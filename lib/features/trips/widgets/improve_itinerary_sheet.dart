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
import 'package:voyage/features/planning/services/pinned_dates.dart';
import 'package:voyage/features/planning/services/sub_trip_conflict_detector.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/itinerary_mutation.dart';
import 'package:voyage/features/trips/widgets/pick_insertion_date_sheet.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Ouvre la sheet "Améliorer ton itinéraire". Retourne la liste des
/// mutations choisies par l'utilisateur (multi-select), ou `null` /
/// liste vide s'il a annulé / fermé sans rien sélectionner. Le caller
/// est responsable de validateMutationBatch puis applyMutationBatch.
Future<List<ItineraryMutation>?> openImproveItinerarySheet(
  BuildContext context, {
  required String tripId,
  required List<TripSegment> currentSegments,
  required DateTime tripStartDate,
  required int tripDurationDays,
}) async {
  return showModalBottomSheet<List<ItineraryMutation>>(
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

class _ImproveItinerarySheet extends ConsumerStatefulWidget {
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
  ConsumerState<_ImproveItinerarySheet> createState() =>
      _ImproveItinerarySheetState();
}

class _ImproveItinerarySheetState
    extends ConsumerState<_ImproveItinerarySheet> {
  // Set des `_ResolvedSuggestion` actuellement sélectionnées par l'user.
  // ID stable basé sur `(anchorCity, displayName, insertionMode)` :
  // doit être unique PAR VARIANT (Ninh Bình stay vs Ninh Bình dayTrip
  // ont le même displayName mais sont 2 cards distinctes).
  final Set<String> _selectedKeys = <String>{};

  /// V2.3 — Dates choisies au date picker pour les cards
  /// `requiresInsertionDate`. Indexé par la même clé que `_selectedKeys` ;
  /// une entrée existe ssi la card est sélectionnée ET demande une date.
  /// Utilisé à `_applySelection` pour passer la date à `computeMutation`
  /// et obtenir un 3-way split correct.
  final Map<String, DateTime> _selectionDates = <String, DateTime>{};

  String _idFor(_ResolvedSuggestion r) =>
      '${r.suggestion.anchorCity}|${r.suggestion.displayName}|'
      '${r.suggestion.insertionMode.name}|${r.mutation.anchorIndex}';

  /// Clé d'EXCLUSIVITÉ entre alternatives : `(anchor, firstTargetCity)`
  /// normalisés. 2 suggestions partageant la même exclusivity key sont
  /// alternatives — l'user ne peut en sélectionner qu'une à la fois.
  /// Exemples :
  /// - Hanoï→Ninh Bình stay  & Hanoï→Ninh Bình dayTrip → même clé
  ///   "hanoi|ninh binh"
  /// - Hanoï→Ha Long stay & Hanoï→Ha Long dayTrip → même clé
  ///   "hanoi|baie d'ha long"
  /// Multi-step (Bangkok→Rayong+Koh Samet) utilise la 1re ville
  /// (Rayong) — pas de collision actuelle dans le catalogue.
  String _exclusivityKeyFor(_ResolvedSuggestion r) {
    final firstCity = r.suggestion.segments.isEmpty
        ? ''
        : r.suggestion.segments.first.city;
    return '${_normalizeCityName(r.suggestion.anchorCity)}|'
        '${_normalizeCityName(firstCity)}';
  }

  /// V2 multi-window — construit un label compact pour distinguer
  /// plusieurs cards majorDestination ciblant le même nom de ville à
  /// des moments différents du voyage. Heuristique :
  /// - segment SUIVANT d'une autre ville → "Avant {nextCity}"
  /// - sinon segment PRÉCÉDENT d'une autre ville → "Après {prevCity}"
  /// - sinon (segment isolé) → "Pendant {anchorCity}".
  String _buildWindowLabel(List<TripSegment> segments, int anchorIdx) {
    final anchorCityNorm =
        _normalizeCityName(segments[anchorIdx].city);
    for (var i = anchorIdx + 1; i < segments.length; i++) {
      if (_normalizeCityName(segments[i].city) != anchorCityNorm) {
        return 'Avant ${segments[i].city}';
      }
    }
    for (var i = anchorIdx - 1; i >= 0; i--) {
      if (_normalizeCityName(segments[i].city) != anchorCityNorm) {
        return 'Après ${segments[i].city}';
      }
    }
    return 'Pendant ${segments[anchorIdx].city}';
  }

  Future<void> _toggle(_ResolvedSuggestion r) async {
    final key = _idFor(r);
    if (_selectedKeys.contains(key)) {
      setState(() {
        _selectedKeys.remove(key);
        _selectionDates.remove(key);
      });
      return;
    }

    // V2.3 — cards requiresInsertionDate : ouvrir le picker AVANT
    // d'ajouter à la sélection. Si l'user annule, on n'ajoute rien.
    if (suggestionRequiresInsertionDate(r.suggestion)) {
      final docs = ref.read(tripDocumentsProvider(widget.tripId)).maybeWhen(
            data: (d) => d,
            orElse: () => const <TripDocument>[],
          );
      final analysis = analyzePinnedDates(
        segments: widget.currentSegments,
        tripStartDate: widget.tripStartDate,
        docs: docs,
      );
      // V2 (fix Bangkok dupliqué) — viser le segment exact que la
      // mutation a déjà résolu (longest pour majorDestination, sinon
      // premier match), pas n'importe quel Bangkok.
      final anchorIdx = r.mutation.anchorIndex;
      if (anchorIdx < 0 || anchorIdx >= analysis.segments.length) return;
      final anchorPin = analysis.segments[anchorIdx];
      final validDates = validInsertionStartDates(
        anchorCity: r.suggestion.anchorCity,
        insertionDays: r.suggestion.totalSuggestedDays,
        analysis: analysis,
        anchorSegmentIndex: anchorIdx,
      );
      if (validDates.isEmpty) return;
      final chosen = await openPickInsertionDateSheet(
        context,
        anchorCity: r.suggestion.anchorCity,
        displayName: r.suggestion.displayName,
        insertedSegments: r.suggestion.segments
            .map((s) => (city: s.city, nights: s.days))
            .toList(),
        validDates: validDates,
        anchorPin: anchorPin,
      );
      if (chosen == null || !mounted) return;
      setState(() {
        _selectedKeys.add(key);
        _selectionDates[key] = chosen;
      });
      return;
    }

    setState(() => _selectedKeys.add(key));
  }

  @override
  Widget build(BuildContext context) {
    final docsAsync = ref.watch(tripDocumentsProvider(widget.tripId));

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
    for (final s in widget.currentSegments) {
      final t = s.city.trim();
      if (t.isEmpty) continue;
      final key = t.toLowerCase();
      if (seen.add(key)) uniqueCities.add(t);
    }

    // V2.3 — analyse des dates pinnées (vols/hôtels datés) pour filtrer
    // les cards qui exigent une date d'insertion mais n'ont aucune date
    // valide. Pure computation, recalculée à chaque rebuild.
    final pinnedAnalysis = analyzePinnedDates(
      segments: widget.currentSegments,
      tripStartDate: widget.tripStartDate,
      docs: docs,
    );

    // Pour chaque ville, récupère les suggestions catalogue puis FILTRE
    // celles qui ne sont pas applicables (MutationFailed ou preflight
    // bloqué = conflit hôtel city-level / date-précis). Demande UX
    // Lalith 2026-05-08 : ne pas afficher de card non actionnable, ça
    // crée du bruit visuel sans valeur.
    //
    // `isArrival` (= titre "Après ton arrivée à X") : data-driven via
    // les modes des suggestions catalogue (pas le subset filtré). Une
    // ville est traitée comme gateway si AU MOINS une de ses suggestions
    // catalogue est mode `replaceAnchorGateway` ou `splitGatewaySequence`,
    // même si toutes ces suggestions sont actuellement bloquées par un
    // hôtel — le statut sémantique de la ville reste "gateway".
    // Une ville peut avoir 2 sections distinctes (gateway vs
    // majorDestination) — on émet 2 entrées sectionsWithSuggestions
    // pour Bangkok si les 2 catégories sont peuplées.
    final sectionsWithSuggestions = <({
      String city,
      List<_ResolvedSuggestion> resolved,
      bool isArrival,
      SuggestionCategory category,
    })>[];
    for (final c in uniqueCities) {
      final catalogue = findSuggestionsForAnchor(c);
      if (catalogue.isEmpty) continue;
      // `isArrival` calculé sur le catalogue complet (avant filtrage),
      // pour que le statut sémantique de la ville reste stable même
      // si les cards gateway sont actuellement bloquées par hôtel.
      final isArrival = catalogue.any(
        (e) =>
            e.insertionMode == InsertionMode.replaceAnchorGateway ||
            e.insertionMode == InsertionMode.splitGatewaySequence,
      );

      // Résout chaque suggestion (filtre block / déjà appliquée /
      // arrival anchor manquant / minAnchorDaysToShow) puis groupe
      // par catégorie d'affichage.
      final byCategory = <SuggestionCategory, List<_ResolvedSuggestion>>{
        SuggestionCategory.gateway: [],
        SuggestionCategory.majorDestination: [],
      };
      for (final s in catalogue) {
        // V2 multi-window : pour majorDestination, fan-out une card par
        // segment d'ancrage matchant (Krabi proposé sur Bangkok aller +
        // Bangkok retour). Les autres catégories gardent 1 card via
        // résolution auto (la sélection longest/first reste).
        if (s.category == SuggestionCategory.majorDestination) {
          final indices = findAllAnchorIndicesForSuggestion(
            widget.currentSegments,
            s,
          );
          // 1 seule fenêtre → pas de label, comportement single-window.
          // ≥2 fenêtres → label de désambiguation par card.
          final emitLabel = indices.length >= 2;
          for (final idx in indices) {
            final r = _resolveSuggestion(
              suggestion: s,
              currentSegments: widget.currentSegments,
              tripStartDate: widget.tripStartDate,
              tripDurationDays: widget.tripDurationDays,
              docs: docs,
              pinnedAnalysis: pinnedAnalysis,
              anchorOverrideIndex: idx,
              windowLabel: emitLabel
                  ? _buildWindowLabel(widget.currentSegments, idx)
                  : null,
            );
            if (r == null) continue;
            byCategory[s.category]!.add(r);
          }
          continue;
        }
        final r = _resolveSuggestion(
          suggestion: s,
          currentSegments: widget.currentSegments,
          tripStartDate: widget.tripStartDate,
          tripDurationDays: widget.tripDurationDays,
          docs: docs,
          pinnedAnalysis: pinnedAnalysis,
        );
        if (r == null) continue;
        byCategory[s.category]!.add(r);
      }

      // Émettre les sections dans cet ordre : gateway puis
      // majorDestination (gateway = plus pertinent à l'arrivée,
      // majorDestination = à proposer après).
      final gateway = byCategory[SuggestionCategory.gateway]!;
      if (gateway.isNotEmpty) {
        sectionsWithSuggestions.add((
          city: c,
          resolved: gateway,
          isArrival: isArrival,
          category: SuggestionCategory.gateway,
        ));
      }
      final major = byCategory[SuggestionCategory.majorDestination]!;
      if (major.isNotEmpty) {
        sectionsWithSuggestions.add((
          city: c,
          resolved: major,
          isArrival: isArrival,
          category: SuggestionCategory.majorDestination,
        ));
      }
    }

    if (sectionsWithSuggestions.isEmpty) {
      // Distinction subtile : si AUCUNE suggestion n'existe au catalogue
      // pour les villes du voyage → "pas de suggestions". Si des
      // suggestions existent mais sont TOUTES bloquées → message dédié
      // qui pointe vers les réservations comme cause probable.
      final hasAnyCatalogue = uniqueCities
          .any((c) => findSuggestionsForAnchor(c).isNotEmpty);
      return _buildEmptyState(context, allBlocked: hasAnyCatalogue);
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
          resolved: entry.resolved,
          isLikelyArrivalGateway: entry.isArrival,
          category: entry.category,
          selectedKeys: _selectedKeys,
          idFor: _idFor,
          isDisabled: (r) => _isCardDisabled(r, sectionsWithSuggestions),
          onToggle: _toggle,
        );
      },
    );
  }

  /// Renvoie tous les `_ResolvedSuggestion` actuellement sélectionnés
  /// dans toutes les sections. Sert au sticky footer (count) et au
  /// retour au caller via `Navigator.pop`.
  List<_ResolvedSuggestion> _collectSelected(
    List<({String city, List<_ResolvedSuggestion> resolved, bool isArrival, SuggestionCategory category})>
        sections,
  ) {
    final out = <_ResolvedSuggestion>[];
    for (final s in sections) {
      for (final r in s.resolved) {
        if (_selectedKeys.contains(_idFor(r))) out.add(r);
      }
    }
    return out;
  }

  /// Détermine si la card `r` doit être désactivée (greyed + un-tappable)
  /// vu la sélection courante. Règles MVP — Lalith 2026-05-08 :
  /// - Si une autre suggestion STRUCTURELLE (SPLIT/REPLACE) est déjà
  ///   sélectionnée pour le même anchor → désactiver les autres
  ///   structurelles du même anchor
  /// - Si une REPLACE est sélectionnée pour anchor X → désactiver TOUTES
  ///   les autres suggestions sur X (anchor disparaît)
  /// - Si la sélection courante remplit déjà les jours libres →
  ///   désactiver les APPEND restantes qui ne tiennent plus
  /// La card courante elle-même n'est jamais "désactivée par
  /// elle-même" — l'user peut toujours la décocher.
  bool _isCardDisabled(
    _ResolvedSuggestion candidate,
    List<({String city, List<_ResolvedSuggestion> resolved, bool isArrival, SuggestionCategory category})>
        sections,
  ) {
    final candKey = _idFor(candidate);
    if (_selectedKeys.contains(candKey)) return false; // déjà sélectionnée

    final selected = _collectSelected(sections);

    // ─── Règle exclusivité (Lalith 2026-05-08) ──────────────────────
    // 2 suggestions partageant la même `(anchor, firstTargetCity)`
    // sont des alternatives mutuellement exclusives (ex: Ninh Bình
    // stay vs Ninh Bình dayTrip). Si l'user a déjà sélectionné une
    // variante, l'autre devient indisponible.
    final candExKey = _exclusivityKeyFor(candidate);
    for (final s in selected) {
      if (_exclusivityKeyFor(s) == candExKey) return true;
    }

    final candAnchor = candidate.suggestion.anchorCity.toLowerCase().trim();
    final candIsStructural = candidate.mutation.isStructural;
    final candIsReplace = candidate.mutation.removesAnchor;

    for (final s in selected) {
      final selAnchor = s.suggestion.anchorCity.toLowerCase().trim();
      if (selAnchor != candAnchor) continue;
      // Même anchor.
      if (s.mutation.removesAnchor) {
        // REPLACE déjà sélectionné → toute autre suggestion sur cet
        // anchor devient impossible.
        return true;
      }
      // Sinon, conflit uniquement si la candidate est structurelle.
      if (candIsStructural && s.mutation.isStructural) return true;
      if (candIsReplace) {
        // Cand veut remplacer mais une autre mutation sur l'anchor
        // est déjà sélectionnée → REPLACE incompatible.
        return true;
      }
    }

    // Vérif jours libres pour APPEND.
    if (!candIsStructural) {
      final currentTotal = widget.currentSegments
          .fold<int>(0, (sum, s) => sum + s.days);
      final freeDays = widget.tripDurationDays - currentTotal;
      // Somme des APPEND déjà sélectionnés (pas la candidate).
      final selectedAppendDays = selected
          .where((r) => !r.mutation.isStructural)
          .fold<int>(
              0,
              (sum, r) =>
                  sum +
                  r.mutation.insertedSegments.fold<int>(0, (s, e) => s + e.days));
      final candAppendDays = candidate.mutation.insertedSegments
          .fold<int>(0, (s, e) => s + e.days);
      if (selectedAppendDays + candAppendDays > freeDays) return true;
    }

    return false;
  }

  /// Empty state. Si `allBlocked=false` : aucune suggestion catalogue
  /// pour les villes du voyage. Si `allBlocked=true` : des suggestions
  /// existent mais sont TOUTES bloquées par les réservations actuelles
  /// (typiquement hôtels couvrant les nuits affectées par les
  /// transformations).
  Widget _buildEmptyState(BuildContext context, {required bool allBlocked}) {
    final title = allBlocked
        ? 'Aucune amélioration possible pour l\'instant'
        : 'Pas encore de suggestions pour ton parcours';
    final subtitle = allBlocked
        ? 'Toutes les transformations entreraient en conflit avec '
            'tes réservations actuelles. Modifie tes hôtels ou tes '
            'étapes si tu veux explorer d\'autres options.'
        : 'Le catalogue Lunao s\'enrichit petit à petit. '
            'Tu peux toujours ajouter une étape manuellement.';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            allBlocked ? Icons.event_busy : Icons.travel_explore,
            size: 48,
            color: AppColors.textPrimary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
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
    final count = _selectedKeys.length;
    final hasSelection = count > 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasSelection) ...[
              Text(
                count == 1
                    ? '1 suggestion sélectionnée'
                    : '$count suggestions sélectionnées',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (hasSelection) ...[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _applySelection,
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        count == 1
                            ? 'Appliquer 1 modification'
                            : 'Appliquer $count modifications',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      child: const Text('Fermer'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tape "Appliquer N modifications" : récupère les `_ResolvedSuggestion`
  /// sélectionnées (à travers toutes les sections), extrait la mutation
  /// de chacune, et pop la sheet avec la liste. Le caller fait la
  /// validation `validateMutationBatch` puis `applyMutationBatch`.
  void _applySelection() {
    // On reconstruit la liste flat des resolved en re-parcourant le
    // catalogue (le state ne mémorise pas le résultat de _buildBody).
    final docsAsync = ref.read(tripDocumentsProvider(widget.tripId));
    final docs = docsAsync.maybeWhen(
      data: (d) => d,
      orElse: () => const <TripDocument>[],
    );
    // V2.3 — recompute analysis avec les docs courants pour que les
    // mutations renvoyées portent un `insertionPreDays` correct.
    final pinnedAnalysis = analyzePinnedDates(
      segments: widget.currentSegments,
      tripStartDate: widget.tripStartDate,
      docs: docs,
    );
    final mutations = <ItineraryMutation>[];
    final seenCities = <String>{};
    for (final s in widget.currentSegments) {
      final t = s.city.trim();
      if (t.isEmpty) continue;
      if (!seenCities.add(t.toLowerCase())) continue;
      final catalogue = findSuggestionsForAnchor(t);
      for (final sug in catalogue) {
        // V2 multi-window — pour majorDestination, on doit recalculer
        // pour CHAQUE anchor index possible (= chaque card affichée).
        // Pour les autres catégories, 1 seule preview comme avant.
        final indicesToTry = sug.category == SuggestionCategory.majorDestination
            ? findAllAnchorIndicesForSuggestion(widget.currentSegments, sug)
            : <int>[-1]; // sentinel : laisser _resolveSuggestion choisir
        for (final overrideIdx in indicesToTry) {
          final preview = _resolveSuggestion(
            suggestion: sug,
            currentSegments: widget.currentSegments,
            tripStartDate: widget.tripStartDate,
            tripDurationDays: widget.tripDurationDays,
            docs: docs,
            pinnedAnalysis: pinnedAnalysis,
            anchorOverrideIndex: overrideIdx >= 0 ? overrideIdx : null,
          );
          if (preview == null) continue;
          final key = _idFor(preview);
          if (!_selectedKeys.contains(key)) continue;
          // Re-compute avec la date choisie pour les cards V2.3.
          final pickedDate = _selectionDates[key];
          final r = pickedDate == null
              ? preview
              : _resolveSuggestion(
                  suggestion: sug,
                  currentSegments: widget.currentSegments,
                  tripStartDate: widget.tripStartDate,
                  tripDurationDays: widget.tripDurationDays,
                  docs: docs,
                  pinnedAnalysis: pinnedAnalysis,
                  insertionStartDate: pickedDate,
                  anchorOverrideIndex: overrideIdx >= 0 ? overrideIdx : null,
                );
          if (r == null) continue;
          mutations.add(r.mutation);
        }
      }
    }
    Navigator.of(context).pop(mutations);
  }
}

/// Résultat de la résolution d'une suggestion : mutation calculée +
/// notice optionnelle (allowWithNotice). Ne contient que des cards
/// AFFICHABLES (mutation OK + preflight non-block). Les blocked et
/// MutationFailed sont filtrés en amont, retour null.
///
/// V2 multi-window : si la même ville d'ancrage apparaît plusieurs fois
/// dans le voyage (Bangkok aller + retour), on émet une `_ResolvedSuggestion`
/// par fenêtre compatible. `windowLabel` distingue les cards à l'écran.
class _ResolvedSuggestion {
  final SubTripSuggestion suggestion;
  final ItineraryMutation mutation;
  final String? notice;

  /// V2 multi-window — sous-titre court pour distinguer la fenêtre
  /// d'insertion ("Avant Phú Quốc", "Après Hội An"). Null quand un seul
  /// segment matche → pas de désambiguation nécessaire.
  final String? windowLabel;

  const _ResolvedSuggestion({
    required this.suggestion,
    required this.mutation,
    required this.notice,
    this.windowLabel,
  });
}

/// Normalise un nom de ville (case + diacritiques). Aligné sur les
/// helpers `_normalize` dans `sub_trip_conflict_detector.dart` et
/// `_normalizeCity` dans `sub_trip_suggestions.dart` (pattern projet).
String _normalizeCityName(String s) {
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

/// Compute mutation + preflight pour une suggestion, et retourne :
/// - `null` si la suggestion n'est pas applicable (MutationFailed OU
///   preflight city-level / date-précis = block, OU déjà appliquée)
///   → la card sera masquée
/// - `_ResolvedSuggestion` sinon (ALLOW ou ALLOW_WITH_NOTICE)
///
/// Demande UX Lalith 2026-05-08 : ne pas afficher les cards non
/// actionnables, ça pollue la sheet sans valeur ajoutée.
_ResolvedSuggestion? _resolveSuggestion({
  required SubTripSuggestion suggestion,
  required List<TripSegment> currentSegments,
  required DateTime tripStartDate,
  required int tripDurationDays,
  required List<TripDocument> docs,
  PinnedDatesAnalysis? pinnedAnalysis,
  DateTime? insertionStartDate,
  int? anchorOverrideIndex,
  String? windowLabel,
}) {
  // ─── 0. Filtre "déjà appliquée" ────────────────────────────────────
  // Si AU MOINS UNE des villes suggérées est déjà présente dans les
  // segments du voyage → masquer la card (la suggestion a probablement
  // déjà été appliquée, ou la ville a été ajoutée manuellement). Évite
  // les doublons après application sur multi-step (ex: Rayong + Koh
  // Samet qui restait visible après ajout). Spec Lalith 2026-05-08.
  // MVP : on hide dès qu'UNE des cibles est présente — on ne propose
  // pas une suggestion partielle (ex: si user a Rayong mais pas Koh
  // Samet, on ne propose pas l'ajout du seul Koh Samet via cette card).
  final existingCitiesNorm = currentSegments
      .map((s) => _normalizeCityName(s.city))
      .where((c) => c.isNotEmpty)
      .toSet();
  final anyTargetAlreadyPresent = suggestion.segments
      .any((s) => existingCitiesNorm.contains(_normalizeCityName(s.city)));
  if (anyTargetAlreadyPresent) return null;

  // ─── 0.5 splitGatewaySequence single-step : exige arrival anchor ───
  // Single-step (Hanoï→Ninh Bình) ne demande pas de date picker (V2.2
  // : `requiresInsertionDate=false` pour ce cas) mais requiert un
  // arrival anchor fiable — sinon on ne sait pas si le user arrive
  // vraiment à la gateway au début du segment et l'heuristique MVP
  // (insertion en début de bloc) peut produire des dates aberrantes.
  // Le cas multi-step est désormais géré par le date picker (V2.3).
  if (suggestion.insertionMode == InsertionMode.splitGatewaySequence &&
      suggestion.segments.length < 2 &&
      !hasReliableArrivalAnchor(suggestion.anchorCity, docs)) {
    return null;
  }

  // V2 (fix Bangkok dupliqué) — pré-résolution du segment ancrage. Pour
  // majorDestination, choisit le segment LE PLUS LONG (= cible légitime
  // du rééquilibrage). Tous les filtres en aval (validInsertionStartDates,
  // minAnchorDaysToShow) utilisent ce segment, pas le premier match.
  //
  // V2 multi-window : si `anchorOverrideIndex` est fourni, le caller a
  // explicitement choisi une fenêtre (cas Krabi sur Bangkok aller vs
  // retour) → on respecte ce choix.
  final int resolvedAnchorIdx;
  if (anchorOverrideIndex != null &&
      anchorOverrideIndex >= 0 &&
      anchorOverrideIndex < currentSegments.length &&
      _normalizeCityName(currentSegments[anchorOverrideIndex].city) ==
          _normalizeCityName(suggestion.anchorCity)) {
    resolvedAnchorIdx = anchorOverrideIndex;
  } else {
    resolvedAnchorIdx =
        findAnchorIndexForSuggestion(currentSegments, suggestion);
    if (resolvedAnchorIdx < 0) return null;
  }

  // ─── 0.55 V2.3 — Filtre cards requiresInsertionDate sans dates ────
  // Si la suggestion exige une date (Krabi/Chiang Mai/Rayong+Koh Samet)
  // mais qu'aucune date d'insertion valide n'existe (segment ancrage
  // entièrement contraint par des transports/hôtels pinnés), inutile
  // de l'afficher : elle serait dé-tappable.
  if (suggestionRequiresInsertionDate(suggestion) && pinnedAnalysis != null) {
    final dates = validInsertionStartDates(
      anchorCity: suggestion.anchorCity,
      insertionDays: suggestion.totalSuggestedDays,
      analysis: pinnedAnalysis,
      anchorSegmentIndex: resolvedAnchorIdx,
    );
    if (dates.isEmpty) return null;
  }

  // ─── 0.6 Filtre minAnchorDaysToShow ───────────────────────────────
  // Suggestions catégorie `majorDestination` (Chiang Mai, Krabi…) ne
  // s'affichent que si le segment d'ancrage est suffisamment long
  // (typiquement Bangkok > 7 nuits). Évite de proposer Chiang Mai
  // quand Bangkok ne fait que 3 nuits.
  if (suggestion.minAnchorDaysToShow != null) {
    final anchorSegResolved = currentSegments[resolvedAnchorIdx];
    if (anchorSegResolved.days < suggestion.minAnchorDaysToShow!) {
      return null;
    }
  }

  final mutationResult = computeMutation(
    suggestion: suggestion,
    currentSegments: currentSegments,
    tripDurationDays: tripDurationDays,
    insertionStartDate: insertionStartDate,
    pinnedAnalysis: pinnedAnalysis,
    anchorOverrideIndex: resolvedAnchorIdx,
  );
  if (mutationResult is MutationFailed) return null;
  final mutation = (mutationResult as MutationOk).mutation;

  final preflightCity = preflightSuggestion(
    anchorCity: suggestion.anchorCity,
    suggestedCities: suggestion.segments.map((e) => e.city).toList(),
    mode: suggestion.insertionMode.name,
    docs: docs,
  );
  if (preflightCity.verdict == SuggestionVerdict.block) return null;

  final preflightDate = preflightDatePrecise(
    suggestion: suggestion,
    currentSegments: currentSegments,
    tripStartDate: tripStartDate,
    docs: docs,
  );
  if (preflightDate.verdict == SuggestionVerdict.block) return null;

  // Notice positive (allowWithNotice) éventuellement présente côté
  // city-level (« ton hôtel est à la ville suggérée, ça colle »).
  final notice = preflightCity.verdict == SuggestionVerdict.allowWithNotice
      ? preflightCity.notice
      : null;

  return _ResolvedSuggestion(
    suggestion: suggestion,
    mutation: mutation,
    notice: notice,
    windowLabel: windowLabel,
  );
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
  /// Liste des suggestions DÉJÀ résolues (filtrées des cas non
  /// actionnables côté hôtel/conflits). Les cards affichées peuvent
  /// néanmoins être désactivées par `isDisabled` (conflit batch).
  final List<_ResolvedSuggestion> resolved;
  final bool isLikelyArrivalGateway;
  /// Catégorie d'affichage. Pilote le titre + sous-titre de section :
  /// - `gateway` : "Après ton arrivée à X" / "Autour de X"
  /// - `majorDestination` : "Rééquilibrer ton long séjour à X" +
  ///   sous-titre explicatif.
  final SuggestionCategory category;
  final Set<String> selectedKeys;
  final String Function(_ResolvedSuggestion) idFor;
  final bool Function(_ResolvedSuggestion) isDisabled;
  final void Function(_ResolvedSuggestion) onToggle;

  const _SectionForCity({
    required this.anchorCity,
    required this.resolved,
    required this.isLikelyArrivalGateway,
    required this.category,
    required this.selectedKeys,
    required this.idFor,
    required this.isDisabled,
    required this.onToggle,
  });

  String get _sectionTitle {
    if (category == SuggestionCategory.majorDestination) {
      return 'Rééquilibrer ton long séjour à $anchorCity';
    }
    return isLikelyArrivalGateway
        ? 'Après ton arrivée à $anchorCity'
        : 'Autour de $anchorCity';
  }

  String? get _sectionSubtitle {
    if (category == SuggestionCategory.majorDestination) {
      return 'Ton séjour à $anchorCity est long. Tu peux utiliser '
          'quelques nuits pour ajouter une grande étape.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _sectionSubtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(4, 16, 4, subtitle == null ? 8 : 4),
          child: Text(
            _sectionTitle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppColors.primary,
            ),
          ),
        ),
        if (subtitle != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppColors.textPrimary.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
        ...resolved.map((r) => _SuggestionCard(
              resolved: r,
              isSelected: selectedKeys.contains(idFor(r)),
              isDisabled: isDisabled(r),
              onToggle: () => onToggle(r),
            )),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Card affichant une suggestion résolue. Multi-select V2.3 : tap
/// toggle la sélection (au lieu d'apply direct). Désactivée
/// dynamiquement si conflit batch (autre sélection rend celle-ci
/// impossible) — visuellement greyed out + non tappable.
class _SuggestionCard extends StatelessWidget {
  final _ResolvedSuggestion resolved;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onToggle;

  const _SuggestionCard({
    required this.resolved,
    required this.isSelected,
    required this.isDisabled,
    required this.onToggle,
  });

  SubTripSuggestion get suggestion => resolved.suggestion;
  ItineraryMutation get mutation => resolved.mutation;
  String? get notice => resolved.notice;

  @override
  Widget build(BuildContext context) {
    final hasNotice = notice != null && notice!.isNotEmpty;
    // Card disabled = greyed + un-tappable. Sélectionnée = bordure
    // primary + fond légèrement teinté. Sinon : neutre tappable.
    final cardOpacity = isDisabled ? 0.45 : 1.0;
    final borderColor = isSelected
        ? AppColors.primary.withValues(alpha: 0.6)
        : AppColors.textPrimary.withValues(alpha: 0.08);
    final bgColor = isSelected
        ? AppColors.primary.withValues(alpha: 0.04)
        : Colors.white;
    final borderWidth = isSelected ? 1.5 : 1.0;

    return Opacity(
      opacity: cardOpacity,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: borderWidth),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.025),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: isDisabled ? null : onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header : checkbox + displayName + badge durée
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SelectIndicator(
                        isSelected: isSelected,
                        isDisabled: isDisabled,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              suggestion.displayName,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            // V2 multi-window — sous-titre de fenêtre
                            // ("Avant Phú Quốc" / "Après Hội An") quand
                            // la même ville d'ancrage apparaît plusieurs
                            // fois dans le voyage.
                            if (resolved.windowLabel != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                resolved.windowLabel!,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.primary
                                      .withValues(alpha: 0.85),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      _DurationBadge(suggestion: suggestion),
                    ],
                  ),
                  // Travel label
                  if (suggestion.travelLabel != null) ...[
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 32),
                      child: Text(
                        suggestion.travelLabel!,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary.withValues(alpha: 0.65),
                        ),
                      ),
                    ),
                  ],
                  // Tags
                  if (suggestion.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 32),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: suggestion.tags
                            .map((t) => _TagChip(label: t))
                            .toList(),
                      ),
                    ),
                  ],
                  // whyText : pourquoi cette suggestion
                  if (suggestion.whyText != null) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(left: 32),
                      child: Text(
                        suggestion.whyText!,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          fontStyle: FontStyle.italic,
                          color: AppColors.textPrimary.withValues(alpha: 0.78),
                        ),
                      ),
                    ),
                  ],
                  // Notice info (allowWithNotice — hôtel à la suggested
                  // city, etc.). Block hôtel sont déjà filtrées en amont.
                  if (hasNotice) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(left: 32),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                notice!,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color:
                                      AppColors.textPrimary.withValues(alpha: 0.85),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  // Ligne d'impact planning
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(
                      _impactText(suggestion),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Indicateur visuel multi-select à gauche de la card. État vide /
/// rempli (selected) / disabled (greyed). Pas de Checkbox material
/// classique — on garde un design custom plus discret.
class _SelectIndicator extends StatelessWidget {
  final bool isSelected;
  final bool isDisabled;
  const _SelectIndicator({required this.isSelected, required this.isDisabled});

  @override
  Widget build(BuildContext context) {
    final color = isDisabled
        ? AppColors.textPrimary.withValues(alpha: 0.25)
        : isSelected
            ? AppColors.primary
            : AppColors.textPrimary.withValues(alpha: 0.4);
    return Container(
      width: 22,
      height: 22,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        color: isSelected ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: isSelected
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : null,
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
