import 'dart:convert';
import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Cache local des données voyage pour la **lecture offline-first**.
///
/// Stratégie : à chaque fetch Supabase réussi, on snapshot les rows brutes
/// (Map JSON) dans `shared_preferences`. Si un fetch ultérieur échoue (mode
/// avion, zone blanche, panne réseau), les providers Riverpod fallback sur
/// le cache pour permettre au voyageur de **consulter** ses voyages, son
/// planning et ses docs en toute circonstance. Pas d'écritures offline pour
/// la beta — un `save()` sans réseau est rejeté avec un message explicite.
///
/// Stockage : 1 entrée pour la liste des trips, 1 par voyage pour
/// activities/documents/transports, 1 globale pour le wallet.
class LocalTripsCacheService {
  final SharedPreferences _prefs;
  LocalTripsCacheService(this._prefs);

  static const _kTrips = 'cache_trips';
  static const _kAllDocuments = 'cache_all_documents';
  static const _kActivitiesPrefix = 'cache_activities_';
  static const _kDocumentsPrefix = 'cache_documents_';
  static const _kTransportsPrefix = 'cache_transports_';

  // ─── Trips ─────────────────────────────────────────────────────────────

  Future<void> writeTrips(List<dynamic> rows) async {
    await _writeJson(_kTrips, rows);
  }

  List<Trip> readTrips() => _readList(_kTrips, Trip.fromJson);

  // ─── Activities (par voyage) ───────────────────────────────────────────

  Future<void> writeActivities(String tripId, List<dynamic> rows) async {
    await _writeJson('$_kActivitiesPrefix$tripId', rows);
  }

  List<TripActivity> readActivities(String tripId) =>
      _readList('$_kActivitiesPrefix$tripId', TripActivity.fromJson);

  // ─── Documents globaux (Wallet) ────────────────────────────────────────

  Future<void> writeAllDocuments(List<dynamic> rows) async {
    await _writeJson(_kAllDocuments, rows);
  }

  List<TripDocument> readAllDocuments() =>
      _readList(_kAllDocuments, TripDocument.fromJson);

  // ─── Documents (par voyage) ────────────────────────────────────────────

  Future<void> writeDocuments(String tripId, List<dynamic> rows) async {
    await _writeJson('$_kDocumentsPrefix$tripId', rows);
  }

  List<TripDocument> readDocuments(String tripId) =>
      _readList('$_kDocumentsPrefix$tripId', TripDocument.fromJson);

  // ─── Transports ────────────────────────────────────────────────────────

  Future<void> writeTransports(String tripId, List<dynamic> rows) async {
    await _writeJson('$_kTransportsPrefix$tripId', rows);
  }

  List<TripTransport> readTransports(String tripId) =>
      _readList('$_kTransportsPrefix$tripId', TripTransport.fromJson);

  // ─── Helpers ───────────────────────────────────────────────────────────

  Future<void> _writeJson(String key, List<dynamic> rows) async {
    try {
      // On stocke les rows BRUTES (Map<String, dynamic>) telles que reçues
      // de Supabase, pour pouvoir rejouer fromJson au read sans avoir à
      // ajouter toJson() à tous les modèles. Sérialisation jsonEncode
      // gère bien les types Dart standards (DateTime → String ISO, etc.).
      await _prefs.setString(key, jsonEncode(rows));
    } catch (e) {
      developer.log('[local-cache] write error $key : $e', name: 'cache');
    }
  }

  List<T> _readList<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list.whereType<Map<String, dynamic>>().map(fromJson).toList();
    } catch (e) {
      developer.log('[local-cache] read error $key : $e', name: 'cache');
      return const [];
    }
  }

  /// Nettoie tout le cache (utile au logout, ou si l'user signale un bug
  /// "données obsolètes"). À garder pour debug futur.
  Future<void> clearAll() async {
    final keys = _prefs.getKeys().where((k) =>
        k == _kTrips ||
        k == _kAllDocuments ||
        k.startsWith(_kActivitiesPrefix) ||
        k.startsWith(_kDocumentsPrefix) ||
        k.startsWith(_kTransportsPrefix)).toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
  }
}
