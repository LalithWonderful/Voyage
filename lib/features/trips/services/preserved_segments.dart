/// V5.4 (Lalith 2026-05-10) — service de préservation des étapes
/// non doc-derived lors d'une reconstruction de l'itinéraire depuis
/// les documents (`applyTimelineDiff`).
///
/// Règle produit : on capture les étapes manuelles et window-linked
/// AVEC LEURS DATES D'ORIGINE avant la reconstruction. Après le rebuild
/// du squelette doc-derived, on tente de les replacer aux mêmes dates
/// si elles sont encore libres dans le nouveau squelette. Les étapes
/// qui ne peuvent pas être replacées (dates en conflit, fenêtre
/// disparue, etc.) sont retournées comme « leftovers » pour que le
/// bandeau « À replacer » les expose à l'utilisateur.
library;

import 'package:voyage/features/trips/models/trip_model.dart';

/// Origine d'une étape préservée. Sert à classer dans les buckets UX
/// (auto-replaçable, à confirmer, etc.) et pour le télémétrie.
enum PreservedSegmentSource {
  /// Étape ajoutée manuellement par le voyageur (Tokyo, Kyoto…).
  manual,

  /// Étape liée à une fenêtre d'ancrage existante (Hội An liée à
  /// Da Nang, Ninh Bình liée à Hanoï…) — `sourceAnchorCity` non null.
  windowLinked,
}

/// Snapshot riche d'une étape mise de côté avant resync. Stocke ce
/// qu'il faut pour tenter un replacement aux dates d'origine.
class PreservedSegmentInfo {
  final String city;
  final String? country;
  final int days;

  /// Date inclusive de début (= jour d'arrivée à la ville).
  final DateTime startDate;

  /// Date exclusive de fin (= jour de départ de la ville).
  final DateTime endDateExclusive;

  /// Position originale du segment dans `trip.itinerarySegments`. Sert
  /// au tri stable + heuristique de désambiguïsation.
  final int originalIndex;

  final PreservedSegmentSource source;

  /// Ville d'ancrage source si disponible (ex : Da Nang pour Hội An).
  /// Null pour les étapes purement manuelles.
  final String? sourceAnchorCity;

  const PreservedSegmentInfo({
    required this.city,
    required this.days,
    required this.startDate,
    required this.endDateExclusive,
    required this.originalIndex,
    required this.source,
    this.country,
    this.sourceAnchorCity,
  });

  TripSegment toSegment() => TripSegment(
        city: city,
        days: days,
        country: country,
        sourceAnchorCity: sourceAnchorCity,
      );
}

/// Tente de replacer les `preserved` aux dates d'origine dans le
/// `skeleton` doc-derived. Retourne la liste finale des segments à
/// persister + la liste des étapes qu'on n'a pas pu replacer.
///
/// Règles d'auto-placement :
///  1. les dates [startDate, endDateExclusive) doivent être incluses
///     dans la plage du voyage (skeleton total)
///  2. tous les jours [start, end) doivent appartenir au MÊME segment
///     du squelette (pas de chevauchement de doc / autre preserved)
///  3. si OK : on remplace les jours par l'étape préservée. Le
///     squelette reste intact en dehors.
///
/// Hard rules respectées :
///  - aucun segment doc-derived n'est déplacé (on travaille en
///    superposition jour par jour, pas de réordonnancement)
///  - pas de dépassement de durée totale (jours conservés stricts)
///  - pas de segment 0-jour (l'émission groupe les jours contigus)
({
  List<TripSegment> placed,
  List<PreservedSegmentInfo> leftovers,
}) autoPlacePreservedSegments({
  required List<TripSegment> skeleton,
  required DateTime tripStartDate,
  required List<PreservedSegmentInfo> preserved,
}) {
  final totalDays = skeleton.fold<int>(0, (a, s) => a + s.days);
  if (totalDays == 0 || preserved.isEmpty) {
    return (placed: List<TripSegment>.of(skeleton), leftovers: preserved);
  }

  // Carte jour → owner. Initialement = segment du squelette qui
  // couvre ce jour. Sera potentiellement écrasé par les preserved.
  final dayOwner = <int, Object>{};
  var offset = 0;
  for (final s in skeleton) {
    for (var k = 0; k < s.days; k++) {
      dayOwner[offset + k] = s;
    }
    offset += s.days;
  }

  final leftovers = <PreservedSegmentInfo>[];
  final tripStart = _dateOnly(tripStartDate);
  // V5.4 — set des owners créés pour des étapes préservées déjà
  // placées. Sert à interdire un 2ᵉ placement qui écraserait le 1er
  // (cas où 2 preserved ciblent les mêmes jours par dates d'origine).
  final placedOwners = <Object>{};

  // Tri par date pour déterminisme + permettre aux placements
  // antérieurs de potentiellement bloquer les plus tardifs (anti-
  // chevauchement entre deux preserved sur les mêmes jours).
  final sorted = List<PreservedSegmentInfo>.of(preserved)
    ..sort((a, b) => a.startDate.compareTo(b.startDate));

  for (final p in sorted) {
    if (p.days <= 0) {
      leftovers.add(p);
      continue;
    }
    final startIdx = _dateOnly(p.startDate).difference(tripStart).inDays;
    final endIdx = startIdx + p.days;
    if (startIdx < 0 || endIdx > totalDays) {
      leftovers.add(p);
      continue;
    }
    // Le 1er owner doit être un segment du skeleton (= NON déjà placé
    // par un autre preserved sinon on écraserait le 1er).
    final firstOwner = dayOwner[startIdx];
    if (firstOwner is! TripSegment || placedOwners.contains(firstOwner)) {
      leftovers.add(p);
      continue;
    }
    // Tous les jours [startIdx, endIdx) doivent partager LE MÊME
    // owner (= étape skeleton ininterrompue par un autre placement).
    var sameOwner = true;
    for (var k = startIdx + 1; k < endIdx; k++) {
      if (!identical(dayOwner[k], firstOwner)) {
        sameOwner = false;
        break;
      }
    }
    if (!sameOwner) {
      leftovers.add(p);
      continue;
    }
    // Tous les jours sont libres dans le même segment skeleton →
    // on les écrase avec une instance représentant cette étape
    // préservée. L'identité (référence) sert à grouper à l'émission.
    final pSeg = p.toSegment();
    placedOwners.add(pSeg);
    for (var k = startIdx; k < endIdx; k++) {
      dayOwner[k] = pSeg;
    }
  }

  // Émission : on parcourt les jours et on groupe les owners contigus
  // identiques. Pour les fragments d'un même segment skeleton (= même
  // référence), on les rend tous comme des splits du même skeleton.
  final result = <TripSegment>[];
  Object? currentOwner;
  var currentDays = 0;
  for (var k = 0; k < totalDays; k++) {
    final o = dayOwner[k];
    if (o == null) continue;
    if (currentOwner == null || !identical(o, currentOwner)) {
      if (currentOwner != null) {
        result.add(_ownerToSegment(currentOwner, currentDays));
      }
      currentOwner = o;
      currentDays = 1;
    } else {
      currentDays++;
    }
  }
  if (currentOwner != null) {
    result.add(_ownerToSegment(currentOwner, currentDays));
  }

  return (placed: result, leftovers: leftovers);
}

TripSegment _ownerToSegment(Object owner, int days) {
  if (owner is TripSegment) return owner.copyWith(days: days);
  throw StateError('autoPlacePreservedSegments: unexpected owner type');
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
