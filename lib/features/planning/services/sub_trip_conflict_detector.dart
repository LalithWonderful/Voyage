/// Détection de conflits avant d'appliquer une `SubTripSuggestion` au voyage.
///
/// Lot 1 — `preflightSuggestion` (city-level, sans dates) :
/// - Hôtel à l'ancrage → bloquer `replaceAnchorGateway`
/// - Hôtel à la ville suggérée → notice positive ("ton hébergement colle")
/// - Vol/transport vers l'ancrage → info neutre (gateway pattern)
///
/// Lot 2.2 — `preflightDatePrecise` (date-precise) :
/// - Calcule la plage de dates de chaque segment depuis `trip.startDate`
///   et le cumul des `days`.
/// - Identifie les "jours retirés à l'anchor" selon le mode :
///   * APPEND : aucun jour retiré → pas de check
///   * SPLIT : les premiers `suggestedTotal` jours de l'anchor (ces
///     nuits sont réattribuées à la ville suggérée)
///   * REPLACE : tous les jours de l'anchor (l'anchor disparaît)
/// - Pour chaque hôtel à l'anchor city : si check_in/check_out chevauche
///   les "jours retirés" → BLOCK (l'user dort vraiment là-bas ces
///   nuits-là, on ne peut pas les attribuer à une autre ville).
///
/// Lot 1 + Lot 2.2 sont complémentaires : le caller appelle les 2 et
/// combine les verdicts (block prime sur allow).
library;

import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Verdict de la pré-validation d'une suggestion.
enum SuggestionVerdict {
  /// La suggestion peut être appliquée sans précaution particulière.
  allow,
  /// La suggestion peut être appliquée mais on signale un point d'attention
  /// (ex: hôtel déjà à la ville suggérée, l'user verra son hébergement
  /// associé). Card cliquable, hint informatif.
  allowWithNotice,
  /// L'application risque de casser le planning (ex: replace alors que
  /// l'user a un hôtel à l'ancrage). Card désactivée en V1, demandera
  /// confirmation explicite en V2.
  block,
}

/// Résultat structuré du conflict detector — verdict + texte humain pour UI.
class SuggestionPreflight {
  final SuggestionVerdict verdict;

  /// Texte court à afficher sur la card (hint ou raison de blocage).
  /// Vide si verdict = allow et pas d'info supplémentaire utile.
  final String? notice;

  const SuggestionPreflight({
    required this.verdict,
    this.notice,
  });
}

/// Normalise un nom de ville pour comparaison. Doit rester aligné sur
/// `_normalizeCity` côté `sub_trip_suggestions.dart` (copie locale pour
/// éviter une exposition de l'helper privé).
String _normalize(String s) {
  const accents = {
    'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a',
    'ç': 'c',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ï': 'i', 'î': 'i',
    'ñ': 'n',
    'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
  };
  var out = s.toLowerCase().trim();
  accents.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

/// Vrai si AU MOINS un doc hôtel du voyage est rattaché à `city`. Match
/// d'abord sur `metadata['address_city']` (structuré, fourni par
/// Geocoding API), fallback texte sur `metadata['address']` (substring
/// case+accent insensible).
///
/// Note : address_city peut être null si l'user a saisi l'hôtel en mode
/// fallback texte sans placeId. On reste tolérant.
bool _hasHotelInCity(List<TripDocument> docs, String city) {
  final norm = _normalize(city);
  if (norm.isEmpty) return false;
  for (final d in docs) {
    if (d.category != DocumentCategory.hotel) continue;
    final m = d.metadata;
    final structuredCity = (m['address_city'] as String?)?.trim();
    if (structuredCity != null && structuredCity.isNotEmpty) {
      if (_normalize(structuredCity) == norm) return true;
    }
    // Fallback : substring sur l'adresse libre. Tolère "Hanoi, Vietnam"
    // contenant "hanoi" — sans confondre avec "Han" (on cherche le mot
    // entier via délimiteurs simples).
    final address = (m['address'] as String?)?.trim();
    if (address != null && address.isNotEmpty) {
      final normAddr = _normalize(address);
      // Match simple : ville présente comme mot dans l'adresse.
      // Délimité par début/fin/espace/virgule/tiret.
      final pattern = RegExp(
        r'(^|[\s,;\-])' + RegExp.escape(norm) + r'($|[\s,;\-])',
      );
      if (pattern.hasMatch(normAddr)) return true;
    }
  }
  return false;
}

/// Vrai si un vol arrive à `city` (`metadata['to_city']` match). Sert à
/// confirmer le pattern gateway — info neutre, pas un blocage.
bool _hasArrivalFlightTo(List<TripDocument> docs, String city) {
  final norm = _normalize(city);
  for (final d in docs) {
    if (d.category != DocumentCategory.flight) continue;
    final to = (d.metadata['to_city'] as String?)?.trim();
    if (to != null && _normalize(to) == norm) return true;
  }
  return false;
}

/// Pré-validation d'une suggestion.
///
/// Règles V1 (Lot 1) :
/// - Si la suggestion est `replaceAnchorGateway` ET un hôtel existe à
///   l'ancrage → BLOCK ("Cette étape contient déjà une réservation").
///   On ne remplace pas une ville où l'user dort réellement.
/// - Si un hôtel existe à la ville suggérée → ALLOW_WITH_NOTICE
///   ("Ton hébergement est à [ville suggérée]"). Confirme la pertinence.
/// - Si un hôtel existe à la ville suggérée ET pas à l'ancrage → idem
///   ALLOW_WITH_NOTICE. Renforce le signal gateway.
/// - Sinon → ALLOW.
///
/// `anchorCity` = ville d'ancrage de la suggestion.
/// `suggestedCities` = villes que la suggestion injecterait.
/// `mode` = mode d'insertion (string pour découpler d'enum).
/// `docs` = documents du voyage (vols, hôtels, transferts).
SuggestionPreflight preflightSuggestion({
  required String anchorCity,
  required List<String> suggestedCities,
  required String mode,
  required List<TripDocument> docs,
}) {
  final hotelInAnchor = _hasHotelInCity(docs, anchorCity);
  final hotelInSuggested = suggestedCities.any(
    (c) => _hasHotelInCity(docs, c),
  );

  // Cas critique : on veut effacer l'ancrage alors que l'user a un hôtel
  // dessus. Bloquer dur en V1.
  if (mode == 'replaceAnchorGateway' && hotelInAnchor) {
    return const SuggestionPreflight(
      verdict: SuggestionVerdict.block,
      notice:
          'Cette étape contient déjà une réservation d\'hôtel. '
          'Vérifie avant de remplacer.',
    );
  }

  // Hôtel à la ville suggérée → notice positive ("ça colle, ton hôtel
  // est là-bas"). Renforce le signal pour l'user.
  if (hotelInSuggested) {
    return SuggestionPreflight(
      verdict: SuggestionVerdict.allowWithNotice,
      notice:
          'Lunao a trouvé une réservation d\'hôtel à '
          '${suggestedCities.first}. Cette étape colle à ton itinéraire.',
    );
  }

  // Vol vers l'ancrage + pas d'hôtel à l'ancrage → pattern gateway pur.
  // Info neutre, allow propre (pas de notice nécessaire — le whyText
  // de la suggestion suffit).
  if (!hotelInAnchor && _hasArrivalFlightTo(docs, anchorCity)) {
    return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
  }

  return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
}

// ─── Lot 2.2 — Detector date-précis ──────────────────────────────────

/// Plage de jours d'un segment dans le voyage. Indices basés sur
/// `tripStartDate` : `firstDay = tripStartDate + offset`, `lastNight =
/// firstDay + (days - 1)`. La nuit du `lastNight` est la dernière dormie
/// dans cette ville (le lendemain matin on part).
class _SegmentDateRange {
  final int index;
  final String city;
  final DateTime firstDay;
  final DateTime lastNight;
  const _SegmentDateRange({
    required this.index,
    required this.city,
    required this.firstDay,
    required this.lastNight,
  });
}

/// Calcule la plage de dates de chaque segment depuis `tripStartDate` et
/// le cumul des `days`. Le 1er segment commence à `tripStartDate`. Si la
/// somme des `days` dépasse la durée du voyage (cas observé sur certains
/// voyages auto-seedés), le calcul reste correct mais les derniers
/// segments dépassent `trip.endDate` — pas un problème ici, on raisonne
/// sur les segments tels que définis.
List<_SegmentDateRange> _computeSegmentRanges(
  List<TripSegment> segments,
  DateTime tripStartDate,
) {
  final ranges = <_SegmentDateRange>[];
  var cursor = tripStartDate;
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    final firstDay = cursor;
    // lastNight = firstDay + (days - 1). Pour days=1, lastNight = firstDay.
    final lastNight = cursor.add(Duration(days: s.days - 1));
    ranges.add(_SegmentDateRange(
      index: i,
      city: s.city,
      firstDay: firstDay,
      lastNight: lastNight,
    ));
    cursor = cursor.add(Duration(days: s.days));
  }
  return ranges;
}

/// Vrai si une nuit `n` (DateTime) est couverte par une réservation hôtel
/// `(checkIn, checkOut)`. Convention : la dernière nuit dormie est
/// `checkOut - 1 day`. Donc `n` est couverte si `checkIn ≤ n < checkOut`.
bool _isNightCoveredByStay(
  DateTime night,
  DateTime checkIn,
  DateTime checkOut,
) {
  // Tout à minuit pour une comparaison de jour calendaire pure.
  final n = DateTime(night.year, night.month, night.day);
  final ci = DateTime(checkIn.year, checkIn.month, checkIn.day);
  final co = DateTime(checkOut.year, checkOut.month, checkOut.day);
  return !n.isBefore(ci) && n.isBefore(co);
}

/// Pré-validation date-précise. Calcule les jours retirés à l'anchor par
/// la mutation et vérifie qu'aucune réservation hôtel à l'anchor city ne
/// les couvre.
///
/// `suggestion` : la suggestion à pré-valider.
/// `currentSegments` : segments actuels du voyage.
/// `tripStartDate` : date début du voyage (pour calcul des dates segment).
/// `docs` : documents du voyage (vols, hôtels, etc.).
///
/// Comportement par mode :
/// - `dayTrip` / `nearbyStay` (APPEND) : aucun jour retiré → ALLOW.
/// - `splitSegment` / `splitGatewaySequence` (SPLIT) : les `suggestedTotal`
///   premiers jours de l'anchor sont retirés. BLOCK si une résa hôtel à
///   l'anchor city couvre l'une de ces nuits.
/// - `replaceAnchorGateway` (REPLACE) : TOUS les jours de l'anchor sont
///   retirés. BLOCK si une résa hôtel à l'anchor city couvre l'une de ces
///   nuits. (Cas typique : le user sleeps réellement à Hanoï tous les
///   jours du segment → on ne peut pas remplacer Hanoï par Ninh Bình
///   silencieusement.)
SuggestionPreflight preflightDatePrecise({
  required SubTripSuggestion suggestion,
  required List<TripSegment> currentSegments,
  required DateTime tripStartDate,
  required List<TripDocument> docs,
}) {
  // Trouve le 1er segment matchant l'anchor (cohérent avec
  // `computeMutation` qui fait pareil).
  final anchorNorm = _normalize(suggestion.anchorCity);
  final ranges = _computeSegmentRanges(currentSegments, tripStartDate);
  _SegmentDateRange? anchorRange;
  for (final r in ranges) {
    if (_normalize(r.city) == anchorNorm) {
      anchorRange = r;
      break;
    }
  }
  if (anchorRange == null) {
    // Pas d'anchor → rien à vérifier (le `computeMutation` lèvera
    // anchorNotFound de toute façon côté caller).
    return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
  }

  // Identifie les nuits "retirées à l'anchor" selon le mode.
  final nightsRemoved = <DateTime>[];
  switch (suggestion.insertionMode) {
    case InsertionMode.dayTrip:
    case InsertionMode.nearbyStay:
      // APPEND : aucune nuit retirée à l'anchor.
      return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
    case InsertionMode.splitSegment:
    case InsertionMode.splitGatewaySequence:
      // Les `suggestedTotal` premières nuits de l'anchor sont
      // réattribuées à la ville suggérée.
      final n = suggestion.totalSuggestedDays;
      for (var i = 0; i < n; i++) {
        nightsRemoved.add(anchorRange.firstDay.add(Duration(days: i)));
      }
      break;
    case InsertionMode.replaceAnchorGateway:
      // Toutes les nuits de l'anchor sont retirées (anchor disparaît).
      var d = anchorRange.firstDay;
      while (!d.isAfter(anchorRange.lastNight)) {
        nightsRemoved.add(d);
        d = d.add(const Duration(days: 1));
      }
      break;
  }

  if (nightsRemoved.isEmpty) {
    return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
  }

  // Pour chaque hôtel à l'anchor city : check si une nuit couverte
  // tombe dans `nightsRemoved`. Si oui → BLOCK.
  for (final d in docs) {
    if (d.category != DocumentCategory.hotel) continue;
    if (!_hotelDocMatchesCity(d, suggestion.anchorCity)) continue;
    final ci = _parseDate(d.metadata['check_in']);
    final co = _parseDate(d.metadata['check_out']);
    if (ci == null || co == null) continue;
    for (final night in nightsRemoved) {
      if (_isNightCoveredByStay(night, ci, co)) {
        final dStr = '${night.day.toString().padLeft(2, '0')}/'
            '${night.month.toString().padLeft(2, '0')}';
        return SuggestionPreflight(
          verdict: SuggestionVerdict.block,
          notice:
              'Tu as une réservation d\'hôtel à ${suggestion.anchorCity} '
              'qui couvre la nuit du $dStr. Cette modification entrerait '
              'en conflit avec ton hébergement.',
        );
      }
    }
  }

  return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
}

/// Vrai si le voyage a un point d'arrivée daté FIABLE pour `city`.
/// Sources acceptées (Lalith 2026-05-08, MVP safety rule pour
/// `splitGatewaySequence`) :
/// - vol/train/etc. avec `to_city` matchant `city` ET date parseable
/// - hôtel à `city` avec `check_in` parseable
///
/// Sans signal fiable, on ne sait pas QUAND l'utilisateur arrive
/// vraiment dans la ville-gateway → un SPLIT depuis le début du
/// segment risque de produire des dates aberrantes (ex: Rayong au
/// jour J0 du voyage alors que le user vient juste d'atterrir à
/// Bangkok). Pour le MVP on REFUSE simplement la suggestion plutôt
/// que de positionner aléatoirement.
bool hasReliableArrivalAnchor(String city, List<TripDocument> docs) {
  final norm = _normalize(city);
  if (norm.isEmpty) return false;
  for (final d in docs) {
    // Transport vers la ville → arrival anchor direct.
    if (d.category == DocumentCategory.flight ||
        d.category == DocumentCategory.train) {
      final to = (d.metadata['to_city'] as String?)?.trim();
      if (to != null && _normalize(to) == norm) {
        if (_parseDate(d.metadata['date']) != null) return true;
      }
    }
    // Hôtel à la ville → check-in date est un anchor indicatif fiable
    // (l'utilisateur dort dans la ville, donc y est arrivé au plus
    // tard à check-in).
    if (d.category == DocumentCategory.hotel &&
        _hotelDocMatchesCity(d, city) &&
        _parseDate(d.metadata['check_in']) != null) {
      return true;
    }
  }
  return false;
}

/// Vrai si un doc hôtel matche `city` (réplique stricte de la logique de
/// `_hasHotelInCity` mais pour 1 doc à la fois — sert au date-precise
/// detector qui itère sur les docs).
bool _hotelDocMatchesCity(TripDocument d, String city) {
  if (d.category != DocumentCategory.hotel) return false;
  final norm = _normalize(city);
  if (norm.isEmpty) return false;
  final m = d.metadata;
  final structuredCity = (m['address_city'] as String?)?.trim();
  if (structuredCity != null && structuredCity.isNotEmpty) {
    if (_normalize(structuredCity) == norm) return true;
  }
  final address = (m['address'] as String?)?.trim();
  if (address != null && address.isNotEmpty) {
    final normAddr = _normalize(address);
    final pattern = RegExp(
      r'(^|[\s,;\-])' + RegExp.escape(norm) + r'($|[\s,;\-])',
    );
    if (pattern.hasMatch(normAddr)) return true;
  }
  return false;
}

/// Parse une date depuis metadata (peut être `String` ISO ou `DateTime`).
DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

