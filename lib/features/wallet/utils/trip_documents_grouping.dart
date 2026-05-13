/// Groupement des `TripDocument` par catégorie d'affichage pour l'écran
/// détail voyage.
///
/// Décision UX 2026-05-13 (Lalith) : ne plus empiler tous les documents
/// non-hôtel dans une liste verticale "Autres documents". On regroupe par
/// nature et chaque groupe se présente en carrousel horizontal positionné
/// sur l'élément le plus pertinent à l'instant T.
///
/// Helpers purs, sans dépendance Flutter, sans appel API live, testables
/// unitairement.
library;

import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';

/// Catégorie d'affichage sur le trip detail. Distincte de
/// [DocumentCategory] (granularité fonctionnelle vs granularité métier).
enum TripDocumentGroup {
  accommodation,
  transport,
  ticket,
  other,
}

/// Mapping catégorie métier → groupe d'affichage.
///
/// `car_rental` est rangé dans les transports (mode de déplacement avec
/// date de prise en charge), pas dans les hébergements.
TripDocumentGroup groupOf(TripDocument doc) {
  switch (doc.category) {
    case DocumentCategory.hotel:
      return TripDocumentGroup.accommodation;
    case DocumentCategory.flight:
    case DocumentCategory.train:
    case DocumentCategory.carRental:
      return TripDocumentGroup.transport;
    case DocumentCategory.ticket:
      return TripDocumentGroup.ticket;
    default:
      return TripDocumentGroup.other;
  }
}

/// Résultat de la classification : 4 listes parallèles, jamais de doc
/// perdu (la somme = entrée).
class GroupedTripDocuments {
  final List<TripDocument> accommodations;
  final List<TripDocument> transports;
  final List<TripDocument> tickets;
  final List<TripDocument> others;

  const GroupedTripDocuments({
    required this.accommodations,
    required this.transports,
    required this.tickets,
    required this.others,
  });

  bool get isEmpty =>
      accommodations.isEmpty &&
      transports.isEmpty &&
      tickets.isEmpty &&
      others.isEmpty;
}

/// Classifie les documents puis trie chaque groupe chronologiquement.
GroupedTripDocuments classifyTripDocuments(List<TripDocument> docs) {
  final accommodations = <TripDocument>[];
  final transports = <TripDocument>[];
  final tickets = <TripDocument>[];
  final others = <TripDocument>[];
  for (final d in docs) {
    switch (groupOf(d)) {
      case TripDocumentGroup.accommodation:
        accommodations.add(d);
      case TripDocumentGroup.transport:
        transports.add(d);
      case TripDocumentGroup.ticket:
        tickets.add(d);
      case TripDocumentGroup.other:
        others.add(d);
    }
  }
  return GroupedTripDocuments(
    accommodations: sortAccommodationDocuments(accommodations),
    transports: sortTransportDocuments(transports),
    tickets: sortTicketDocuments(tickets),
    others: others,
  );
}

DateTime? _parseIsoDate(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

DateTime _combineDateAndTime(DateTime date, String? hhmm) {
  if (hhmm == null) return DateTime(date.year, date.month, date.day);
  final parts = hhmm.split(':');
  if (parts.length < 2) return DateTime(date.year, date.month, date.day);
  final h = int.tryParse(parts[0]) ?? 0;
  final m = int.tryParse(parts[1]) ?? 0;
  return DateTime(date.year, date.month, date.day, h, m);
}

/// Date+heure de départ utilisée pour trier et trouver le "prochain"
/// transport. Pour `flight`/`train` : `date` + `departure_time`. Pour
/// `car_rental` : `pickup_date`.
DateTime? transportSortKey(TripDocument doc) {
  final m = doc.metadata;
  if (doc.category == DocumentCategory.carRental) {
    final pickup = _parseIsoDate(m['pickup_date']);
    if (pickup == null) return null;
    return _combineDateAndTime(pickup, m['pickup_time'] as String?);
  }
  final dep = _parseIsoDate(m['date']);
  if (dep == null) return null;
  return _combineDateAndTime(dep, m['departure_time'] as String?);
}

/// Date d'arrivée / fin de pertinence utilisée pour décider si un
/// transport est "passé". Pour `car_rental` : `return_date`. Pour
/// `flight`/`train` : arrivée via [arrivalDateFromMetadata] + heure
/// d'arrivée si disponible.
DateTime? transportEndKey(TripDocument doc) {
  final m = doc.metadata;
  if (doc.category == DocumentCategory.carRental) {
    final r = _parseIsoDate(m['return_date']);
    if (r == null) return null;
    return _combineDateAndTime(r, m['return_time'] as String?);
  }
  final arr = arrivalDateFromMetadata(m);
  if (arr == null) return transportSortKey(doc);
  return _combineDateAndTime(arr, m['arrival_time'] as String?);
}

/// `check_in` d'un hébergement (date pure, sans heure).
DateTime? accommodationStartKey(TripDocument doc) {
  return _parseIsoDate(doc.metadata['check_in']);
}

/// `check_out` d'un hébergement (date pure, sans heure).
DateTime? accommodationEndKey(TripDocument doc) {
  return _parseIsoDate(doc.metadata['check_out']);
}

/// Date+heure d'une réservation/activité (billet, spectacle, musée…).
DateTime? ticketSortKey(TripDocument doc) {
  final d = _parseIsoDate(doc.metadata['date']);
  if (d == null) return null;
  return _combineDateAndTime(d, doc.metadata['time'] as String?);
}

/// Tri stable par clé chrono croissante, `null` en fin de liste.
List<TripDocument> _sortByKey(
  List<TripDocument> docs,
  DateTime? Function(TripDocument) key,
) {
  final indexed = <MapEntry<int, TripDocument>>[
    for (var i = 0; i < docs.length; i++) MapEntry(i, docs[i]),
  ];
  indexed.sort((a, b) {
    final ka = key(a.value);
    final kb = key(b.value);
    if (ka == null && kb == null) return a.key.compareTo(b.key);
    if (ka == null) return 1;
    if (kb == null) return -1;
    final c = ka.compareTo(kb);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return [for (final e in indexed) e.value];
}

List<TripDocument> sortAccommodationDocuments(List<TripDocument> docs) =>
    _sortByKey(docs, accommodationStartKey);

List<TripDocument> sortTransportDocuments(List<TripDocument> docs) =>
    _sortByKey(docs, transportSortKey);

List<TripDocument> sortTicketDocuments(List<TripDocument> docs) =>
    _sortByKey(docs, ticketSortKey);

DateTime _startOfDay(DateTime t) => DateTime(t.year, t.month, t.day);

/// Index initial à afficher dans le carrousel hébergement :
///   1. premier hébergement couvrant aujourd'hui (`ci <= today <= co`) ;
///   2. sinon premier à venir (`ci >= today`) ;
///   3. sinon dernier passé (plus récent `co` strictement avant
///      aujourd'hui) ;
///   4. fallback `0`.
///
/// `sorted` est attendu trié par `check_in` croissant (cf.
/// [sortAccommodationDocuments]).
int findInitialAccommodationIndex(
  List<TripDocument> sorted,
  DateTime now,
) {
  if (sorted.isEmpty) return 0;
  final today = _startOfDay(now);
  for (var i = 0; i < sorted.length; i++) {
    final ci = accommodationStartKey(sorted[i]);
    final co = accommodationEndKey(sorted[i]);
    if (ci == null || co == null) continue;
    final start = _startOfDay(ci);
    final end = _startOfDay(co);
    if (!today.isBefore(start) && !today.isAfter(end)) return i;
  }
  for (var i = 0; i < sorted.length; i++) {
    final ci = accommodationStartKey(sorted[i]);
    if (ci == null) continue;
    if (!_startOfDay(ci).isBefore(today)) return i;
  }
  int? bestIdx;
  DateTime? bestEnd;
  for (var i = 0; i < sorted.length; i++) {
    final co = accommodationEndKey(sorted[i]);
    if (co == null) continue;
    final end = _startOfDay(co);
    if (end.isBefore(today) && (bestEnd == null || end.isAfter(bestEnd))) {
      bestEnd = end;
      bestIdx = i;
    }
  }
  return bestIdx ?? 0;
}

/// Index initial à afficher dans le carrousel transport :
///   1. premier transport à venir (`departure >= now`) ;
///   2. sinon transport le plus récemment terminé (arrivée la plus
///      proche de `now` dans le passé) ;
///   3. fallback `0`.
///
/// `sorted` est attendu trié par départ croissant (cf.
/// [sortTransportDocuments]).
int findInitialTransportIndex(List<TripDocument> sorted, DateTime now) {
  if (sorted.isEmpty) return 0;
  for (var i = 0; i < sorted.length; i++) {
    final dep = transportSortKey(sorted[i]);
    if (dep == null) continue;
    if (!dep.isBefore(now)) return i;
  }
  int? bestIdx;
  DateTime? bestEnd;
  for (var i = 0; i < sorted.length; i++) {
    final end = transportEndKey(sorted[i]);
    if (end == null) continue;
    if (end.isBefore(now) && (bestEnd == null || end.isAfter(bestEnd))) {
      bestEnd = end;
      bestIdx = i;
    }
  }
  return bestIdx ?? 0;
}

/// Index initial à afficher dans le carrousel réservation/activité :
///   1. prochaine réservation (`date+time >= now`) ;
///   2. sinon dernière passée ;
///   3. fallback `0`.
int findInitialTicketIndex(List<TripDocument> sorted, DateTime now) {
  if (sorted.isEmpty) return 0;
  for (var i = 0; i < sorted.length; i++) {
    final t = ticketSortKey(sorted[i]);
    if (t == null) continue;
    if (!t.isBefore(now)) return i;
  }
  int? bestIdx;
  DateTime? bestTime;
  for (var i = 0; i < sorted.length; i++) {
    final t = ticketSortKey(sorted[i]);
    if (t == null) continue;
    if (t.isBefore(now) && (bestTime == null || t.isAfter(bestTime))) {
      bestTime = t;
      bestIdx = i;
    }
  }
  return bestIdx ?? 0;
}

/// État d'un élément carrousel par rapport à `now` — sert au badge
/// "en cours / à venir / passé" affiché dans la card.
enum TripDocumentStatus { current, upcoming, past, unknown }

TripDocumentStatus accommodationStatus(TripDocument doc, DateTime now) {
  final ci = accommodationStartKey(doc);
  final co = accommodationEndKey(doc);
  if (ci == null || co == null) return TripDocumentStatus.unknown;
  final today = _startOfDay(now);
  final start = _startOfDay(ci);
  final end = _startOfDay(co);
  if (!today.isBefore(start) && !today.isAfter(end)) {
    return TripDocumentStatus.current;
  }
  if (today.isBefore(start)) return TripDocumentStatus.upcoming;
  return TripDocumentStatus.past;
}

TripDocumentStatus transportStatus(TripDocument doc, DateTime now) {
  final dep = transportSortKey(doc);
  final end = transportEndKey(doc);
  if (dep == null && end == null) return TripDocumentStatus.unknown;
  if (dep != null && !dep.isBefore(now)) return TripDocumentStatus.upcoming;
  if (end != null && end.isBefore(now)) return TripDocumentStatus.past;
  return TripDocumentStatus.current;
}

TripDocumentStatus ticketStatus(TripDocument doc, DateTime now) {
  final t = ticketSortKey(doc);
  if (t == null) return TripDocumentStatus.unknown;
  if (!t.isBefore(now)) return TripDocumentStatus.upcoming;
  return TripDocumentStatus.past;
}
