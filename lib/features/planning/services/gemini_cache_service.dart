import 'dart:convert';
import 'dart:developer' as developer;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cache générique pour les réponses Gemini, partagé entre tous les voyageurs
/// (cf. pattern `places_cache`). La table Supabase `gemini_cache` est indexée
/// par (action, cache_key). Chaque caller est responsable de :
/// 1. Choisir une `action` stable (ex: 'describe_activity', 'transport_pair'),
/// 2. Construire un `cacheKey` déterministe à partir des inputs qui influencent
///    la réponse (titres normalisés, IDs, paramètres). Voir [normKey] et [hashKey]
///    pour les helpers usuels,
/// 3. Sérialiser sa réponse en `Map<String, dynamic>` JSON-safe pour le `put`,
///    et savoir la désérialiser au `get`.
///
/// Best-effort : toute erreur de cache (réseau, RLS, JSON cassé) est swallow et
/// loguée, mais ne fait pas échouer l'appel d'origine — au pire on rappelle Gemini.
class GeminiCacheService {
  final SupabaseClient _client;
  final Duration _defaultTtl;

  // V8.3 (Lalith 2026-05-10 — Phase Cost-3) — TTL bumpé 30j → 90j.
  // Les payloads cachés ici sont des résultats Places/Gemini quasi
  // statiques (rating, types, address, photos d'un venue). Sur 1-3 mois
  // les variations sont négligeables vs le coût API en cas de re-fetch.
  // Le risque (rating légèrement périmé) est acceptable pour le scoring.
  GeminiCacheService(this._client, {Duration? ttl})
      : _defaultTtl = ttl ?? const Duration(days: 90);

  /// Récupère un payload caché. Retourne null si miss, expiré, ou erreur.
  /// Le caller décode le payload selon son schéma.
  Future<Map<String, dynamic>?> get(
    String action,
    String cacheKey, {
    Duration? ttl,
  }) async {
    final effectiveTtl = ttl ?? _defaultTtl;
    try {
      final row = await _client
          .from('gemini_cache')
          .select('payload, refreshed_at')
          .eq('action', action)
          .eq('cache_key', cacheKey)
          .maybeSingle();
      if (row == null) {
        developer.log('MISS $action / $cacheKey', name: 'gemini_cache');
        return null;
      }
      final refreshed = DateTime.tryParse(row['refreshed_at'] as String? ?? '');
      if (refreshed == null || DateTime.now().difference(refreshed) > effectiveTtl) {
        developer.log('EXPIRED $action / $cacheKey', name: 'gemini_cache');
        return null;
      }
      developer.log('HIT $action / $cacheKey', name: 'gemini_cache');
      final payload = row['payload'];
      if (payload is Map<String, dynamic>) return payload;
      // Postgres jsonb peut nous renvoyer un Map<dynamic, dynamic> selon les drivers
      if (payload is Map) return Map<String, dynamic>.from(payload);
      return null;
    } catch (e) {
      developer.log('lookup error ($action): $e', name: 'gemini_cache');
      return null;
    }
  }

  /// Upsert un payload. Best-effort (silencieux en cas d'erreur).
  Future<void> put(
    String action,
    String cacheKey,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _client.from('gemini_cache').upsert({
        'action': action,
        'cache_key': cacheKey,
        'payload': payload,
        'refreshed_at': DateTime.now().toIso8601String(),
      }, onConflict: 'action,cache_key');
    } catch (e) {
      developer.log('upsert error ($action): $e', name: 'gemini_cache');
    }
  }

  /// Normalise une string pour la rendre stable comme composant de clé :
  /// lowercase, trim, espaces réduits, accents préservés.
  static String normKey(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Sérialise une liste de pairs (clé, valeur) en chaîne déterministe pour
  /// servir de cache_key. Ordre stable, JSON-encode des valeurs pour gérer les
  /// listes (ex: liste d'intérêts triée). Pour un cas simple `'a|b|c'` suffit.
  static String hashKey(List<({String k, Object? v})> parts) {
    final sorted = [...parts]..sort((a, b) => a.k.compareTo(b.k));
    return sorted
        .map((p) => '${p.k}=${p.v is String ? p.v : jsonEncode(p.v)}')
        .join('|');
  }
}
