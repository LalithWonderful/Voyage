/// Sheet "Améliorer ton itinéraire" — Lot 1 (V1).
///
/// Affichée quand un voyage a déjà ≥2 segments d'itinéraire (typiquement
/// auto-détectés depuis les vols) ET qu'au moins une des villes d'ancrage
/// a des suggestions dans `sub_trip_suggestions.dart`.
///
/// Lot 1 (cette sheet) : lecture seule. Affiche les sections par ville
/// d'ancrage avec les cards de suggestions catalogue. Détecte les conflits
/// simples (hôtel à l'ancrage → mode replace bloqué). CTAs stubbés via
/// snackbar "Bientôt disponible".
///
/// Lot 2 (séparé) : implémentation effective des transformations
/// APPEND/SPLIT/REPLACE avec validation date-précise + retour des
/// `TripSegment` au caller.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/planning/services/sub_trip_conflict_detector.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Ouvre la sheet "Améliorer ton itinéraire". Retourne `null` en V1
/// (Lot 1) — aucune transformation n'est appliquée. La signature est
/// déjà alignée sur le futur Lot 2 où on retournera les `TripSegment`
/// à insérer.
Future<void> openImproveItinerarySheet(
  BuildContext context, {
  required String tripId,
  required List<String> anchorCities,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ImproveItinerarySheet(
      tripId: tripId,
      anchorCities: anchorCities,
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
  final List<String> anchorCities;

  const _ImproveItinerarySheet({
    required this.tripId,
    required this.anchorCities,
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
    // Dédup par ville (case-insensitive) en préservant l'ordre.
    final seen = <String>{};
    final uniqueCities = <String>[];
    for (final c in anchorCities) {
      final t = c.trim();
      if (t.isEmpty) continue;
      final key = t.toLowerCase();
      if (seen.add(key)) uniqueCities.add(t);
    }

    // Pour chaque ville, récupère les suggestions catalogue.
    // `isArrivalGateway` : on considère les 2 premières villes du parcours
    // comme probables points d'arrivée (vol AR + 1ère escale gateway).
    // Heuristique simple V1 — sera affinée en V2 si on intègre le signal
    // "ville origine d'un vol/transfert vers une autre étape".
    final sectionsWithSuggestions =
        <({String city, List<SubTripSuggestion> suggestions, bool isArrival})>[];
    for (var i = 0; i < uniqueCities.length; i++) {
      final c = uniqueCities[i];
      final s = findSuggestionsForAnchor(c);
      if (s.isNotEmpty) {
        sectionsWithSuggestions.add((
          city: c,
          suggestions: s,
          isArrival: i < 2,
        ));
      }
    }

    if (sectionsWithSuggestions.isEmpty) {
      return _buildEmptyState(context);
    }

    return ListView.builder(
      controller: scrollController,
      // Padding bottom large pour s'assurer que la dernière card ne se
      // retrouve pas masquée par le footer fixe "Fermer" (icone shadow +
      // SafeArea sur certains devices).
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: sectionsWithSuggestions.length,
      itemBuilder: (context, index) {
        final entry = sectionsWithSuggestions[index];
        return _SectionForCity(
          anchorCity: entry.city,
          suggestions: entry.suggestions,
          docs: docs,
          isLikelyArrivalGateway: entry.isArrival,
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
/// voyage. Affichée sur la card juste avant le CTA, en gris discret,
/// pour que l'utilisateur sache exactement ce qui va se passer s'il
/// applique la suggestion. Wordings validés Lalith 2026-05-08 :
/// - dayTrip : "ajoute une excursion d'1 jour depuis [anchor], sans nuit"
/// - replaceAnchorGateway : "remplace [anchor] par [suggestion] dans planning"
/// - nearbyStay : "ajoute [seg] [regionLabel || 'au parcours']"
/// - split single-step : "transforme le bloc [anchor] en [seg] + [anchor] N"
///   où N = `minAnchorDaysToKeep` (proxy raisonnable, on n'a pas le total
///   d'origine de l'anchor à ce niveau)
/// - split multi-step (≥2 seg) : "ajoute [seg1] + [seg2] après [anchor]"
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
    case InsertionMode.splitGatewaySequence:
      final added = s.segments.map(segPart).join(' + ');
      // Multi-step gateway sequence (Bangkok → Rayong + Koh Samet) :
      // phrasé "ajoute après" pour rester accessible. La nature SPLIT
      // (Bangkok réduit) reste implicite.
      if (s.segments.length >= 2) {
        return 'Impact : ajoute $added après ${s.anchorCity}.';
      }
      // Single-step split-with-return (Hanoï → Ninh Bình + retour) :
      // phrasé "transforme le bloc" pour rendre la transformation
      // explicite. On utilise minAnchorDaysToKeep comme nombre concret
      // de nuits restantes à l'anchor.
      final keep = s.minAnchorDaysToKeep;
      final keepLabel = nights(keep);
      return 'Impact : transforme le bloc ${s.anchorCity} en '
          '$added + ${s.anchorCity} $keepLabel.';
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

  const _SectionForCity({
    required this.anchorCity,
    required this.suggestions,
    required this.docs,
    required this.isLikelyArrivalGateway,
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
            )),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Card affichant une suggestion. Lot 1 : CTAs stubbés.
class _SuggestionCard extends StatelessWidget {
  final SubTripSuggestion suggestion;
  final List<TripDocument> docs;

  const _SuggestionCard({
    required this.suggestion,
    required this.docs,
  });

  @override
  Widget build(BuildContext context) {
    final preflight = preflightSuggestion(
      anchorCity: suggestion.anchorCity,
      suggestedCities: suggestion.segments.map((e) => e.city).toList(),
      mode: suggestion.insertionMode.name,
      docs: docs,
    );

    final isBlocked = preflight.verdict == SuggestionVerdict.block;
    final hasNotice = preflight.notice != null && preflight.notice!.isNotEmpty;
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
                        preflight.notice!,
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
            // CTA primary
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isBlocked ? null : () => _stubCta(context),
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

  void _stubCta(BuildContext context) {
    // Lot 1 : CTA non-fonctionnel. Lot 2 implémentera la transformation
    // segment + retour des TripSegment au caller.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Application de la suggestion : bientôt disponible (Lot 2). '
          'Pour l\'instant, ajoute l\'étape manuellement.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
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
