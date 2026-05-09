import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/trips/services/flight_timeline_builder.dart';
import 'package:voyage/features/trips/services/preserved_segments.dart';
import 'package:voyage/features/trips/services/trip_segment_sync_service.dart';
import 'package:voyage/features/trips/widgets/trip_step_card.dart';

/// Sheet de PREVIEW de la timeline déduite des vols.
/// Affichée après le save d'un doc Vol/Train (ou via "Synchroniser depuis
/// mes vols") quand le diff a des changements à proposer.
///
/// Format : timeline verticale avec dots + connecteurs, badge durée
/// proéminent, hiérarchie ville/dates/source claire. Ton humain : on parle
/// de "Lunao a détecté tes étapes", pas de "candidats" / "segmentation".
class DetectedSegmentsSheet extends StatelessWidget {
  final TripTimelineDiff diff;

  const DetectedSegmentsSheet({super.key, required this.diff});

  /// Helper pour ouvrir la sheet. Retourne true si l'utilisateur a appliqué.
  static Future<bool> show(
    BuildContext context, {
    required TripTimelineDiff diff,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Plafonne la hauteur à 90% pour que le contenu reste scrollable
      // tout en gardant les boutons en bas visibles.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      builder: (_) => DetectedSegmentsSheet(diff: diff),
    );
    return result ?? false;
  }

  /// Résumé dynamique sous l'intro : "5 étapes détectées automatiquement
  /// depuis tes billets." (singulier/pluriel adaptés).
  String _summaryText(int count) {
    final etapeWord = count > 1 ? 'étapes détectées' : 'étape détectée';
    final billetWord = count > 1 ? 'tes billets' : 'ton billet';
    return '$count $etapeWord automatiquement depuis $billetWord';
  }

  @override
  Widget build(BuildContext context) {
    final timeline = diff.timeline;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            // ─── En-tête ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "✨ Lunao a détecté tes étapes",
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Voici l'itinéraire reconstruit à partir de tes billets. "
                    "Vérifie avant d'appliquer.",
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  if (timeline.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _summaryText(timeline.length),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(height: 1, color: AppColors.border),
            // ─── Contenu scrollable ───────────────────────────────────
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                children: [
                  // Timeline verticale
                  if (timeline.isNotEmpty)
                    for (var i = 0; i < timeline.length; i++)
                      _TimelineStop(
                        stay: timeline[i],
                        isLast: i == timeline.length - 1,
                      ),

                  // Cas vide
                  if (timeline.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        "Aucun séjour n'a pu être déduit de tes vols. "
                        "Tu peux ajouter des étapes manuellement.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),

                  // Étapes à replacer
                  // V4 (2026-05-10) — sémantique : ces étapes ne sont
                  // PAS ajoutées au voyage par cette sync. Elles sont
                  // listées pour que l'user sache quoi recréer via
                  // « Affiner les étapes ».
                  // Lot C (2026-05-10) — section enrichie : titre aligné
                  // sur la spec produit (« Étapes à replacer »), pill
                  // « À replacer » sur chaque row pour la lisibilité.
                  if (diff.preservedManual.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _SectionLabel(
                      label: 'Étapes à replacer',
                      tone: _SectionTone.neutral,
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 4),
                      child: Text(
                        'Pour ne pas casser tes dates documentées, Lunao '
                        'met ces étapes de côté. Tu pourras les rajouter '
                        'via « Affiner les étapes » une fois le voyage à '
                        'jour.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final m in diff.preservedManual)
                      _ManualPreservedRow(segment: m),
                  ],

                  // Bloc "À noter"
                  if (diff.warnings.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _NoteBlock(messages: diff.warnings),
                  ],
                ],
              ),
            ),
            // ─── Boutons toujours visibles ────────────────────────────
            Container(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  // Secondaire : discret mais pas désactivé. Texte assez
                  // contrasté pour l'action, pas de fond pour ne pas
                  // concurrencer le CTA principal.
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor:
                          AppColors.textPrimary.withValues(alpha: 0.75),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Garder mes étapes',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Principal : CTA fort, prend l'espace restant.
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: timeline.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(true),
                      child: const Text(
                        'Mettre à jour mon voyage',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Sub-widgets ─────────────────────────────────────────────────────────

/// Étape de la timeline : dot bleu à gauche + connecteur vertical (sauf
/// dernière étape) + [TripStepCard] partagée à droite. La card est un
/// composant commun avec la sheet d'édition (cohérence visuelle).
class _TimelineStop extends StatelessWidget {
  final FlightStayCandidate stay;
  final bool isLast;

  const _TimelineStop({required this.stay, required this.isLast});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Colonne dot + ligne verticale. Ligne fine + teinte bleutée
          // discrète pour s'harmoniser avec les dots et donner un effet
          // de "fil conducteur" plutôt qu'un séparateur brut.
          SizedBox(
            width: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      color: AppColors.primary.withValues(alpha: 0.18),
                      margin: const EdgeInsets.only(top: 3),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
              child: TripStepCard(
                city: stay.city,
                country: stay.country,
                days: stay.days,
                startDate: stay.startDate,
                endDate: stay.endDate,
                sourceLabel: stay.sourceDocName,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _SectionTone { neutral, primary }

class _SectionLabel extends StatelessWidget {
  final String label;
  final _SectionTone tone;
  const _SectionLabel({required this.label, this.tone = _SectionTone.primary});

  @override
  Widget build(BuildContext context) {
    final color = tone == _SectionTone.primary
        ? AppColors.primary
        : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Affichage d'une étape « à replacer » — son nom n'apparaît pas dans
/// les vols et Lunao tente de la replacer aux dates d'origine si
/// possible (cf. V5.4 2026-05-10 / `autoPlacePreservedSegments`).
/// Pill orange « À replacer » pour signaler l'action demandée à
/// l'utilisateur quand ça n'a pas pu être placé automatiquement.
class _ManualPreservedRow extends StatelessWidget {
  final PreservedSegmentInfo segment;
  const _ManualPreservedRow({required this.segment});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.bookmark_outline,
              size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${segment.city} · ${segment.days} jour${segment.days > 1 ? 's' : ''}',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.accentLight.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'À replacer',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bloc d'information rassurant en bas de la sheet ("Bangkok sera séparé
/// en 2 séjours, car deux passages ont été détectés dans tes vols.").
class _NoteBlock extends StatelessWidget {
  final List<String> messages;
  const _NoteBlock({required this.messages});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accentLight.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline,
                  size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Text(
                'À NOTER',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final m in messages) ...[
            const SizedBox(height: 2),
            Text(
              m,
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.textPrimary,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
