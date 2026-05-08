/// Service de mutation d'itinéraire — Lot 2.1.
///
/// Calcule et applique les transformations associées à une
/// `SubTripSuggestion` (cf. `sub_trip_suggestions.dart`). Service pur
/// sans I/O ni dépendance Flutter, testable hors-app.
///
/// 3 opérations supportées (mappées depuis les 5 `InsertionMode`) :
///
/// **APPEND** (`dayTrip`, `nearbyStay`) : anchor inchangé. Segments
/// suggérés insérés JUSTE APRÈS l'anchor. La somme totale des jours
/// du voyage augmente. Refusé si pas assez de jours libres
/// (`tripDuration - currentTotal < suggestedTotal`).
///
/// **SPLIT** (`splitSegment`, `splitGatewaySequence`) : anchor réduit,
/// segments suggérés insérés À LA PLACE de l'anchor (devant le reliquat
/// d'anchor). La somme totale est préservée.
/// Ex: Hanoï 4 + Ninh Bình 3 (minKeep 1) → [Ninh Bình 3, Hanoï 1].
/// Refusé si `anchor.days - suggestedTotal < minAnchorDaysToKeep`.
///
/// **REPLACE** (`replaceAnchorGateway`) : anchor disparaît. Le segment
/// suggéré prend la durée de l'anchor (`days = anchor.days`, override
/// la valeur déclarée). Préserve la somme totale du voyage. Cas
/// canonique : Da Nang 5 → Hội An 5 (gateway → vraie étape).
///
/// Lot 2.2 ajoutera un conflict detector date-précis (overlap
/// réservations) en complément du detector city-level Lot 1.
library;

import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Description immutable d'une mutation à appliquer sur une liste de
/// `TripSegment`. Calculée par `computeMutation`, appliquée par
/// `applyMutation`.
class ItineraryMutation {
  /// Index de l'anchor dans la liste des segments d'origine.
  final int anchorIndex;

  /// Mode logique (pour log/observabilité). N'influe pas sur
  /// `applyMutation` qui se base uniquement sur `newAnchorDays` et
  /// `insertedSegments`.
  final InsertionMode mode;

  /// Segments à insérer, dans l'ordre. Pour APPEND : insérés APRÈS
  /// l'anchor. Pour SPLIT/REPLACE : insérés À LA PLACE de l'anchor
  /// (devant le reliquat éventuel de l'anchor).
  final List<TripSegment> insertedSegments;

  /// Nouvelle durée pour l'anchor :
  /// - `null` : anchor inchangé (APPEND).
  /// - `0` : anchor supprimé (REPLACE).
  /// - `> 0` : anchor réduit (SPLIT, conserve uniquement le reliquat).
  final int? newAnchorDays;

  const ItineraryMutation({
    required this.anchorIndex,
    required this.mode,
    required this.insertedSegments,
    required this.newAnchorDays,
  });
}

/// Raisons d'échec exposées au caller (pour message UX humain).
enum MutationFailureReason {
  /// Aucun segment du voyage ne matche `suggestion.anchorCity`.
  /// Cas typique : suggestion catalogue pour Hanoï mais segments =
  /// [Paris, Lyon]. Le routing devrait masquer ces suggestions, mais
  /// on garde le garde-fou.
  anchorNotFound,

  /// SPLIT impossible : `anchor.days - suggestedTotal < minAnchorDaysToKeep`.
  /// Ex: Hanoï 3 nuits, Ninh Bình suggéré 3 nuits, minKeep 1 → reste 0.
  notEnoughDaysToSplit,

  /// APPEND impossible : pas assez de jours libres dans le voyage.
  /// `tripDuration - currentTotal < suggestedTotal`. V1 ne vole pas
  /// de jours à un autre segment automatiquement.
  notEnoughFreeDaysToAppend,
}

/// Résultat scellé de `computeMutation`. Soit un `MutationOk(mutation)`
/// applicable via `applyMutation`, soit un `MutationFailed(reason)`.
sealed class MutationResult {
  const MutationResult();
}

class MutationOk extends MutationResult {
  final ItineraryMutation mutation;
  const MutationOk(this.mutation);
}

class MutationFailed extends MutationResult {
  final MutationFailureReason reason;

  /// Détails optionnels pour log/debug. Pas affiché à l'utilisateur tel
  /// quel — le caller mappe `reason` vers un message UX humain.
  final String? detail;

  const MutationFailed(this.reason, {this.detail});
}

/// Calcule la mutation à appliquer au voyage pour cette suggestion, ou
/// renvoie `MutationFailed` avec la raison.
///
/// `currentSegments` : segments actuels du voyage (typiquement
/// `trip.itinerarySegments` ou la copie en cours d'édition).
/// `tripDurationDays` : durée totale du voyage (`endDate - startDate +
/// 1`). Sert au calcul des jours libres pour APPEND.
///
/// Cas multi-occurrence : si `anchorCity` apparaît plusieurs fois dans
/// les segments (ex: Bangkok au début + Bangkok au retour), le PREMIER
/// match est retenu en V1. Le caller peut signaler via UI s'il faut
/// affiner (V2).
MutationResult computeMutation({
  required SubTripSuggestion suggestion,
  required List<TripSegment> currentSegments,
  required int tripDurationDays,
}) {
  final anchorIdx = _findAnchorIndex(currentSegments, suggestion.anchorCity);
  if (anchorIdx < 0) {
    return MutationFailed(
      MutationFailureReason.anchorNotFound,
      detail: 'Aucun segment ne matche "${suggestion.anchorCity}".',
    );
  }
  final anchor = currentSegments[anchorIdx];

  switch (suggestion.insertionMode) {
    case InsertionMode.dayTrip:
    case InsertionMode.nearbyStay:
      // ─── APPEND ─────────────────────────────────────────────────
      final currentTotal =
          currentSegments.fold<int>(0, (sum, s) => sum + s.days);
      final freeDays = tripDurationDays - currentTotal;
      final addedDays = suggestion.totalSuggestedDays;
      if (freeDays < addedDays) {
        return MutationFailed(
          MutationFailureReason.notEnoughFreeDaysToAppend,
          detail: 'Voyage = $tripDurationDays jours, déjà placés = '
              '$currentTotal, suggéré = $addedDays, libres = $freeDays.',
        );
      }
      return MutationOk(ItineraryMutation(
        anchorIndex: anchorIdx,
        mode: suggestion.insertionMode,
        insertedSegments: _materialize(suggestion),
        newAnchorDays: null, // anchor inchangé
      ));

    case InsertionMode.replaceAnchorGateway:
      // ─── REPLACE ────────────────────────────────────────────────
      // Validation Lalith 2026-05-08 : suggested.days = anchor.days
      // (override la valeur déclarée). Préserve la durée totale du
      // voyage et évite de perdre des jours silencieusement.
      // En multi-step (cas non observé en V1 catalogue), on alloue la
      // totalité des jours d'anchor au premier segment et garde les
      // suivants à leur durée déclarée — l'utilisateur ajustera.
      final inserted = <TripSegment>[];
      if (suggestion.segments.isNotEmpty) {
        final main = suggestion.segments.first;
        inserted.add(TripSegment(
          city: main.city,
          days: anchor.days,
          country: main.country ?? anchor.country,
        ));
        for (final s in suggestion.segments.skip(1)) {
          inserted.add(TripSegment(
            city: s.city,
            days: s.days,
            country: s.country,
          ));
        }
      }
      return MutationOk(ItineraryMutation(
        anchorIndex: anchorIdx,
        mode: suggestion.insertionMode,
        insertedSegments: inserted,
        newAnchorDays: 0, // anchor supprimé
      ));

    case InsertionMode.splitSegment:
    case InsertionMode.splitGatewaySequence:
      // ─── SPLIT ──────────────────────────────────────────────────
      final addedDays = suggestion.totalSuggestedDays;
      final reduced = anchor.days - addedDays;
      if (reduced < suggestion.minAnchorDaysToKeep) {
        return MutationFailed(
          MutationFailureReason.notEnoughDaysToSplit,
          detail: 'Anchor "${anchor.city}" a ${anchor.days} jours, '
              'suggéré = $addedDays, minKeep = '
              '${suggestion.minAnchorDaysToKeep}, restant = $reduced.',
        );
      }
      return MutationOk(ItineraryMutation(
        anchorIndex: anchorIdx,
        mode: suggestion.insertionMode,
        insertedSegments: _materialize(suggestion),
        newAnchorDays: reduced,
      ));
  }
}

/// Applique une mutation calculée à la liste de segments. Retourne une
/// NOUVELLE liste (immutable in spirit). Idempotent par construction :
/// même mutation appliquée 2× donne le même résultat (tant qu'aucun
/// segment n'a changé entre-temps — sinon le caller doit recompute).
List<TripSegment> applyMutation(
  List<TripSegment> currentSegments,
  ItineraryMutation mutation,
) {
  final result = <TripSegment>[];
  for (var i = 0; i < currentSegments.length; i++) {
    if (i != mutation.anchorIndex) {
      result.add(currentSegments[i]);
      continue;
    }
    // i == anchorIndex
    if (mutation.newAnchorDays == null) {
      // APPEND : anchor inchangé, segments insérés APRÈS.
      result.add(currentSegments[i]);
      result.addAll(mutation.insertedSegments);
    } else if (mutation.newAnchorDays == 0) {
      // REPLACE : anchor supprimé, segments insérés à sa place.
      result.addAll(mutation.insertedSegments);
    } else {
      // SPLIT : segments insérés À LA PLACE de l'anchor, suivi du
      // reliquat de l'anchor avec days réduit.
      result.addAll(mutation.insertedSegments);
      result.add(currentSegments[i].copyWith(days: mutation.newAnchorDays));
    }
  }
  return result;
}

// ─── Helpers internes ─────────────────────────────────────────────────

List<TripSegment> _materialize(SubTripSuggestion suggestion) {
  return suggestion.segments
      .map((s) => TripSegment(
            city: s.city,
            days: s.days,
            country: s.country,
          ))
      .toList();
}

int _findAnchorIndex(List<TripSegment> segments, String anchorCity) {
  final norm = _normalizeCity(anchorCity);
  for (var i = 0; i < segments.length; i++) {
    if (_normalizeCity(segments[i].city) == norm) return i;
  }
  return -1;
}

/// Normalisation case+diacritiques. Doit rester alignée sur les
/// helpers `_normalizeCity` de `sub_trip_suggestions.dart` et
/// `sub_trip_conflict_detector.dart` (pattern projet).
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
