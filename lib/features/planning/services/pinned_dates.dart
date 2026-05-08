/// Analyse des dates "pinned" du voyage : pour chaque segment, dates de
/// début/fin et flags indiquant si l'arrivée ou le départ est ancré par
/// un transport daté (vol/train), plus les ranges hôtels.
///
/// V2 "Affiner les étapes" — Lot V2.1 : avant d'appliquer une suggestion
/// qui consomme des nuits dans un segment ancrage (ex: insérer Krabi 3n
/// dans Bangkok 11n), Lunao doit savoir quelles dates de début sont
/// valides pour ne pas shifter les transports/hébergements aval.
///
/// Règle produit non négociable (Lalith 2026-05-08) : une mutation ne
/// doit JAMAIS shifter une date dérivée d'un doc.
library;

import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';

class HotelStay {
  /// 1ère nuit dormie (inclusif).
  final DateTime checkIn;

  /// Lendemain matin du dernier jour dormi (exclusif). Convention alignée
  /// sur les hôtels : `[checkIn, checkOutExclusive)` couvre les nuits.
  final DateTime checkOutExclusive;

  const HotelStay({required this.checkIn, required this.checkOutExclusive});
}

class SegmentPinnedDates {
  final int segmentIndex;
  final String city;

  /// Première nuit (inclusif) calculée par cumul depuis `trip.startDate`.
  /// Représente l'offset théorique du segment dans le voyage. Pour la
  /// disponibilité réelle de la ville (cas vol overnight Lux→BKK qui
  /// décolle 21/06 et atterrit 22/06), utiliser `effectiveStartDate`.
  final DateTime startDate;

  /// V2.3 — Première date à laquelle l'utilisateur est RÉELLEMENT à
  /// `city`. Égale à `startDate` par défaut, mais avancée à la date
  /// d'arrivée du transport entrant si celui-ci la spécifie
  /// (`metadata['arrival_date']`, fallback sur `metadata['date']`).
  ///
  /// Lalith 2026-05-08 — règle produit : la date de DÉPART d'un
  /// transport ne rend pas la destination disponible. Seule la date
  /// d'ARRIVÉE le fait. Pour Lux→BKK qui décolle 21/06 et atterrit
  /// 22/06, Bangkok n'est pas exploitable le 21/06.
  final DateTime effectiveStartDate;

  /// Lendemain matin du dernier jour à cette ville (exclusif).
  final DateTime endDateExclusive;

  /// Durée totale du segment (= jours du `TripSegment`).
  final int days;

  /// Vrai si un transport (vol/train) entrant a sa date d'arrivée
  /// (`arrival_date` si présent, sinon `date`) qui matche `startDate`.
  /// Champ informatif post-refactor 2026-05-08 (les contraintes "≥1
  /// nuit" ont été retirées) — laissé pour usage futur (UX, debug).
  final bool startPinned;

  /// Vrai si un transport (vol/train) avec `from_city == segment.city` a
  /// sa `date == endDateExclusive`. Champ informatif (idem).
  final bool endPinned;

  /// Hébergements rattachés à `city`. Les nuits couvertes ne peuvent pas
  /// être réattribuées à une autre ville par une insertion.
  final List<HotelStay> hotelRanges;

  const SegmentPinnedDates({
    required this.segmentIndex,
    required this.city,
    required this.startDate,
    required this.effectiveStartDate,
    required this.endDateExclusive,
    required this.days,
    required this.startPinned,
    required this.endPinned,
    required this.hotelRanges,
  });
}

class PinnedDatesAnalysis {
  final List<SegmentPinnedDates> segments;

  const PinnedDatesAnalysis(this.segments);

  /// Premier segment dont la ville matche `city` (insensible casse/accents).
  SegmentPinnedDates? forCity(String city) {
    final norm = _normalize(city);
    if (norm.isEmpty) return null;
    for (final s in segments) {
      if (_normalize(s.city) == norm) return s;
    }
    return null;
  }
}

/// Calcule la plage de dates et les ancres (transports + hôtels) pour
/// chaque segment. Le 1er segment commence à `tripStartDate`, les
/// suivants enchaînent sur la durée cumulée des précédents.
PinnedDatesAnalysis analyzePinnedDates({
  required List<TripSegment> segments,
  required DateTime tripStartDate,
  required List<TripDocument> docs,
}) {
  final result = <SegmentPinnedDates>[];
  var cursor = tripStartDate;
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    final start = cursor;
    final endExcl = cursor.add(Duration(days: s.days));

    final incomingArrival = _earliestIncomingArrivalAt(
      docs: docs,
      city: s.city,
      windowStart: start,
      windowEndExcl: endExcl,
    );
    final effectiveStart =
        incomingArrival != null && incomingArrival.isAfter(_dateOnly(start))
            ? incomingArrival
            : start;

    final startPinned = _hasTransportOn(
      docs: docs,
      cityField: 'to_city',
      city: s.city,
      date: start,
    );
    final endPinned = _hasTransportOn(
      docs: docs,
      cityField: 'from_city',
      city: s.city,
      date: endExcl,
    );
    final hotels = _hotelStaysAtCity(docs: docs, city: s.city);

    result.add(SegmentPinnedDates(
      segmentIndex: i,
      city: s.city,
      startDate: start,
      effectiveStartDate: effectiveStart,
      endDateExclusive: endExcl,
      days: s.days,
      startPinned: startPinned,
      endPinned: endPinned,
      hotelRanges: hotels,
    ));
    cursor = endExcl;
  }
  return PinnedDatesAnalysis(result);
}

/// Énumère toutes les dates de début d'insertion valides pour insérer
/// `insertionDays` nuits dans le segment ancrage `anchorCity`. Liste vide
/// si l'ancrage est introuvable, si la durée est invalide, ou si aucune
/// date ne satisfait toutes les contraintes.
List<DateTime> validInsertionStartDates({
  required String anchorCity,
  required int insertionDays,
  required PinnedDatesAnalysis analysis,
  int? anchorSegmentIndex,
}) {
  final anchor = _resolveAnchor(analysis, anchorCity, anchorSegmentIndex);
  if (anchor == null || insertionDays <= 0) return const [];
  final out = <DateTime>[];
  final lastStart = anchor.endDateExclusive.subtract(
    Duration(days: insertionDays),
  );
  // V2.3 — borne basse = effectiveStartDate (post-arrivée), pas startDate
  // (qui peut tomber en plein transit pour un vol overnight).
  var d = anchor.effectiveStartDate;
  while (!_dateOnly(d).isAfter(_dateOnly(lastStart))) {
    final reason = validateInsertionDate(
      anchorCity: anchorCity,
      insertionStartDate: d,
      insertionDays: insertionDays,
      analysis: analysis,
      anchorSegmentIndex: anchorSegmentIndex,
    );
    if (reason == null) out.add(d);
    d = d.add(const Duration(days: 1));
  }
  return out;
}

/// V2 (bug fix Bangkok dupliqué) — résolution du segment ancrage. Si
/// `anchorSegmentIndex` est fourni et valide, l'utilise (priorité). Sinon
/// fallback `forCity` (premier match) — comportement legacy.
SegmentPinnedDates? _resolveAnchor(
  PinnedDatesAnalysis analysis,
  String anchorCity,
  int? anchorSegmentIndex,
) {
  if (anchorSegmentIndex != null &&
      anchorSegmentIndex >= 0 &&
      anchorSegmentIndex < analysis.segments.length) {
    return analysis.segments[anchorSegmentIndex];
  }
  return analysis.forCity(anchorCity);
}

/// Retourne `null` si l'insertion (`insertionStartDate` pour
/// `insertionDays` nuits dans `anchorCity`) est valide. Sinon, une raison
/// humaine en français prête à afficher.
///
/// Contraintes vérifiées dans l'ordre :
/// 1. La date est ≥ `effectiveStartDate` du segment ancrage (= date
///    réelle de présence à la ville, post-arrivée transport).
/// 2. La date + durée est ≤ fin (exclusive) du segment ancrage.
/// 3. L'insertion ne chevauche aucun hôtel à l'ancrage.
///
/// Lalith 2026-05-08 : ne PAS forcer "≥1 nuit avant/après transport
/// pinné". Si l'utilisateur n'a pas réservé d'hôtel à l'ancrage et n'a
/// pas d'autre doc qui ancre la nuit, il est libre de partir le jour
/// même de l'arrivée ou de rentrer le jour du départ pinné. Le filtre
/// hôtel (#3) couvre déjà les nuits réellement réservées à l'ancrage.
///
/// Lalith 2026-05-08 (correction transit) : la date de DÉPART d'un
/// transport vers la ville ne rend pas la ville disponible — seule la
/// date d'ARRIVÉE le fait. `effectiveStartDate` capte ça via
/// `metadata['arrival_date']` (fallback `metadata['date']`).
String? validateInsertionDate({
  required String anchorCity,
  required DateTime insertionStartDate,
  required int insertionDays,
  required PinnedDatesAnalysis analysis,
  int? anchorSegmentIndex,
}) {
  final anchor = _resolveAnchor(analysis, anchorCity, anchorSegmentIndex);
  if (anchor == null) {
    return 'Étape "$anchorCity" introuvable dans le voyage.';
  }
  if (insertionDays <= 0) {
    return 'Durée d\'insertion invalide.';
  }

  final insertStart = _dateOnly(insertionStartDate);
  final insertEndExcl = insertStart.add(Duration(days: insertionDays));
  final effectiveStart = _dateOnly(anchor.effectiveStartDate);
  final anchorEndExcl = _dateOnly(anchor.endDateExclusive);

  if (insertStart.isBefore(effectiveStart)) {
    return 'Tu n\'es pas encore à $anchorCity le '
        '${_fmtDate(insertionStartDate)} — première date possible : '
        '${_fmtDate(anchor.effectiveStartDate)}.';
  }
  if (insertEndExcl.isAfter(anchorEndExcl)) {
    return 'L\'insertion dépasse la fin de l\'étape $anchorCity '
        '(${_fmtDate(anchor.endDateExclusive)}).';
  }

  for (final stay in anchor.hotelRanges) {
    if (_rangesOverlap(
      insertStart, insertEndExcl,
      _dateOnly(stay.checkIn), _dateOnly(stay.checkOutExclusive),
    )) {
      return 'Tu as une réservation d\'hôtel à $anchorCity du '
          '${_fmtDate(stay.checkIn)} au ${_fmtDate(stay.checkOutExclusive)} — '
          'l\'insertion entrerait en conflit.';
    }
  }

  return null;
}

// ─── Internals ────────────────────────────────────────────────────────

bool _hasTransportOn({
  required List<TripDocument> docs,
  required String cityField,
  required String city,
  required DateTime date,
}) {
  final normCity = _normalize(city);
  if (normCity.isEmpty) return false;
  final target = _dateOnly(date);
  for (final d in docs) {
    if (d.category != DocumentCategory.flight &&
        d.category != DocumentCategory.train) {
      continue;
    }
    final c = (d.metadata[cityField] as String?)?.trim();
    if (c == null || _normalize(c) != normCity) continue;
    final dt = _parseDate(d.metadata['date']);
    if (dt == null) continue;
    if (_dateOnly(dt) == target) return true;
  }
  return false;
}

/// Plus tôt date d'arrivée d'un transport entrant à `city` dans la
/// fenêtre `[windowStart, windowEndExcl)`. Délègue à
/// `arrivalDateFromMetadata` (préfère `arrival_date` explicite, sinon
/// infère via la règle J+1 si `arrival_time < departure_time`).
DateTime? _earliestIncomingArrivalAt({
  required List<TripDocument> docs,
  required String city,
  required DateTime windowStart,
  required DateTime windowEndExcl,
}) {
  final norm = _normalize(city);
  if (norm.isEmpty) return null;
  final wStart = _dateOnly(windowStart);
  final wEnd = _dateOnly(windowEndExcl);
  DateTime? earliest;
  for (final d in docs) {
    if (d.category != DocumentCategory.flight &&
        d.category != DocumentCategory.train) {
      continue;
    }
    final to = (d.metadata['to_city'] as String?)?.trim();
    if (to == null || _normalize(to) != norm) continue;
    final arrival = arrivalDateFromMetadata(d.metadata);
    if (arrival == null) continue;
    final dt = _dateOnly(arrival);
    if (dt.isBefore(wStart) || !dt.isBefore(wEnd)) continue;
    if (earliest == null || dt.isBefore(earliest)) earliest = dt;
  }
  return earliest;
}

List<HotelStay> _hotelStaysAtCity({
  required List<TripDocument> docs,
  required String city,
}) {
  final out = <HotelStay>[];
  for (final d in docs) {
    if (d.category != DocumentCategory.hotel) continue;
    if (!_hotelMatchesCity(d, city)) continue;
    final ci = _parseDate(d.metadata['check_in']);
    final co = _parseDate(d.metadata['check_out']);
    if (ci == null || co == null) continue;
    out.add(HotelStay(checkIn: ci, checkOutExclusive: co));
  }
  return out;
}

bool _hotelMatchesCity(TripDocument d, String city) {
  final norm = _normalize(city);
  if (norm.isEmpty) return false;
  final m = d.metadata;
  final structured = (m['address_city'] as String?)?.trim();
  if (structured != null && structured.isNotEmpty) {
    if (_normalize(structured) == norm) return true;
  }
  final address = (m['address'] as String?)?.trim();
  if (address != null && address.isNotEmpty) {
    final pattern = RegExp(
      r'(^|[\s,;\-])' + RegExp.escape(norm) + r'($|[\s,;\-])',
    );
    if (pattern.hasMatch(_normalize(address))) return true;
  }
  return false;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool _rangesOverlap(
  DateTime aStart, DateTime aEndExcl,
  DateTime bStart, DateTime bEndExcl,
) =>
    aStart.isBefore(bEndExcl) && bStart.isBefore(aEndExcl);

String _fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

/// Réplique locale du `_normalize` de `sub_trip_conflict_detector.dart`
/// (couple faible : on évite d'exposer un helper privé inter-services).
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
