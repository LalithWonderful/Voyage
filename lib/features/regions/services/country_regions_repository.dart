import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/regions/data/country_regions.dart';
import 'package:voyage/features/regions/data/region_tags.dart';
import 'package:voyage/features/regions/models/country_region.dart';

/// Charge les régions touristiques préconfigurées des "grands pays" (V1).
///
/// Stratégie de fallback (ordre de priorité) :
/// 1. **Cache mémoire** (cette session) — déjà chargé une fois.
/// 2. **Cache disque frais** (< 7 jours) — SharedPreferences.
/// 3. **Supabase** `country_regions` — source de vérité, met à jour le cache.
/// 4. **Cache disque expiré** (mieux que rien si Supabase down).
/// 5. **JSON asset** `assets/data/country_regions.json` — toujours dispo,
///    embarqué dans le binaire.
///
/// Robustesse : même offline, sans cache, l'asset garantit le service.
/// Validation : au 1er load, vérifie que tous les tags utilisés ∈ allowedTags
/// (debugPrint warning sinon — fail soft, ne bloque pas l'app).
class CountryRegionsRepository {
  final SupabaseClient _supabase;
  CountryRegionsRepository(this._supabase);

  static const _cacheKey = 'country_regions_cache_v1';
  static const _cacheTtl = Duration(days: 7);
  static const _assetPath = 'assets/data/country_regions.json';

  /// Cache en mémoire pour la session courante. Évite N appels disque/réseau
  /// si plusieurs widgets demandent les régions du même pays.
  List<CountryRegion>? _memoryCache;
  bool _validatedThisSession = false;

  /// Charge toutes les régions (80 en V1) selon la stratégie de fallback.
  /// La 1ère fois fait du I/O ; ensuite c'est en mémoire (instantané).
  Future<List<CountryRegion>> loadAll() async {
    if (_memoryCache != null) return _memoryCache!;

    // 1. Cache disque frais ?
    final freshDisk = await _loadFromDiskCache(requireFresh: true);
    if (freshDisk != null && freshDisk.isNotEmpty) {
      debugPrint('[regions] cache disque HIT (${freshDisk.length} régions, < 7j)');
      _finalize(freshDisk);
      return freshDisk;
    }

    // 2. Supabase — source de vérité
    final fromSupabase = await _loadFromSupabase();
    if (fromSupabase != null && fromSupabase.isNotEmpty) {
      debugPrint('[regions] Supabase HIT (${fromSupabase.length} régions) — cache update');
      await _saveToDiskCache(fromSupabase);
      _finalize(fromSupabase);
      return fromSupabase;
    }

    // 3. Cache disque expiré (Supabase down/lent → mieux que rien)
    final staleDisk = await _loadFromDiskCache(requireFresh: false);
    if (staleDisk != null && staleDisk.isNotEmpty) {
      debugPrint('[regions] Supabase KO → cache disque expiré (${staleDisk.length} régions)');
      _finalize(staleDisk);
      return staleDisk;
    }

    // 4. JSON asset embarqué (fallback ultime)
    final fromAsset = await _loadFromAsset();
    debugPrint('[regions] fallback asset (${fromAsset.length} régions)');
    _finalize(fromAsset);
    return fromAsset;
  }

  /// Régions d'un pays donné, triées par `priority` croissante (1 → 5).
  /// Liste vide si le pays n'est pas dans la table (ex: France, Italie...).
  Future<List<CountryRegion>> getRegions(String countryCode) async {
    final all = await loadAll();
    final upper = countryCode.toUpperCase();
    final filtered = all.where((r) => r.countryCode.toUpperCase() == upper).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return filtered;
  }

  // ─── Validation au boot ────────────────────────────────────────────────

  /// Une seule fois par session, on vérifie :
  /// - les mappings interestToTags / travelerTypeToTags / tagToFrLabel sont
  ///   cohérents avec `allowedTags` (throw si dérive — bug à corriger).
  /// - les régions chargées n'utilisent que des tags ∈ allowedTags
  ///   (warning soft si dérive — données externes potentiellement à mettre à jour).
  void _finalize(List<CountryRegion> regions) {
    _memoryCache = regions;
    if (_validatedThisSession) return;
    _validatedThisSession = true;
    try {
      validateMappings(allowedTags);
    } catch (e) {
      debugPrint('[regions] ⚠️ validation mappings : $e');
      rethrow; // bug interne → on veut le voir
    }
    final unknown = findUnknownTags(regions.map((r) => r.tags));
    if (unknown.isNotEmpty) {
      debugPrint('[regions] ⚠️ tags non whitelistés (cf. allowedTags) : $unknown');
    }
  }

  // ─── Sources individuelles ─────────────────────────────────────────────

  Future<List<CountryRegion>?> _loadFromSupabase() async {
    try {
      final rows = await _supabase
          .from('country_regions')
          .select()
          .order('country_code')
          .order('priority');
      return rows
          .whereType<Map<String, dynamic>>()
          .map(CountryRegion.fromSupabase)
          .toList();
    } catch (e) {
      debugPrint('[regions] Supabase fetch KO : $e');
      return null;
    }
  }

  Future<List<CountryRegion>> _loadFromAsset() async {
    final raw = await rootBundle.loadString(_assetPath);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final list = (decoded['regions'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(CountryRegion.fromAssetJson)
        .toList();
  }

  Future<List<CountryRegion>?> _loadFromDiskCache({required bool requireFresh}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final fetchedAt = DateTime.tryParse(decoded['fetched_at'] as String? ?? '');
      if (fetchedAt == null) return null;
      if (requireFresh) {
        final age = DateTime.now().difference(fetchedAt);
        if (age > _cacheTtl) return null;
      }
      final list = (decoded['regions'] as List?) ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(CountryRegion.fromAssetJson)
          .toList();
    } catch (e) {
      debugPrint('[regions] cache disque lecture KO : $e');
      return null;
    }
  }

  Future<void> _saveToDiskCache(List<CountryRegion> regions) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'fetched_at': DateTime.now().toIso8601String(),
        'regions': regions.map((r) => r.toCacheJson()).toList(),
      });
      await prefs.setString(_cacheKey, payload);
    } catch (e) {
      debugPrint('[regions] cache disque écriture KO : $e');
      // pas grave : le cache mémoire suffit pour la session
    }
  }

  /// Force un refresh (utile pour les écrans admin / debug).
  Future<void> invalidateCache() async {
    _memoryCache = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {}
  }
}

/// Provider Riverpod du repository. Le repo est singleton (cache mémoire
/// partagé entre tous les consommateurs de la session).
final countryRegionsRepositoryProvider =
    Provider<CountryRegionsRepository>((ref) {
  final client = ref.watch(supabaseProvider);
  return CountryRegionsRepository(client);
});

/// Provider famille : régions d'un pays donné (clé = ISO 2). Cache en mémoire.
/// Renvoie [] si le pays n'est pas dans la table.
final regionsByCountryProvider =
    FutureProvider.family<List<CountryRegion>, String>((ref, countryCode) async {
  final repo = ref.watch(countryRegionsRepositoryProvider);
  return repo.getRegions(countryCode);
});
