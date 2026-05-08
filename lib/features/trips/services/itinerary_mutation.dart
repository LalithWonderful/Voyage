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
import 'package:voyage/features/planning/services/pinned_dates.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Description immutable d'une mutation à appliquer sur une liste de
/// `TripSegment`. Calculée par `computeMutation`, appliquée par
/// `applyMutation` (single) ou `applyMutationBatch` (multi).
class ItineraryMutation {
  /// Index de l'anchor dans la liste des segments AU MOMENT DU CALCUL.
  /// Reste utile pour `applyMutation` single. En batch, on re-localise
  /// l'anchor par `anchorCity` (les indices shift entre mutations).
  final int anchorIndex;

  /// Nom de la ville d'ancrage. Sert au batch apply (re-localisation
  /// par nom après que d'autres mutations aient shifté les indices)
  /// et à `validateMutationBatch` (groupage par anchor).
  final String anchorCity;

  /// Mode logique (pour log/observabilité + validation batch — ex:
  /// 2 SPLIT sur même anchor = conflit).
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

  /// V2 — Date à laquelle l'insertion commence dans le bloc anchor (1ère
  /// nuit à la ville suggérée). Null pour APPEND/REPLACE et pour les SPLIT
  /// qui n'exigent pas de date (cf. `requiresInsertionDate`).
  ///
  /// Conservé pour log/observabilité — le calcul effectif d'`applyMutation`
  /// utilise `insertionPreDays` (offset en jours).
  final DateTime? insertionStartDate;

  /// V2 — Décalage en jours entre `anchor.startDate` et
  /// `insertionStartDate`. Calculé à `computeMutation` à partir de
  /// `pinnedAnalysis`. Sert à `applyMutation` pour découper l'anchor en
  /// `[pre anchor, inserted, post anchor]` en segment-space (stable
  /// sous batch même si des APPEND amont décalent l'anchor en
  /// date-space).
  final int? insertionPreDays;

  /// V2 — Vrai si la suggestion à l'origine de cette mutation EXIGE une
  /// `insertionStartDate` (rule produit non négociable : pas
  /// d'heuristique début/milieu/fin de bloc). Calculé à `computeMutation`
  /// via `suggestionRequiresInsertionDate`. Le batch validator rejette
  /// toute mutation requiresInsertionDate sans date.
  final bool requiresInsertionDate;

  const ItineraryMutation({
    required this.anchorIndex,
    required this.anchorCity,
    required this.mode,
    required this.insertedSegments,
    required this.newAnchorDays,
    this.insertionStartDate,
    this.insertionPreDays,
    this.requiresInsertionDate = false,
  });

  /// Vrai si la mutation modifie structurellement l'anchor (SPLIT ou
  /// REPLACE — les jours de l'anchor changent ou l'anchor disparaît).
  /// Sert à la validation batch : 2 mutations structurelles sur le même
  /// anchor sont incompatibles.
  bool get isStructural => newAnchorDays != null;

  /// Vrai si la mutation supprime l'anchor (REPLACE). Bloque toute
  /// autre mutation sur le même anchor (anchor disparaît).
  bool get removesAnchor => newAnchorDays == 0;
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

  /// V2 — `insertionStartDate` est en dehors des bornes du segment ancrage
  /// OU viole une contrainte de transport pinné (arrivée/départ daté).
  /// Couvre les contraintes 1-4 de `validateInsertionDate`.
  insertionDateOutOfBounds,

  /// V2 — `insertionStartDate` chevauche une réservation d'hôtel à
  /// l'ancrage. Contrainte 5 de `validateInsertionDate`.
  insertionDateConflictsHotel,
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
  DateTime? insertionStartDate,
  PinnedDatesAnalysis? pinnedAnalysis,
}) {
  final anchorIdx = _findAnchorIndex(currentSegments, suggestion.anchorCity);
  if (anchorIdx < 0) {
    return MutationFailed(
      MutationFailureReason.anchorNotFound,
      detail: 'Aucun segment ne matche "${suggestion.anchorCity}".',
    );
  }
  final anchor = currentSegments[anchorIdx];
  final requiresDate = suggestionRequiresInsertionDate(suggestion);

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
        anchorCity: anchor.city,
        mode: suggestion.insertionMode,
        insertedSegments: _materialize(suggestion),
        newAnchorDays: null, // anchor inchangé
        requiresInsertionDate: requiresDate,
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
        anchorCity: anchor.city,
        mode: suggestion.insertionMode,
        insertedSegments: inserted,
        newAnchorDays: 0, // anchor supprimé
        requiresInsertionDate: requiresDate,
      ));

    case InsertionMode.splitSegment:
    case InsertionMode.splitGatewaySequence:
      // ─── SPLIT ──────────────────────────────────────────────────
      // Safety floor : SPLIT ne doit JAMAIS produire un anchor à 0 jour
      // (pas de TripSegment vide). Si le catalogue déclare
      // minAnchorDaysToKeep = 0 (cas non observé en V1 mais possible),
      // on force quand même un minimum de 1 jour. Une suggestion qui
      // veut consommer 100 % des jours de l'anchor doit utiliser
      // `replaceAnchorGateway`, pas SPLIT avec minKeep = 0.
      final addedDays = suggestion.totalSuggestedDays;
      final reduced = anchor.days - addedDays;
      final effectiveMinKeep =
          suggestion.minAnchorDaysToKeep < 1 ? 1 : suggestion.minAnchorDaysToKeep;
      if (reduced < effectiveMinKeep) {
        return MutationFailed(
          MutationFailureReason.notEnoughDaysToSplit,
          detail: 'Anchor "${anchor.city}" a ${anchor.days} jours, '
              'suggéré = $addedDays, min keep effectif = $effectiveMinKeep, '
              'restant = $reduced.',
        );
      }

      // V2 — Validation date d'insertion si fournie + analyse pinned dispo.
      // L'absence de date n'est PAS rejetée ici (le batch validator s'en
      // charge selon `requiresInsertionDate`) — applyMutation fallback à
      // l'heuristique MVP si pas de date.
      int? insertionPreDays;
      if (insertionStartDate != null && pinnedAnalysis != null) {
        final reason = validateInsertionDate(
          anchorCity: anchor.city,
          insertionStartDate: insertionStartDate,
          insertionDays: addedDays,
          analysis: pinnedAnalysis,
        );
        if (reason != null) {
          final isHotel = reason.contains('hôtel');
          return MutationFailed(
            isHotel
                ? MutationFailureReason.insertionDateConflictsHotel
                : MutationFailureReason.insertionDateOutOfBounds,
            detail: reason,
          );
        }
        final pin = pinnedAnalysis.forCity(anchor.city);
        if (pin != null) {
          insertionPreDays = DateTime(
            insertionStartDate.year,
            insertionStartDate.month,
            insertionStartDate.day,
          ).difference(DateTime(
            pin.startDate.year,
            pin.startDate.month,
            pin.startDate.day,
          )).inDays;
        }
      }

      return MutationOk(ItineraryMutation(
        anchorIndex: anchorIdx,
        anchorCity: anchor.city,
        mode: suggestion.insertionMode,
        insertedSegments: _materialize(suggestion),
        newAnchorDays: reduced,
        insertionStartDate: insertionStartDate,
        insertionPreDays: insertionPreDays,
        requiresInsertionDate: requiresDate,
      ));
  }
}

/// V2 — Vrai si la suggestion exige une `insertionStartDate` explicite
/// avant d'être appliquée. Sert à la fois au UI (afficher un date picker
/// à la sélection) et au batch validator (rejeter une mutation
/// structurelle sans date).
///
/// Critère narrow (V2.2) :
/// - `splitSegment` × `majorDestination` (Chiang Mai, Krabi, Koh Samui,
///   Phuket depuis Bangkok) — grandes alternatives où l'insertion à la
///   date heuristique de début de bloc shifterait des dates pinnées.
/// - `splitGatewaySequence` multi-step (≥2 segments insérés —
///   Rayong+Koh Samet) — séquences longues qui consomment
///   significativement les nuits du gateway.
///
/// Les autres SPLIT (gateway × splitSegment, splitGatewaySequence
/// single-step) gardent le comportement MVP "insertion en début de
/// bloc" jusqu'à ce que le picker soit étendu.
bool suggestionRequiresInsertionDate(SubTripSuggestion s) {
  if (s.insertionMode == InsertionMode.splitSegment &&
      s.category == SuggestionCategory.majorDestination) {
    return true;
  }
  if (s.insertionMode == InsertionMode.splitGatewaySequence &&
      s.segments.length >= 2) {
    return true;
  }
  return false;
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
      // SPLIT : 2 stratégies selon `insertionPreDays`.
      // - Si fourni (V2 picker) : 3-way split [anchor pre, inserted, anchor post]
      //   en omettant les bouts à 0 jour. L'anchor garde son city/country.
      // - Sinon (fallback MVP) : insertion en début de bloc, anchor reliquat
      //   après. Comportement Lot 2.1 inchangé.
      final pre = mutation.insertionPreDays;
      if (pre != null && mutation.insertedSegments.isNotEmpty) {
        final insertedTotal = mutation.insertedSegments
            .fold<int>(0, (sum, e) => sum + e.days);
        final post = currentSegments[i].days - pre - insertedTotal;
        if (pre > 0) {
          result.add(currentSegments[i].copyWith(days: pre));
        }
        result.addAll(mutation.insertedSegments);
        if (post > 0) {
          result.add(currentSegments[i].copyWith(days: post));
        }
      } else {
        result.addAll(mutation.insertedSegments);
        result.add(currentSegments[i].copyWith(days: mutation.newAnchorDays));
      }
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

// ─── Batch (Lot 2.3 — multi-select) ──────────────────────────────────

/// Raisons d'échec spécifiques au batch (en plus de
/// `MutationFailureReason` qui couvre les erreurs single).
enum BatchFailureReason {
  /// Au moins 2 mutations structurelles (SPLIT/REPLACE) ciblent le
  /// même anchor city. Une seule modification par anchor est autorisée.
  conflictingStructuralOnSameAnchor,

  /// REPLACE supprime l'anchor, mais une autre mutation cible le même
  /// anchor (devenu inexistant après REPLACE).
  appendOnRemovedAnchor,

  /// Le total des jours ajoutés via APPEND dépasse les jours libres
  /// du voyage (somme des APPEND > tripDuration - currentTotal).
  notEnoughFreeDaysForAllAppends,

  /// V2 — Une mutation structurelle dont la suggestion exige une
  /// `insertionStartDate` (cf. `suggestionRequiresInsertionDate`) a été
  /// fournie sans date. Le caller doit ouvrir le date picker avant
  /// d'appeler le validator.
  missingInsertionDate,
}

/// Résultat scellé de `validateMutationBatch`.
sealed class BatchValidationResult {
  const BatchValidationResult();
}

class BatchOk extends BatchValidationResult {
  const BatchOk();
}

class BatchFailed extends BatchValidationResult {
  final BatchFailureReason reason;
  /// Ville d'ancrage liée au conflit (si pertinent — pour message UX).
  final String? anchorCity;
  /// Détails optionnels (logs/debug).
  final String? detail;
  const BatchFailed(this.reason, {this.anchorCity, this.detail});
}

/// Valide qu'un batch de mutations peut être appliqué ensemble. Règles :
/// 1. Au plus 1 mutation STRUCTURELLE (SPLIT ou REPLACE) par anchor city.
/// 2. Si REPLACE sur anchor X → aucune autre mutation ne peut cibler X
///    (anchor disparaît).
/// 3. La somme des jours ajoutés via APPEND doit tenir dans les jours
///    libres du voyage.
///
/// Les conflits city-level / date-précis sont gérés en amont par
/// `_resolveSuggestion` côté UI — ce validator se concentre sur les
/// règles INTER-mutations (impossibles à détecter individuellement).
BatchValidationResult validateMutationBatch({
  required List<ItineraryMutation> mutations,
  required List<TripSegment> currentSegments,
  required int tripDurationDays,
}) {
  if (mutations.isEmpty) return const BatchOk();

  // V2 — Pre-check : toute mutation requiresInsertionDate sans date est
  // rejetée. Le UI doit ouvrir le picker avant le batch.
  for (final m in mutations) {
    if (m.requiresInsertionDate && m.insertionStartDate == null) {
      return BatchFailed(
        BatchFailureReason.missingInsertionDate,
        anchorCity: m.anchorCity,
        detail: 'Mutation "${m.anchorCity}" exige une insertionStartDate.',
      );
    }
  }

  // Groupage par anchor (normalisé pour case/accent insensible).
  final byAnchor = <String, List<ItineraryMutation>>{};
  for (final m in mutations) {
    final k = _normalizeCity(m.anchorCity);
    byAnchor.putIfAbsent(k, () => []).add(m);
  }

  for (final entry in byAnchor.entries) {
    final group = entry.value;
    final structural = group.where((m) => m.isStructural).toList();

    // Règle 1 : au plus 1 structurelle par anchor.
    if (structural.length > 1) {
      return BatchFailed(
        BatchFailureReason.conflictingStructuralOnSameAnchor,
        anchorCity: structural.first.anchorCity,
      );
    }

    // Règle 2 : REPLACE → aucune autre mutation sur l'anchor.
    final removes = group.where((m) => m.removesAnchor).toList();
    if (removes.isNotEmpty && group.length > 1) {
      return BatchFailed(
        BatchFailureReason.appendOnRemovedAnchor,
        anchorCity: removes.first.anchorCity,
      );
    }
  }

  // Règle 3 : somme des APPEND ≤ jours libres.
  final currentTotal =
      currentSegments.fold<int>(0, (sum, s) => sum + s.days);
  final freeDays = tripDurationDays - currentTotal;
  // APPEND = mutations non structurelles (newAnchorDays == null).
  // Pour SPLIT (structural), la somme des days reste préservée par
  // construction → ne consomme pas de jour libre.
  // Pour REPLACE (structural removal) idem : suggested prend anchor.days
  // → pas de consommation de jour libre.
  final appendTotal = mutations
      .where((m) => !m.isStructural)
      .fold<int>(
          0, (sum, m) => sum + m.insertedSegments.fold<int>(0, (s, e) => s + e.days));
  if (appendTotal > freeDays) {
    return BatchFailed(
      BatchFailureReason.notEnoughFreeDaysForAllAppends,
      detail:
          'APPEND total = $appendTotal jours, libres = $freeDays.',
    );
  }

  return const BatchOk();
}

/// Applique séquentiellement un batch de mutations. À chaque étape, on
/// re-localise l'anchor par CITY (pas par index, qui shifterait après
/// les mutations précédentes).
///
/// Présuppose que `validateMutationBatch` a déjà validé le batch — sinon
/// une mutation pourrait référencer un anchor disparu (REPLACE+autre)
/// et serait skippée silencieusement.
List<TripSegment> applyMutationBatch(
  List<TripSegment> initial,
  List<ItineraryMutation> mutations,
) {
  var current = List<TripSegment>.from(initial);
  for (final m in mutations) {
    final idx = _findAnchorIndex(current, m.anchorCity);
    if (idx < 0) {
      // Anchor disparu (e.g., REPLACE l'a supprimé en amont) — skip
      // proprement plutôt que crasher. La validation upstream aurait
      // dû éviter ce cas.
      continue;
    }
    final patched = ItineraryMutation(
      anchorIndex: idx,
      anchorCity: m.anchorCity,
      mode: m.mode,
      insertedSegments: m.insertedSegments,
      newAnchorDays: m.newAnchorDays,
      insertionStartDate: m.insertionStartDate,
      insertionPreDays: m.insertionPreDays,
      requiresInsertionDate: m.requiresInsertionDate,
    );
    current = applyMutation(current, patched);
  }
  return current;
}
