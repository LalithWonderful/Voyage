// POI-0.8 — Tests de LivePoiSupabaseClient.
//
// Aucun appel réseau par défaut. Les tests live sont skipped sauf si
// lancés avec :
//   flutter test --dart-define=ALLOW_LIVE_SUPABASE=true \
//                --dart-define=SUPABASE_URL=<url> \
//                --dart-define=SUPABASE_ANON_KEY=<key> \
//                test/poi/live_poi_supabase_client_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/poi/data/live_poi_supabase_client.dart';
import 'package:voyage/features/poi/data/poi_supabase_client.dart';

const bool _allowLive = bool.fromEnvironment(
  'ALLOW_LIVE_SUPABASE',
  defaultValue: false,
);
const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  // ═══════════════════════════════════════════════════════════════════
  // 1. Tests structurels (offline, toujours exécutés)
  // ═══════════════════════════════════════════════════════════════════

  group('LivePoiSupabaseClient structure', () {
    test('LivePoiSupabaseClient is a PoiSupabaseClient', () {
      // Vérification de type à la compilation.
      PoiSupabaseClient client = LivePoiSupabaseClient(
        // On peut passer un mock/fake ici ; pour le test structurel
        // on vérifie juste que le constructeur existe et accepte le type.
        _FakeSupabaseClient(),
      );
      expect(client, isA<PoiSupabaseClient>());
    });

    test('LivePoiSupabaseQuery is a PoiSupabaseQuery', () {
      final liveClient = LivePoiSupabaseClient(_FakeSupabaseClient());
      final query = liveClient.from('pois');
      expect(query, isA<PoiSupabaseQuery>());
    });

    test('LivePoiSupabaseQuery supports chaining', () {
      final liveClient = LivePoiSupabaseClient(_FakeSupabaseClient());
      final query = liveClient
          .from('pois')
          .select()
          .eq('destination_key', 'singapore')
          .ilike('name', '%gardens%')
          .or('name.ilike.%a%,name.ilike.%b%')
          .inFilter('poi_id', ['1', '2'])
          .order('editorial_score', ascending: false)
          .limit(10);
      expect(query, isA<PoiSupabaseQuery>());
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 2. Tests live (opt-in, skipped par défaut)
  // ═══════════════════════════════════════════════════════════════════

  group('Live integration tests (opt-in)', () {
    final runLive = _allowLive &&
        _supabaseUrl.isNotEmpty &&
        _supabaseAnonKey.isNotEmpty;

    late SupabaseClient client;

    setUp(() {
      if (!runLive) return;
      // Pas de Supabase.initialize() — on instancie le client bas-niveau
      // directement pour éviter tout effet de bord sur le singleton.
      client = SupabaseClient(_supabaseUrl, _supabaseAnonKey);
    });

    tearDown(() {
      if (!runLive) return;
      client.dispose();
    });

    test(
      'can query pois table (read-only sanity)',
      skip: !runLive,
      () async {
        final liveClient = LivePoiSupabaseClient(client);
        final result = await liveClient
            .from('pois')
            .select()
            .limit(1)
            .execute();
        expect(result, isA<List<Map<String, dynamic>>>());
      },
    );

    test(
      'can query poi_aliases table (read-only sanity)',
      skip: !runLive,
      () async {
        final liveClient = LivePoiSupabaseClient(client);
        final result = await liveClient
            .from('poi_aliases')
            .select(['alias_id', 'poi_id', 'alias'])
            .limit(1)
            .execute();
        expect(result, isA<List<Map<String, dynamic>>>());
        if (result.isNotEmpty) {
          expect(result.first.keys.toSet(),
              equals({'alias_id', 'poi_id', 'alias'}));
        }
      },
    );

    test(
      'can query poi_tags table (read-only sanity)',
      skip: !runLive,
      () async {
        final liveClient = LivePoiSupabaseClient(client);
        final result = await liveClient
            .from('poi_tags')
            .select()
            .limit(1)
            .execute();
        expect(result, isA<List<Map<String, dynamic>>>());
      },
    );

    test(
      'maybeSingle returns null or map',
      skip: !runLive,
      () async {
        final liveClient = LivePoiSupabaseClient(client);
        final result = await liveClient
            .from('pois')
            .select()
            .eq('poi_id', 'nonexistent-id-12345')
            .maybeSingle();
        expect(result, isNull);
      },
    );
  });
}

// ═══════════════════════════════════════════════════════════════════
// Fake minimal pour le test structurel (offline, aucun réseau)
// ═══════════════════════════════════════════════════════════════════

class _FakeSupabaseClient extends SupabaseClient {
  _FakeSupabaseClient() : super('http://localhost', 'fake-anon-key');
}
