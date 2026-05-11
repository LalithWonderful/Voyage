// Phase 1 / Tâche 1.3 — Tests du DestinationIntelligenceLoader.
//
// Tests purement unitaires : AUCUN réseau, AUCUN Supabase, AUCUN
// Google Places. Les sources externes (remote, centerResolver) sont
// représentées par des fakes en mémoire.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/models/destination_intelligence.dart';
import 'package:voyage/services/destination_intelligence_loader.dart';

// ─── Fakes ──────────────────────────────────────────────────────────────

/// Source remote fake. Permet de scripter un retour (DI, null, throw)
/// + compter les appels pour vérifier la priorité local/remote.
class _FakeRemoteSource implements DestinationIntelligenceRemoteSource {
  final Map<String, DestinationIntelligence?> responses;
  final bool shouldThrow;
  int callCount = 0;
  String? lastRequestedKey;

  _FakeRemoteSource({
    this.responses = const {},
    this.shouldThrow = false,
  });

  @override
  Future<DestinationIntelligence?> loadDestinationIntelligence(
      String destinationKey) async {
    callCount++;
    lastRequestedKey = destinationKey;
    if (shouldThrow) {
      throw const FormatException('fake remote source error');
    }
    return responses[destinationKey];
  }
}

/// Center resolver fake. Retourne un GeoPoint scripté ou null.
class _FakeCenterResolver implements DestinationCenterResolver {
  final Map<String, GeoPoint?> responses;
  final bool shouldThrow;
  int callCount = 0;
  String? lastRequestedKey;

  _FakeCenterResolver({
    this.responses = const {},
    this.shouldThrow = false,
  });

  @override
  Future<GeoPoint?> resolveCenter(String destinationKey) async {
    callCount++;
    lastRequestedKey = destinationKey;
    if (shouldThrow) {
      throw const FormatException('fake center resolver error');
    }
    return responses[destinationKey];
  }
}

/// Builder local fake qui compte combien de fois il est invoqué.
/// Sert à vérifier le cache hit (cache OK ⇒ builder appelé une
/// seule fois).
class _CountingBuilder {
  int callCount = 0;
  final DestinationIntelligence Function() inner;
  _CountingBuilder(this.inner);
  DestinationIntelligence call() {
    callCount++;
    return inner();
  }
}

DestinationIntelligence _minimalValidDestination(String key) {
  return DestinationIntelligence(
    destinationKey: key,
    canonicalCenter: const GeoPoint(lat: 10.0, lng: 20.0),
    countryCode: 'TS',
    allowedCountryCodes: const ['TS'],
    blockedCountryCodes: const [],
    borderSensitivity: BorderSensitivity.low,
    tripMode: TripMode.cityBreak,
    zones: const [
      TouristZone(
        name: 'Test Zone',
        center: GeoPoint(lat: 10.0, lng: 20.0),
        radiusKm: 1.0,
        theme: 'test_theme',
      ),
    ],
    anchors: const [
      DestinationAnchor(
        name: 'Test Anchor',
        placeQueries: ['Test Query'],
        importance: 3,
        recommendedDuration: Duration(minutes: 60),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 5.0,
      dominantMode: 'public_transport',
      hasMetro: false,
      hasMetroAnchorLogic: false,
    ),
  );
}

void main() {
  // ─── 1. Load Singapour depuis le registry local ───────────────────────

  group('1. Load Singapour depuis le registry local', () {
    test('load("singapore") retourne destinationKey singapore, '
        'validate() empty, contient les zones attendues', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');

      expect(di.destinationKey, equals('singapore'));
      expect(di.validate(), isEmpty);
      // Subset des 10 zones spec Tâche 1.2.
      final zoneNames = di.zones.map((z) => z.name).toSet();
      expect(
          zoneNames,
          containsAll([
            'Marina Bay',
            'Chinatown',
            'Sentosa',
            'Orchard',
            'Botanic Gardens',
          ]));
      expect(di.tripMode, equals(TripMode.megaCity));
      expect(di.borderSensitivity, equals(BorderSensitivity.high));
    });
  });

  // ─── 2. Normalisation de clé ──────────────────────────────────────────

  group('2. Normalisation de clé', () {
    test('load(" Singapore "), load("SINGAPORE"), load("singapore") '
        'chargent la même destination', () async {
      final loader = DestinationIntelligenceLoader();
      final a = await loader.load(' Singapore ');
      final b = await loader.load('SINGAPORE');
      final c = await loader.load('singapore');
      // L'objet pourrait être différent ref si cache miss, mais le
      // contenu doit être identique. En réalité, cache hit après le
      // 1er load → identical(ref).
      expect(identical(a, b), isTrue,
          reason: 'Normalisation → même entrée cache');
      expect(identical(b, c), isTrue);
      expect(a.destinationKey, equals('singapore'));
    });

    test('isCached("Singapore") retourne true après load("SINGAPORE")',
        () async {
      final loader = DestinationIntelligenceLoader();
      expect(loader.isCached('singapore'), isFalse);
      await loader.load('SINGAPORE');
      expect(loader.isCached('singapore'), isTrue);
      expect(loader.isCached(' singapore '), isTrue);
      expect(loader.isCached('Singapore'), isTrue);
    });
  });

  // ─── 3. Cache hit sur deuxième appel ──────────────────────────────────

  group('3. Cache hit sur deuxième appel', () {
    test('Builder local appelé UNE seule fois sur 2 loads', () async {
      final countingSg = _CountingBuilder(
          () => _minimalValidDestination('singapore'));
      final loader = DestinationIntelligenceLoader(
        localRegistry: {'singapore': countingSg.call},
      );
      await loader.load('singapore');
      await loader.load('singapore');
      await loader.load('Singapore');
      expect(countingSg.callCount, equals(1),
          reason: 'Cache doit éviter de re-builder');
    });

    test('clearCache() force un nouveau build', () async {
      final countingSg = _CountingBuilder(
          () => _minimalValidDestination('singapore'));
      final loader = DestinationIntelligenceLoader(
        localRegistry: {'singapore': countingSg.call},
      );
      await loader.load('singapore');
      loader.clearCache();
      await loader.load('singapore');
      expect(countingSg.callCount, equals(2));
      expect(loader.isCached('singapore'), isTrue,
          reason: 'Le 2ᵉ load re-peuple le cache');
    });
  });

  // ─── 4. Destination inconnue fallback ─────────────────────────────────

  group('4. Destination inconnue fallback', () {
    test('load("unknown_city") retourne DI valide avec invariants '
        'fallback', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('unknown_city');

      expect(di.validate(), isEmpty,
          reason: 'Fallback doit être valide');
      expect(di.destinationKey, equals('unknown_city'));
      expect(di.tripMode, equals(TripMode.cityBreak));
      expect(di.borderSensitivity, equals(BorderSensitivity.medium));
      expect(di.zones, isNotEmpty);
      expect(di.anchors, isNotEmpty);
      expect(di.transportRules.validate(), isEmpty);
      // Centre neutre (pas de resolver) → (0, 0).
      expect(di.canonicalCenter.lat, equals(0));
      expect(di.canonicalCenter.lng, equals(0));
    });

    test('Fallback avec clé vide ne crashe pas, name fallback valide',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('');
      expect(di.validate(), isEmpty,
          reason: 'Fallback clé vide doit rester valide');
      // Anchor name doit être non-vide (DestinationAnchor.validate exige).
      expect(di.anchors.first.name, isNotEmpty);
    });
  });

  // ─── 5. Fallback avec centerResolver ──────────────────────────────────

  group('5. Fallback avec centerResolver', () {
    test('fake resolver retourne un GeoPoint précis → canonicalCenter '
        'utilise ce point', () async {
      final resolver = _FakeCenterResolver(responses: {
        'mystery_city': const GeoPoint(lat: 48.85, lng: 2.35),
      });
      final loader =
          DestinationIntelligenceLoader(centerResolver: resolver);
      final di = await loader.load('mystery_city');

      expect(di.canonicalCenter.lat, equals(48.85));
      expect(di.canonicalCenter.lng, equals(2.35));
      expect(di.validate(), isEmpty);
      expect(resolver.callCount, equals(1));
      expect(resolver.lastRequestedKey, equals('mystery_city'));
      // Et toutes les zones utilisent ce centre par fallback.
      expect(di.zones.first.center.lat, equals(48.85));
      expect(di.zones.first.center.lng, equals(2.35));
    });

    test('resolver retourne null → centre neutre (0, 0)', () async {
      final resolver = _FakeCenterResolver(responses: const {
        'null_city': null,
      });
      final loader =
          DestinationIntelligenceLoader(centerResolver: resolver);
      final di = await loader.load('null_city');
      expect(di.canonicalCenter.lat, equals(0));
      expect(di.canonicalCenter.lng, equals(0));
      expect(di.validate(), isEmpty);
    });

    test('resolver throw → fallback silencieux au centre neutre', () async {
      final resolver = _FakeCenterResolver(shouldThrow: true);
      final loader =
          DestinationIntelligenceLoader(centerResolver: resolver);
      final di = await loader.load('crashy_city');
      expect(di.canonicalCenter.lat, equals(0));
      expect(di.canonicalCenter.lng, equals(0));
      expect(di.validate(), isEmpty);
    });

    test('resolver retourne GeoPoint invalide (lat 200) → fallback '
        'centre neutre', () async {
      // GeoPoint.validate() rejette → loader retombe sur le neutre.
      final resolver = _FakeCenterResolver(responses: const {
        'invalid_geo': GeoPoint(lat: 200, lng: 0),
      });
      final loader =
          DestinationIntelligenceLoader(centerResolver: resolver);
      final di = await loader.load('invalid_geo');
      expect(di.canonicalCenter.lat, equals(0));
      expect(di.canonicalCenter.lng, equals(0));
      expect(di.validate(), isEmpty);
    });
  });

  // ─── 6. Remote source optionnelle ─────────────────────────────────────

  group('6. Remote source optionnelle', () {
    test('Remote retourne un DI valide → loader le retourne et cache',
        () async {
      final testCityDi = _minimalValidDestination('test_city');
      final remote = _FakeRemoteSource(responses: {
        'test_city': testCityDi,
      });
      final loader = DestinationIntelligenceLoader(
        remoteSource: remote,
        localRegistry: const {}, // empty pour forcer le remote
      );
      final di = await loader.load('test_city');
      expect(di.destinationKey, equals('test_city'));
      expect(di.validate(), isEmpty);
      expect(loader.isCached('test_city'), isTrue);
      expect(remote.callCount, equals(1));
      // 2ᵉ load → cache hit, remote PAS rappelé.
      await loader.load('test_city');
      expect(remote.callCount, equals(1));
    });

    test('Remote retourne null → fallback (pas de crash)', () async {
      final remote = _FakeRemoteSource(
          responses: const {'nowhere': null});
      final loader = DestinationIntelligenceLoader(
        remoteSource: remote,
        localRegistry: const {},
      );
      final di = await loader.load('nowhere');
      expect(di.validate(), isEmpty);
      expect(di.destinationKey, equals('nowhere'));
      expect(di.tripMode, equals(TripMode.cityBreak));
      expect(remote.callCount, equals(1));
    });
  });

  // ─── 7. Remote source absente ou null ─────────────────────────────────

  group('7. Remote source absente', () {
    test('Sans remote, destination inconnue → fallback gracieux',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('non_existent');
      expect(di.validate(), isEmpty);
      expect(di.destinationKey, equals('non_existent'));
    });
  });

  // ─── 8. Priorité local vs remote ──────────────────────────────────────

  group('8. Priorité local-first', () {
    test('Destination dans local ET remote → local gagne, remote PAS '
        'consulté', () async {
      // Remote retourne un DI modifié pour Singapour.
      final remoteSg = _minimalValidDestination('singapore');
      final remote = _FakeRemoteSource(responses: {
        'singapore': remoteSg,
      });
      final loader = DestinationIntelligenceLoader(
        remoteSource: remote,
        // localRegistry par défaut = Singapore présent.
      );
      final di = await loader.load('singapore');

      // Le DI local (vrai Singapour avec 10 zones) doit gagner sur
      // le fake remote minimal (1 zone).
      expect(di.zones.length, greaterThan(5),
          reason: 'Le DI local 10 zones doit gagner sur remote 1 zone');
      expect(di.tripMode, equals(TripMode.megaCity));
      expect(remote.callCount, equals(0),
          reason: 'Remote ne doit PAS être consulté quand local trouve');
    });
  });

  // ─── 9. Erreur remote ─────────────────────────────────────────────────

  group('9. Erreur remote → fallback silencieux', () {
    test('Remote throw → loader ne crashe pas, retourne fallback',
        () async {
      final remote = _FakeRemoteSource(shouldThrow: true);
      final loader = DestinationIntelligenceLoader(
        remoteSource: remote,
        localRegistry: const {},
      );
      final di = await loader.load('crashy_city');
      expect(di.validate(), isEmpty);
      expect(di.destinationKey, equals('crashy_city'));
      // Remote a été tenté.
      expect(remote.callCount, equals(1));
    });

    test('Remote throw mais destination dans local → local répond, '
        'pas d\'erreur', () async {
      final remote = _FakeRemoteSource(shouldThrow: true);
      final loader = DestinationIntelligenceLoader(
        remoteSource: remote,
        // localRegistry default contient Singapore.
      );
      final di = await loader.load('singapore');
      expect(di.destinationKey, equals('singapore'));
      expect(di.validate(), isEmpty);
      // Remote pas consulté car local trouvé d'abord.
      expect(remote.callCount, equals(0));
    });
  });

  // ─── 10. Edge cases supplémentaires ───────────────────────────────────

  group('10. Edge cases', () {
    test('isCached avant tout load → false partout', () {
      final loader = DestinationIntelligenceLoader();
      expect(loader.isCached('singapore'), isFalse);
      expect(loader.isCached('whatever'), isFalse);
      expect(loader.isCached(''), isFalse);
    });

    test('clearCache vide vraiment le cache', () async {
      final loader = DestinationIntelligenceLoader();
      await loader.load('singapore');
      await loader.load('unknown');
      expect(loader.isCached('singapore'), isTrue);
      expect(loader.isCached('unknown'), isTrue);
      loader.clearCache();
      expect(loader.isCached('singapore'), isFalse);
      expect(loader.isCached('unknown'), isFalse);
    });

    test('Custom localRegistry remplace le default', () async {
      // Empty registry → load('singapore') tombe en fallback.
      final loader =
          DestinationIntelligenceLoader(localRegistry: const {});
      final di = await loader.load('singapore');
      // Pas le vrai Singapour (1 zone fallback vs 10 zones data).
      expect(di.tripMode, equals(TripMode.cityBreak),
          reason: 'Fallback → cityBreak (pas megaCity)');
      expect(di.zones, hasLength(1));
    });

    test('Custom localRegistry avec destination personnalisée', () async {
      final customSg = _minimalValidDestination('singapore');
      final loader = DestinationIntelligenceLoader(localRegistry: {
        'singapore': () => customSg,
      });
      final di = await loader.load('singapore');
      // Pas le vrai Singapour, mais l'objet customSg.
      expect(di.zones, hasLength(1));
      expect(di.countryCode, equals('TS'));
    });

    test('Cache partagé entre keys normalisées (1 seule entrée)',
        () async {
      final loader = DestinationIntelligenceLoader();
      await loader.load('SINGAPORE');
      await loader.load(' singapore ');
      await loader.load('Singapore');
      // 3 loads, mais une seule entrée cache.
      // Pas d'API pour compter — vérifions indirectement via isCached.
      expect(loader.isCached('singapore'), isTrue);
      // Verifying no duplicate via clearCache + recheck.
      loader.clearCache();
      expect(loader.isCached('singapore'), isFalse);
      expect(loader.isCached('SINGAPORE'), isFalse);
    });
  });
}
