/// V7 (Lalith 2026-05-10 — Phase Cost-1) — budget des appels Google
/// Places PER PLANNING RUN.
///
/// Problème identifié sur les logs : la génération du planning d'un
/// voyage 46 jours déclenchait 200+ appels Places (searchNearby +
/// searchText), causant des HTTP 429 et un risque de coût élevé.
///
/// Stratégie : un compteur en mémoire scopé à une génération, qui
/// court-circuite les appels redondants ou hors budget AVANT qu'ils
/// arrivent à l'API.
///
/// Garanties :
///  - dédup intra-run : 2 appels avec exactement la même clé (ville +
///    query/types + radius + lang) ne tapent l'API qu'une fois — la
///    2ᵉ retombe sur le cache.
///  - hard cap par run : `maxSearchTextPerRun`, `maxNearbyPerRun`,
///    `maxPlacesCallsPerRun`. Au-delà, les appels suivants sont
///    refusés et un log explicite est posé.
///  - rate-limited bail-out : si Places renvoie 429, on flag le
///    budget. Tout appel suivant retombe immédiatement sans
///    re-tenter — pas de cascade de retries.
///
/// Hors scope ici (Phase Cost-2) : pool de candidats par ville,
/// reuse cross-day, throttling adaptatif.
library;

import 'package:flutter/foundation.dart';

/// Constantes par défaut. Hard caps configurables en un seul endroit.
/// Tunables sans toucher aux call sites.
class PlacesBudgetConfig {
  /// Borne supérieure d'appels Places (Nearby + SearchText + Details)
  /// pour une génération de planning. Au-delà → bail-out.
  static const int maxPlacesCallsPerRun = 80;

  /// Borne SearchText spécifique. SearchText est plus cher et bruité
  /// que Nearby, on le serre plus fort.
  static const int maxSearchTextPerRun = 40;

  /// Borne Nearby. Plus structurée donc plus permissive.
  static const int maxNearbyPerRun = 60;

  /// Borne Place Details (resolveTransportEndpoint, etc.). Reste très
  /// utilisée pour le cache enrichissement.
  static const int maxDetailsPerRun = 30;

  /// Phase Cost-2 : par segment. Pour l'instant indicatif (compté
  /// mais pas enforced — on ajoutera l'enforcement quand le pool de
  /// candidats par ville sera en place).
  static const int maxCallsPerSegment = 12;

  /// Constante anti-faux-positif : quand Places renvoie HTTP 429 ou
  /// 403 RESOURCE_EXHAUSTED, on stoppe net.
  static const Set<int> rateLimitedHttpCodes = {429, 403};
}

/// Type d'appel pour catégoriser le tracking.
enum PlacesCallKind { nearby, searchText, details }

/// Budget mutable pour UNE génération de planning. Instancié au début
/// de la run, accumule les compteurs, retourné en snapshot à la fin.
class PlacesBudget {
  PlacesBudget({
    String? tripId,
    int? maxTotal,
    int? maxSearchText,
    int? maxNearby,
    int? maxDetails,
  })  : _tripId = tripId,
        _maxTotal = maxTotal ?? PlacesBudgetConfig.maxPlacesCallsPerRun,
        _maxSearchText =
            maxSearchText ?? PlacesBudgetConfig.maxSearchTextPerRun,
        _maxNearby = maxNearby ?? PlacesBudgetConfig.maxNearbyPerRun,
        _maxDetails = maxDetails ?? PlacesBudgetConfig.maxDetailsPerRun;

  final String? _tripId;
  final int _maxTotal;
  final int _maxSearchText;
  final int _maxNearby;
  final int _maxDetails;

  int _searchTextCalls = 0;
  int _nearbyCalls = 0;
  int _detailsCalls = 0;
  int _cacheHits = 0;
  int _dedupSkipped = 0;
  int _budgetSkipped = 0;
  bool _rateLimited = false;
  final Set<String> _calledQueries = <String>{};

  // ─── Lecture (snapshot) ──────────────────────────────────────────

  int get searchTextCalls => _searchTextCalls;
  int get nearbyCalls => _nearbyCalls;
  int get detailsCalls => _detailsCalls;
  int get totalCalls => _searchTextCalls + _nearbyCalls + _detailsCalls;
  int get cacheHits => _cacheHits;
  int get dedupSkipped => _dedupSkipped;
  int get budgetSkipped => _budgetSkipped;
  bool get rateLimited => _rateLimited;

  // ─── Décisions pré-appel ─────────────────────────────────────────

  /// Vrai si on doit court-circuiter cet appel (rate limit / budget /
  /// dedup intra-run). Le caller interprète et retombe sur cache ou
  /// résultat vide.
  bool shouldSkip({
    required PlacesCallKind kind,
    required String dedupKey,
  }) {
    if (_rateLimited) {
      _budgetSkipped++;
      return true;
    }
    if (_calledQueries.contains(dedupKey)) {
      _dedupSkipped++;
      return true;
    }
    if (totalCalls >= _maxTotal) {
      debugPrint(
        '[places_budget] global cap hit ($_maxTotal) — skip $kind '
        'dedupKey="$dedupKey"',
      );
      _budgetSkipped++;
      return true;
    }
    final perKindMax = switch (kind) {
      PlacesCallKind.searchText => _maxSearchText,
      PlacesCallKind.nearby => _maxNearby,
      PlacesCallKind.details => _maxDetails,
    };
    final perKindCount = switch (kind) {
      PlacesCallKind.searchText => _searchTextCalls,
      PlacesCallKind.nearby => _nearbyCalls,
      PlacesCallKind.details => _detailsCalls,
    };
    if (perKindCount >= perKindMax) {
      debugPrint(
        '[places_budget] per-kind cap hit ($kind=$perKindMax) — skip '
        'dedupKey="$dedupKey"',
      );
      _budgetSkipped++;
      return true;
    }
    return false;
  }

  // ─── Enregistrement post-appel ───────────────────────────────────

  void recordCall(PlacesCallKind kind, String dedupKey) {
    _calledQueries.add(dedupKey);
    switch (kind) {
      case PlacesCallKind.searchText:
        _searchTextCalls++;
      case PlacesCallKind.nearby:
        _nearbyCalls++;
      case PlacesCallKind.details:
        _detailsCalls++;
    }
  }

  void recordCacheHit(String dedupKey) {
    _cacheHits++;
    _calledQueries.add(dedupKey);
  }

  /// Appelé quand Places renvoie 429 / 403 RESOURCE_EXHAUSTED. À
  /// partir de cet instant, tous les `shouldSkip` renvoient true →
  /// le pipeline retombe sur cache uniquement.
  void markRateLimited({required PlacesCallKind kind, required int httpCode}) {
    if (_rateLimited) return;
    _rateLimited = true;
    debugPrint(
      '[places_budget] rate_limited=true (HTTP $httpCode on $kind) — '
      'stopping further Places calls for this run',
    );
  }

  // ─── Log de fin de run ───────────────────────────────────────────

  /// Log structuré à appeler en fin de génération du planning.
  /// Format machine-friendly pour parsing ultérieur si besoin.
  void logSummary({String? context}) {
    final parts = <String>[
      '[places_cost_summary]',
      if (_tripId != null) 'tripId=$_tripId',
      if (context != null) 'context=$context',
      'totalCalls=$totalCalls',
      'searchText=$_searchTextCalls',
      'nearby=$_nearbyCalls',
      'details=$_detailsCalls',
      'cacheHits=$_cacheHits',
      'dedupSkipped=$_dedupSkipped',
      'budgetSkipped=$_budgetSkipped',
      'rateLimited=$_rateLimited',
    ];
    // V7.1 (Lalith 2026-05-10) — `print` plutôt que `debugPrint` :
    // sur cold cache, le pipeline emet des milliers de `[places_first_match]`
    // qui saturent le throttle de `debugPrint` et font disparaître ce summary
    // (ligne unique mais critique). `print` n'est pas throttlé.
    // ignore: avoid_print
    print(parts.join(' '));
    if (totalCalls >= _maxTotal * 0.8) {
      // ignore: avoid_print
      print(
        '[places_cost_warning] calls=$totalCalls '
        'exceedsBudget=${(totalCalls * 100 / _maxTotal).toStringAsFixed(0)}% '
        'of cap $_maxTotal',
      );
    }
  }
}

/// Helper de construction des clés de dédup.
/// Convention : `{kind}|{cityOrCenter}|{queryOrTypes}|{radius}|{lang}`.
/// L'unicité doit refléter l'identité fonctionnelle de la requête.
String placesDedupKey({
  required String kind,
  required double lat,
  required double lng,
  required String querySignature,
  required int radius,
  String? languageCode,
}) {
  // Arrondit lat/lng à 3 décimales (~110m) pour bénéficier du dedup
  // même si le centre bouge légèrement entre 2 jours du même segment.
  final latR = lat.toStringAsFixed(3);
  final lngR = lng.toStringAsFixed(3);
  final lang = languageCode ?? '_';
  return '$kind|$latR|$lngR|$querySignature|$radius|$lang';
}
