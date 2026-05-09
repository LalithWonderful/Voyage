/// Détection de conflits entre documents de voyage (Phase B
/// Lalith 2026-05-09).
///
/// Service pur, sans UI ni dépendance Flutter. Retourne une liste de
/// `DocumentConflict` qu'une bannière "Points à vérifier" pourra
/// afficher (Phase C, hors scope ici). Aucune correction automatique.
///
/// Règle produit : les documents datés sont la source de vérité. Si on
/// détecte une incohérence, on alerte l'utilisateur — c'est lui qui
/// corrige le doc (suppression, édition des dates).
///
/// Conflits couverts :
/// 1. `overlappingTransports` — 2 vols/trains dont les intervalles
///    [départ, arrivée] se chevauchent.
/// 2. `hotelDuringAbsence` — un hôtel à ville X couvre des nuits où la
///    timeline des transports montre que l'utilisateur est ailleurs.
/// 3. `segmentArrivalMismatch` — la date de début d'un segment dans
///    l'itinéraire diffère de la date d'arrivée effective du transport
///    qui le pinne.
///
/// Hors scope :
/// - Conflits déjà gérés par d'autres services :
///   `wouldShiftPinnedDownstream` (mutation), `isNightResolved`
///   (overlap hôtels même ville).
/// - Conflits "soft" type "ton vol décolle 23:30, ton hôtel a checkout
///   12:00" — pas de heure check-out tracking pour l'instant.
library;

import 'package:voyage/features/planning/services/pinned_dates.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';

/// Type de conflit détecté entre documents.
enum ConflictType {
  /// Deux transports (vol/train) dont les intervalles temporels se
  /// chevauchent. Le voyageur ne peut pas être dans deux moyens de
  /// transport en même temps.
  overlappingTransports,

  /// Un hôtel couvre une ou plusieurs nuits où la timeline des
  /// transports place le voyageur dans une autre ville. La réservation
  /// n'est pas erronée en soi (cas appart longue durée valide), mais
  /// elle mérite une vérification.
  hotelDuringAbsence,

  /// La date de début d'un segment dans l'itinéraire ne correspond pas
  /// à la date d'arrivée effective du transport qui pinne ce segment.
  /// Ex : segment Bangkok 21/06 alors que le vol arrive le 22/06.
  segmentArrivalMismatch,

  /// Un transport (vol/train) référence une ville (côté arrivée ou
  /// côté départ) pour laquelle l'itinéraire ne contient AUCUN segment.
  /// Cas typique : l'utilisateur a supprimé une étape doc-linked sans
  /// supprimer le document source — le doc reste orphelin dans le
  /// wallet et la timeline est incohérente.
  /// Ex : « Ton vol arrive à Phú Quốc le 03/07, mais aucune étape
  /// Phú Quốc n'est prévue dans ton itinéraire. »
  missingSegmentForTransport,
}

/// Description structurée d'un conflit détecté. La phase UI (Phase C)
/// affichera ces objets dans une bannière "Points à vérifier" — chaque
/// conflit porte un message FR humain prêt à afficher + les ids des
/// documents/segments concernés pour permettre une navigation directe.
class DocumentConflict {
  final ConflictType type;
  final String message;

  /// IDs des documents impliqués (peut être vide si le conflit
  /// concerne un segment seulement).
  final List<String> docIds;

  /// Index du segment impliqué (null si conflit purement inter-doc).
  final int? segmentIndex;

  const DocumentConflict({
    required this.type,
    required this.message,
    required this.docIds,
    this.segmentIndex,
  });
}

/// Point d'entrée principal — détecte tous les conflits dans la
/// triplet (docs, segments, tripStartDate). Utilisé par la future
/// bannière "Points à vérifier".
///
/// Comportement : ne lève jamais d'exception. Si les données sont
/// partielles (ex : doc sans date), le conflit n'est simplement pas
/// remonté pour ce doc.
List<DocumentConflict> detectDocumentConflicts({
  required List<TripDocument> docs,
  required List<TripSegment> segments,
  required DateTime tripStartDate,
}) {
  final conflicts = <DocumentConflict>[];
  conflicts.addAll(_detectTransportOverlaps(docs));
  conflicts.addAll(_detectHotelDuringAbsence(docs));
  if (segments.isNotEmpty) {
    final analysis = analyzePinnedDates(
      segments: segments,
      tripStartDate: tripStartDate,
      docs: docs,
    );
    conflicts.addAll(_detectSegmentArrivalMismatch(analysis));
    conflicts.addAll(_detectMissingSegmentForTransport(
      docs: docs,
      segments: segments,
      tripStartDate: tripStartDate,
    ));
  }
  return conflicts;
}

// ─── 1. Transports qui se chevauchent ────────────────────────────────

/// Pour chaque paire (vol/train, vol/train) du voyage, vérifie si leurs
/// intervalles [departure_date, arrival_date] s'intersectent. La
/// résolution est journée (pas horaire) : "deux transports le même jour"
/// est flaggé même s'ils sont à 8h d'intervalle. Suffisant pour le
/// warning MVP — Lalith trade UX clarté > précision horaire.
List<DocumentConflict> _detectTransportOverlaps(List<TripDocument> docs) {
  final out = <DocumentConflict>[];
  final transports = docs
      .where((d) =>
          d.category == DocumentCategory.flight ||
          d.category == DocumentCategory.train)
      .toList();
  for (var i = 0; i < transports.length; i++) {
    for (var j = i + 1; j < transports.length; j++) {
      final a = transports[i];
      final b = transports[j];
      final aRange = _transportDateRange(a);
      final bRange = _transportDateRange(b);
      if (aRange == null || bRange == null) continue;
      // Overlap [aDep, aArr] ∩ [bDep, bArr] ≠ ∅ (inclusif des deux côtés
      // car résolution journée).
      if (!aRange.end.isBefore(bRange.start) &&
          !bRange.end.isBefore(aRange.start)) {
        final dateLabel = _fmtDate(_max(aRange.start, bRange.start));
        out.add(DocumentConflict(
          type: ConflictType.overlappingTransports,
          message:
              'Deux transports semblent se chevaucher autour du $dateLabel '
              '(${a.name} et ${b.name}). Vérifie les dates.',
          docIds: [a.id, b.id],
        ));
      }
    }
  }
  return out;
}

/// Plage [départ, arrivée] inclusive d'un doc transport. Null si la
/// `date` (= départ) n'est pas parsable.
({DateTime start, DateTime end})? _transportDateRange(TripDocument t) {
  final dep = _parseDate(t.metadata['date']);
  if (dep == null) return null;
  final arr = arrivalDateFromMetadata(t.metadata) ?? dep;
  return (start: _dateOnly(dep), end: _dateOnly(arr));
}

// ─── 2. Hôtel pendant une absence ────────────────────────────────────

/// Pour chaque hôtel, parcourt ses nuits couvertes et vérifie où la
/// timeline des transports place le voyageur. Une nuit où l'utilisateur
/// est ailleurs que dans la ville de l'hôtel est un "phantom night"
/// (cas typique : appart longue durée valide à Bangkok mais voyage
/// 5 nuits à Phú Quốc — pas faux mais à vérifier).
List<DocumentConflict> _detectHotelDuringAbsence(List<TripDocument> docs) {
  final out = <DocumentConflict>[];
  final hotels =
      docs.where((d) => d.category == DocumentCategory.hotel).toList();
  final transports = docs
      .where((d) =>
          d.category == DocumentCategory.flight ||
          d.category == DocumentCategory.train)
      .toList();
  if (hotels.isEmpty || transports.isEmpty) return out;

  final timeline = _buildLocationTimeline(transports);
  if (timeline.isEmpty) return out;

  for (final h in hotels) {
    final ci = _parseDate(h.metadata['check_in']);
    final co = _parseDate(h.metadata['check_out']);
    final hotelCity = _hotelCity(h);
    if (ci == null || co == null || hotelCity == null) continue;

    // Pour chaque nuit [ci, co), regarde la ville attendue.
    final phantomNights = <DateTime>[];
    for (var n = _dateOnly(ci);
        n.isBefore(_dateOnly(co));
        n = n.add(const Duration(days: 1))) {
      final expected = _userCityOnNight(n, timeline);
      if (expected == null) continue; // pas de signal, on s'abstient
      if (!_cityMatches(expected, hotelCity)) {
        phantomNights.add(n);
      }
    }
    if (phantomNights.isNotEmpty) {
      final firstStr = _fmtDate(phantomNights.first);
      final lastStr = _fmtDate(phantomNights.last);
      final span = phantomNights.length == 1
          ? 'la nuit du $firstStr'
          : 'des nuits du $firstStr au $lastStr';
      out.add(DocumentConflict(
        type: ConflictType.hotelDuringAbsence,
        message:
            'Ton hôtel à $hotelCity (${h.name}) couvre $span, mais tes '
            'transports indiquent que tu es ailleurs ces nuits-là.',
        docIds: [h.id],
      ));
    }
  }
  return out;
}

/// Une entrée timeline : à partir de `fromDay` (date de départ
/// inclusive), l'utilisateur est à `city`. Triée par `fromDay`.
class _LocationEntry {
  final DateTime fromDay;
  final String city;
  const _LocationEntry({required this.fromDay, required this.city});
}

List<_LocationEntry> _buildLocationTimeline(List<TripDocument> transports) {
  final entries = <_LocationEntry>[];
  for (final t in transports) {
    final dep = _parseDate(t.metadata['date']);
    final toCity = (t.metadata['to_city'] as String?)?.trim();
    if (dep == null || toCity == null || toCity.isEmpty) continue;
    entries.add(_LocationEntry(fromDay: _dateOnly(dep), city: toCity));
  }
  entries.sort((a, b) => a.fromDay.compareTo(b.fromDay));
  return entries;
}

/// Ville où l'utilisateur dort la nuit du jour `night`. Convention :
/// le départ d'un transport le jour J place l'utilisateur à la
/// destination la nuit du jour J (= il dort à destination après le
/// trajet). Retourne null si aucun transport n'est antérieur (pas de
/// signal, on ne peut pas conclure).
String? _userCityOnNight(DateTime night, List<_LocationEntry> timeline) {
  String? city;
  final n = _dateOnly(night);
  for (final e in timeline) {
    if (!e.fromDay.isAfter(n)) {
      city = e.city;
    } else {
      break;
    }
  }
  return city;
}

// ─── 3. Segment vs date d'arrivée transport ──────────────────────────

/// Si la date d'arrivée effective d'un segment (calculée à partir des
/// transports entrants via `effectiveStartDate`) est strictement après
/// sa date cumulative `startDate`, c'est que l'itinéraire et les docs
/// ne s'accordent pas sur le début du séjour.
List<DocumentConflict> _detectSegmentArrivalMismatch(
  PinnedDatesAnalysis analysis,
) {
  final out = <DocumentConflict>[];
  for (final seg in analysis.segments) {
    final start = _dateOnly(seg.startDate);
    final eff = _dateOnly(seg.effectiveStartDate);
    if (eff.isAfter(start)) {
      out.add(DocumentConflict(
        type: ConflictType.segmentArrivalMismatch,
        message:
            'L\'étape ${seg.city} commence le ${_fmtDate(seg.startDate)} dans '
            'ton itinéraire, mais ton transport y arrive le '
            '${_fmtDate(seg.effectiveStartDate)}. Décale le début de '
            'l\'étape ou ajuste le transport.',
        docIds: const [],
        segmentIndex: seg.segmentIndex,
      ));
    }
  }
  return out;
}

// ─── 4. Transport orphelin (segment manquant) ────────────────────────

/// Pour chaque vol/train, vérifie qu'une étape couvre la ville d'arrivée
/// ET la ville de départ. Si une de ces villes n'est PAS dans
/// l'itinéraire, on remonte un conflit — le voyageur a probablement
/// supprimé une étape doc-linked sans archiver/supprimer le document
/// source.
///
/// V5 (Lalith 2026-05-10 — Lot B) — la couverture peut désormais venir
/// d'une étape window-linked dont `sourceAnchorCity` matche la ville
/// du transport et dont la fenêtre couvre la date du transport. Cas
/// type : Hội An (sourceAnchorCity = Da Nang) couvre 12/07–15/07 →
/// le vol Da Nang du 12/07 ne déclenche PLUS « aucune étape Da Nang ».
/// Sémantique « gateway » : le voyageur ne dort pas à Da Nang mais
/// passe par Da Nang (aéroport) pour rejoindre Hội An.
///
/// Filtre des « jambes domicile » : le 1er transport chronologique
/// (= vol aller depuis l'aéroport home) et le dernier (= vol retour
/// vers home) ne sont PAS flaggés sur leur côté externe (resp. départ
/// et arrivée). Sans ça, le vol Luxembourg → Bangkok produirait une
/// fausse alerte « aucune étape Luxembourg ».
///
/// Heuristique : on ne tient compte que de la position chronologique
/// 1ère/dernière dans la liste TRIÉE des transports. Tous les transports
/// au milieu (= intra-voyage) sont flaggés des 2 côtés si manquants.
List<DocumentConflict> _detectMissingSegmentForTransport({
  required List<TripDocument> docs,
  required List<TripSegment> segments,
  required DateTime tripStartDate,
}) {
  final out = <DocumentConflict>[];
  if (segments.isEmpty) return out;

  // Set des villes (normalisées) avec au moins un segment couvrant.
  final segmentCities = <String>{};
  for (final s in segments) {
    segmentCities.add(_normalizeCity(s.city));
  }

  // V5 — fenêtres window-linked indexées par sourceAnchorCity normalisée.
  // Chaque entry = { gateway, [start, endInclusive] }. Convention bornes
  // INCLUSIVES des deux côtés : le jour de départ d'une étape (= jour
  // de transit/transfer) compte comme couvrant le transport vers la
  // gateway. Cas typique : Hội An termine 15/07 → le vol Da Nang→BKK
  // du 15/07 est couvert.
  final windowGateways =
      <({String anchorNorm, DateTime start, DateTime endInclusive})>[];
  var offset = 0;
  for (final s in segments) {
    final src = (s.sourceAnchorCity ?? '').trim();
    if (src.isNotEmpty) {
      final start = _dateOnly(tripStartDate.add(Duration(days: offset)));
      final endIncl =
          _dateOnly(tripStartDate.add(Duration(days: offset + s.days)));
      windowGateways.add((
        anchorNorm: _normalizeCity(src),
        start: start,
        endInclusive: endIncl,
      ));
    }
    offset += s.days;
  }

  bool gatewayCovers(String cityNorm, DateTime date) {
    final d = _dateOnly(date);
    for (final w in windowGateways) {
      if (w.anchorNorm != cityNorm) continue;
      if (!d.isBefore(w.start) && !d.isAfter(w.endInclusive)) return true;
    }
    return false;
  }

  // Transports triés chronologiquement par date de départ. Les bornes
  // (1er / dernier) sont considérées comme jambes domicile.
  final transports = docs
      .where((d) =>
          d.category == DocumentCategory.flight ||
          d.category == DocumentCategory.train)
      .where((d) => _parseDate(d.metadata['date']) != null)
      .toList()
    ..sort((a, b) =>
        _parseDate(a.metadata['date'])!
            .compareTo(_parseDate(b.metadata['date'])!));
  if (transports.isEmpty) return out;

  for (var i = 0; i < transports.length; i++) {
    final t = transports[i];
    final m = t.metadata;
    final fromCity = (m['from_city'] as String?)?.trim();
    final toCity = (m['to_city'] as String?)?.trim();
    final dep = _parseDate(m['date']);
    final arr = arrivalDateFromMetadata(m) ?? dep;

    final isFirst = i == 0;
    final isLast = i == transports.length - 1;

    // Côté ARRIVÉE : on flag si to_city manque dans les segments ET
    // qu'aucune fenêtre window-linked vers cette gateway ne couvre
    // l'arrivée. Sauf pour le dernier transport (= retour vers home).
    if (!isLast && toCity != null && toCity.isNotEmpty && arr != null) {
      final toNorm = _normalizeCity(toCity);
      final hasCity = segmentCities.contains(toNorm);
      final hasGateway = !hasCity && gatewayCovers(toNorm, arr);
      if (!hasCity && !hasGateway) {
        out.add(DocumentConflict(
          type: ConflictType.missingSegmentForTransport,
          message:
              'Ton vol arrive à $toCity le ${_fmtDate(arr)}, mais aucune '
              'étape $toCity n\'est prévue dans ton itinéraire.',
          docIds: [t.id],
        ));
      }
    }

    // Côté DÉPART : idem mais avec la date de départ. Sauf pour le 1er
    // transport (= aller depuis home).
    if (!isFirst && fromCity != null && fromCity.isNotEmpty && dep != null) {
      final fromNorm = _normalizeCity(fromCity);
      final hasCity = segmentCities.contains(fromNorm);
      final hasGateway = !hasCity && gatewayCovers(fromNorm, dep);
      if (!hasCity && !hasGateway) {
        out.add(DocumentConflict(
          type: ConflictType.missingSegmentForTransport,
          message:
              'Ton vol part de $fromCity le ${_fmtDate(dep)}, mais aucune '
              'étape $fromCity n\'est prévue dans ton itinéraire.',
          docIds: [t.id],
        ));
      }
    }
  }
  return out;
}

// ─── Helpers internes ────────────────────────────────────────────────

bool _cityMatches(String a, String b) =>
    _normalizeCity(a) == _normalizeCity(b);

String? _hotelCity(TripDocument h) {
  final structured = (h.metadata['address_city'] as String?)?.trim();
  if (structured != null && structured.isNotEmpty) return structured;
  // Fallback minimal : pas d'extraction d'adresse libre ici, on
  // s'abstient si address_city est absent (cohérent avec le reste du
  // pattern projet où address_city est privilégié).
  return null;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _max(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

String _fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Réplique locale du pattern projet (cf. `pinned_dates.dart`,
/// `wallet_provider.dart`, `itinerary_mutation.dart`).
String _normalizeCity(String s) {
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
