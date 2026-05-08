/// Sheet "Améliorer ton itinéraire" — Lot 2.2.
///
/// Affichée quand un voyage a déjà ≥2 segments d'itinéraire (typiquement
/// auto-détectés depuis les vols) ET qu'au moins une des villes d'ancrage
/// a des suggestions dans `sub_trip_suggestions.dart`.
///
/// Lot 2.2 : retourne une `ItineraryMutation?` au caller. La sheet :
/// - Affiche les sections par ville d'ancrage avec les cards catalogue
/// - Calcule pour chaque card un `MutationResult` via `computeMutation`
///   (refus si anchor introuvable / pas assez de jours)
/// - Combine avec le preflight conflit Lot 1 (city-level) + Lot 2.2
///   (date-précis : overlap résa hôtel)
/// - Card désactivée si MutationFailed ou preflight=block, avec notice
///   humaine expliquant pourquoi
/// - CTA cliqué → `Navigator.pop(mutation)` (le caller applique via
///   `applyMutation` + persiste)
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/planning/services/sub_trip_conflict_detector.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/itinerary_mutation.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Ouvre la sheet "Améliorer ton itinéraire". Retourne la mutation
/// choisie par l'utilisateur, ou `null` s'il a annulé / fermé sans tap.
/// Le caller est responsable d'appliquer via `applyMutation` et de
/// persister.
Future<ItineraryMutation?> openImproveItinerarySheet(
  BuildContext context, {
  required String tripId,
  required List<TripSegment> currentSegments,
  required DateTime tripStartDate,
  required int tripDurationDays,
}) async {
  return showModalBottomSheet<ItineraryMutation>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ImproveItinerarySheet(
      tripId: tripId,
      currentSegments: currentSegments,
      tripStartDate: tripStartDate,
      tripDurationDays: tripDurationDays,
    ),
  );
}

/// Vrai si le voyage est éligible au flow "Améliorer ton itinéraire" :
/// au moins 2 villes d'ancrage uniques ET au moins une d'entre elles
/// a des suggestions dans le catalogue. Sinon → fallback sur le flow
/// régions classique (`openRegionalLoopSheet`).
bool isImproveItineraryEligible(List<String> anchorCities) {
  final unique = <String>{};
  for (final c in anchorCities) {
    final t = c.trim();
    if (t.isNotEmpty) unique.add(t.toLowerCase());
  }
  if (unique.length < 2) return false;
  return hasAnySuggestionsFor(anchorCities);
}

class _ImproveItinerarySheet extends ConsumerWidget {
  final String tripId;
  final List<TripSegment> currentSegments;
  final DateTime tripStartDate;
  final int tripDurationDays;

  const _ImproveItinerarySheet({
    required this.tripId,
    required this.currentSegments,
    required this.tripStartDate,
    required this.tripDurationDays,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docsAsync = ref.watch(tripDocumentsProvider(tripId));

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: docsAsync.when(
                data: (docs) => _buildBody(
                  context,
                  scrollController: scrollController,
                  docs: docs,
                ),
                loading: () => const Center(
                  child: CircularProgressIndicator(),
                ),
                error: (_, _) => _buildBody(
                  context,
                  scrollController: scrollController,
                  docs: const [],
                ),
              ),
            ),
            _buildFooter(context),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Améliorer ton itinéraire',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Lunao a détecté des étapes depuis tes documents de '
                  'voyage. Certaines villes peuvent être des points '
                  'd\'arrivée ou de transit. Voici des idées pour '
                  'affiner ton parcours.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.textPrimary.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 22),
            onPressed: () => Navigator.of(context).pop(),
            color: AppColors.textPrimary.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required ScrollController scrollController,
    required List<TripDocument> docs,
  }) {
    // Dédup par ville (case-insensitive) en préservant l'ordre, depuis
    // les segments du voyage (Lot 2.2 reçoit les segments complets pour
    // pouvoir computer mutations + dates précises).
    final seen = <String>{};
    final uniqueCities = <String>[];
    for (final s in currentSegments) {
      final t = s.city.trim();
      if (t.isEmpty) continue;
      final key = t.toLowerCase();
      if (seen.add(key)) uniqueCities.add(t);
    }

    // Pour chaque ville, récupère les suggestions catalogue.
    // `isArrival` (= titre "Après ton arrivée à X") : data-driven via les
    // modes des suggestions plutôt que l'index dans le voyage. Une ville
    // est traitée comme gateway si AU MOINS une de ses suggestions est
    // mode `replaceAnchorGateway` ou `splitGatewaySequence` (signe que
    // la ville sert de point d'arrivée vers une vraie étape de séjour).
    // Plus stable que l'heuristique d'index : Hanoï/Da Nang restent
    // gateway même si le voyage commence par Phú Quốc.
    final sectionsWithSuggestions =
        <({String city, List<SubTripSuggestion> suggestions, bool isArrival})>[];
    for (final c in uniqueCities) {
      final s = findSuggestionsForAnchor(c);
      if (s.isEmpty) continue;
      final isArrival = s.any(
        (e) =>
            e.insertionMode == InsertionMode.replaceAnchorGateway ||
            e.insertionMode == InsertionMode.splitGatewaySequence,
      );
      sectionsWithSuggestions.add((
        city: c,
        suggestions: s,
        isArrival: isArrival,
      ));
    }

    if (sectionsWithSuggestions.isEmpty) {
      return _buildEmptyState(context);
    }

    return ListView.builder(
      controller: scrollController,
      // Padding bottom large pour que la dernière card ne soit pas
      // masquée par le footer fixe "Fermer" (≈ 60px) + SafeArea iOS
      // (jusqu'à 34px home indicator). 140 garantit ~50px de marge
      // au repos sur tous devices testés.
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
      itemCount: sectionsWithSuggestions.length,
      itemBuilder: (context, index) {
        final entry = sectionsWithSuggestions[index];
        return _SectionForCity(
          anchorCity: entry.city,
          suggestions: entry.suggestions,
          docs: docs,
          isLikelyArrivalGateway: entry.isArrival,
          currentSegments: currentSegments,
          tripStartDate: tripStartDate,
          tripDurationDays: tripDurationDays,
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.travel_explore,
            size: 48,
            color: AppColors.textPrimary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'Pas encore de suggestions pour ton parcours',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Le catalogue Lunao s\'enrichit petit à petit. '
            'Tu peux toujours ajouter une étape manuellement.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textPrimary.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          top: BorderSide(
            color: AppColors.textPrimary.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ),
      ),
    );
  }
}

/// CTA label dérivé du mode si la suggestion ne fournit pas un override
/// `ctaLabel`. Évite "Ajouter cette étape" générique : chaque mode a une
/// formulation contextuelle. Reformulations validées Lalith 2026-05-08.
String _defaultCtaLabel(SubTripSuggestion s) {
  if (s.ctaLabel != null && s.ctaLabel!.isNotEmpty) return s.ctaLabel!;
  switch (s.insertionMode) {
    case InsertionMode.dayTrip:
      return 'Ajouter comme excursion';
    case InsertionMode.replaceAnchorGateway:
      return 'Remplacer ${s.anchorCity} par ${s.displayName}';
    case InsertionMode.nearbyStay:
      return 'Ajouter ${s.displayName} au parcours';
    case InsertionMode.splitSegment:
    case InsertionMode.splitGatewaySequence:
      // Multi-step (≥2 segments) : "Ajouter X et Y" / "Ajouter X, Y et Z"
      if (s.segments.length >= 2) {
        final names = s.segments.map((e) => e.city).toList();
        if (names.length == 2) return 'Ajouter ${names[0]} et ${names[1]}';
        final head = names.take(names.length - 1).join(', ');
        return 'Ajouter $head et ${names.last}';
      }
      // Single-step split (Hanoï → Ninh Bình + retour) : "Transformer X en Y"
      return 'Transformer ${s.anchorCity} en ${s.displayName}';
  }
}

/// Phrase courte expliquant l'impact concret sur le bloc d'étapes du
/// voyage. Affichée sur la card juste avant le CTA, en gris discret.
/// Wordings validés Lalith 2026-05-08 :
/// - dayTrip : "ajoute une excursion d'1 jour depuis [anchor], sans nuit"
/// - replaceAnchorGateway : "remplace [anchor] par [suggestion] dans planning"
/// - nearbyStay : "ajoute [seg] [regionLabel || 'au parcours']"
/// - splitSegment single-step (Ha Long depuis Hanoï) : "utilise N nuits
///   du bloc [anchor] pour ajouter [seg]" — l'anchor reste vraie étape
/// - splitSegment multi-step : "ajoute [seg1] + [seg2] depuis [anchor]"
/// - splitGatewaySequence single-step (Ninh Bình depuis Hanoï) :
///   "transforme le bloc [anchor] en [seg] + [anchor] N nuits" — anchor
///   réduit à minAnchorDaysToKeep
/// - splitGatewaySequence multi-step (Rayong+Koh Samet depuis Bangkok) :
///   "ajoute [seg1] + [seg2] après [anchor]"
String _impactText(SubTripSuggestion s) {
  String nights(int n) => n <= 1 ? '1 nuit' : '$n nuits';
  String segPart(SuggestedSegment seg) => '${seg.city} ${nights(seg.days)}';
  switch (s.insertionMode) {
    case InsertionMode.dayTrip:
      return 'Impact : ajoute une excursion d\'1 jour depuis '
          '${s.anchorCity}, sans nuit sur place.';
    case InsertionMode.nearbyStay:
      final added = s.segments.map(segPart).join(' + ');
      final tail = s.regionLabel ?? 'au parcours';
      return 'Impact : ajoute $added $tail.';
    case InsertionMode.replaceAnchorGateway:
      return 'Impact : remplace ${s.anchorCity} par ${s.displayName} '
          'dans ton planning.';
    case InsertionMode.splitSegment:
      // Sub-trip side-excursion : l'anchor reste une vraie étape, on
      // emprunte juste quelques nuits pour la suggested. Phrasé qui
      // évite l'ambiguïté "je remplace l'anchor".
      if (s.segments.length >= 2) {
        final added = s.segments.map(segPart).join(' + ');
        return 'Impact : ajoute $added depuis ${s.anchorCity}.';
      }
      // Utilise `displayName` (label court user-facing) plutôt que
      // `segment.city` (nom géographique réel utilisé en Lot 2 pour
      // l'insertion). Évite "Baie d'Ha Long" qui doublonne avec le
      // titre court "Ha Long / Lan Ha" de la card.
      final main = s.segments.first;
      return 'Impact : utilise ${nights(main.days)} du bloc '
          '${s.anchorCity} pour ajouter ${s.displayName}.';
    case InsertionMode.splitGatewaySequence:
      final added = s.segments.map(segPart).join(' + ');
      // Multi-step gateway sequence (Bangkok → Rayong + Koh Samet) :
      // phrasé "ajoute après" pour rester accessible.
      if (s.segments.length >= 2) {
        return 'Impact : ajoute $added après ${s.anchorCity}.';
      }
      // Single-step gateway sequence (Hanoï → Ninh Bình + retour à
      // Hanoï) : "transforme le bloc". minAnchorDaysToKeep = nombre
      // concret de nuits restantes à l'anchor.
      final keep = s.minAnchorDaysToKeep;
      return 'Impact : transforme le bloc ${s.anchorCity} en '
          '$added + ${s.anchorCity} ${nights(keep)}.';
  }
}

/// Section d'une ville d'ancrage : header contextuel + cards de
/// suggestions filtrées + désactivées selon conflits.
///
/// Si `isLikelyArrivalGateway` est vrai (ville parmi les 2 premiers
/// segments du voyage = probable arrivée vol), titre "Après ton arrivée
/// à X". Sinon, "Autour de X" (étape intermédiaire/finale).
class _SectionForCity extends StatelessWidget {
  final String anchorCity;
  final List<SubTripSuggestion> suggestions;
  final List<TripDocument> docs;
  final bool isLikelyArrivalGateway;
  final List<TripSegment> currentSegments;
  final DateTime tripStartDate;
  final int tripDurationDays;

  const _SectionForCity({
    required this.anchorCity,
    required this.suggestions,
    required this.docs,
    required this.isLikelyArrivalGateway,
    required this.currentSegments,
    required this.tripStartDate,
    required this.tripDurationDays,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(
            isLikelyArrivalGateway
                ? 'Après ton arrivée à $anchorCity'
                : 'Autour de $anchorCity',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppColors.primary,
            ),
          ),
        ),
        ...suggestions.map((s) => _SuggestionCard(
              suggestion: s,
              docs: docs,
              currentSegments: currentSegments,
              tripStartDate: tripStartDate,
              tripDurationDays: tripDurationDays,
            )),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Card affichant une suggestion. Lot 2.2 : CTA actif retourne la
/// `ItineraryMutation` au caller via `Navigator.pop`. Désactivée si
/// `computeMutation` retourne `MutationFailed` ou si le preflight
/// (city-level + date-précis) bloque.
class _SuggestionCard extends StatelessWidget {
  final SubTripSuggestion suggestion;
  final List<TripDocument> docs;
  final List<TripSegment> currentSegments;
  final DateTime tripStartDate;
  final int tripDurationDays;

  const _SuggestionCard({
    required this.suggestion,
    required this.docs,
    required this.currentSegments,
    required this.tripStartDate,
    required this.tripDurationDays,
  });

  @override
  Widget build(BuildContext context) {
    // ─── 1. Compute mutation (faisabilité structurelle) ──────────────
    final mutationResult = computeMutation(
      suggestion: suggestion,
      currentSegments: currentSegments,
      tripDurationDays: tripDurationDays,
    );

    // ─── 2. Preflight conflit (city-level + date-précis) ─────────────
    // Combine les 2 niveaux : block prime sur allow, notice city-level
    // peut compléter une absence de bloc date-precise.
    final preflightCity = preflightSuggestion(
      anchorCity: suggestion.anchorCity,
      suggestedCities: suggestion.segments.map((e) => e.city).toList(),
      mode: suggestion.insertionMode.name,
      docs: docs,
    );
    final preflightDate = preflightDatePrecise(
      suggestion: suggestion,
      currentSegments: currentSegments,
      tripStartDate: tripStartDate,
      docs: docs,
    );

    // ─── 3. Verdict combiné ──────────────────────────────────────────
    // - MutationFailed → disabled, raison ad-hoc.
    // - preflightDate.block → disabled (date-precise prime, info la plus
    //   fine).
    // - preflightCity.block → disabled (Lot 1 catch e.g. replace+hôtel).
    // - sinon → enabled, notice = preflightCity.notice si présent (allow
    //   with notice).
    final ItineraryMutation? mutation = mutationResult is MutationOk
        ? mutationResult.mutation
        : null;

    String? notice;
    bool isBlocked;
    if (mutationResult is MutationFailed) {
      isBlocked = true;
      notice = _mutationFailureNotice(mutationResult.reason, suggestion);
    } else if (preflightDate.verdict == SuggestionVerdict.block) {
      isBlocked = true;
      notice = preflightDate.notice;
    } else if (preflightCity.verdict == SuggestionVerdict.block) {
      isBlocked = true;
      notice = preflightCity.notice;
    } else {
      isBlocked = false;
      notice = preflightCity.verdict == SuggestionVerdict.allowWithNotice
          ? preflightCity.notice
          : null;
    }

    final hasNotice = notice != null && notice.isNotEmpty;
    final cardOpacity = isBlocked ? 0.55 : 1.0;

    return Opacity(
      opacity: cardOpacity,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.textPrimary.withValues(alpha: 0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.025),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header : displayName + badge durée
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    suggestion.displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                _DurationBadge(suggestion: suggestion),
              ],
            ),
            // Travel label
            if (suggestion.travelLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                suggestion.travelLabel!,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimary.withValues(alpha: 0.65),
                ),
              ),
            ],
            // Tags
            if (suggestion.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: suggestion.tags
                    .map((t) => _TagChip(label: t))
                    .toList(),
              ),
            ],
            // whyText : pourquoi cette suggestion
            if (suggestion.whyText != null) ...[
              const SizedBox(height: 10),
              Text(
                suggestion.whyText!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                  color: AppColors.textPrimary.withValues(alpha: 0.78),
                ),
              ),
            ],
            // Notice conflit/info
            if (hasNotice) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isBlocked
                      ? Colors.amber.withValues(alpha: 0.12)
                      : AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isBlocked ? Icons.warning_amber_rounded : Icons.info_outline,
                      size: 16,
                      color: isBlocked ? Colors.amber.shade800 : AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        notice,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: AppColors.textPrimary.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Ligne d'impact planning : décrit en 1 ligne ce que la
            // suggestion va concrètement faire au bloc d'étapes. Permet
            // à l'utilisateur de comprendre la transformation AVANT
            // d'appliquer (utile en V1 même si CTAs stubbés, indispensable
            // en V2 quand l'insertion sera réelle).
            const SizedBox(height: 10),
            Text(
              _impactText(suggestion),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary.withValues(alpha: 0.55),
              ),
            ),
            // CTA primary — Lot 2.2 : retourne la mutation au caller.
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (isBlocked || mutation == null)
                    ? null
                    : () => Navigator.of(context).pop(mutation),
                icon: Icon(
                  isBlocked ? Icons.lock_outline : Icons.add,
                  size: 18,
                ),
                label: Text(
                  _defaultCtaLabel(suggestion),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  foregroundColor: AppColors.primary,
                  side: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Map une raison `MutationFailureReason` vers un message UX humain
/// affiché sur la card désactivée. Garde le message court et orienté
/// action (l'utilisateur sait pourquoi c'est désactivé sans avoir à
/// décoder un message technique).
String _mutationFailureNotice(
  MutationFailureReason reason,
  SubTripSuggestion suggestion,
) {
  switch (reason) {
    case MutationFailureReason.anchorNotFound:
      // Ne devrait pas arriver en pratique : la sheet ne montre que
      // les villes effectivement présentes dans les segments. Garde-fou.
      return 'Cette suggestion ne correspond plus à ton itinéraire.';
    case MutationFailureReason.notEnoughDaysToSplit:
      return 'Pas assez de jours sur "${suggestion.anchorCity}" pour '
          'cette transformation. Allonge cette étape avant.';
    case MutationFailureReason.notEnoughFreeDaysToAppend:
      return 'Ton voyage est déjà complet. Libère des jours sur une '
          'autre étape avant d\'ajouter une excursion.';
  }
}

/// Badge "X nuits" / "1 jour" en haut à droite de la card.
class _DurationBadge extends StatelessWidget {
  final SubTripSuggestion suggestion;
  const _DurationBadge({required this.suggestion});

  @override
  Widget build(BuildContext context) {
    final total = suggestion.totalSuggestedDays;
    final isDayTrip =
        suggestion.insertionMode == InsertionMode.dayTrip && total == 1;
    final label = isDayTrip
        ? 'Excursion 1 jour'
        : (total == 1 ? '1 nuit' : '$total nuits');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.textPrimary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
