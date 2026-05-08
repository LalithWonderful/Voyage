/// Sheet "Quand veux-tu ajouter `<ville>` ?" — V2.3.
///
/// Ouverte depuis `improve_itinerary_sheet.dart` quand l'utilisateur tape
/// une suggestion structurelle dont
/// `suggestionRequiresInsertionDate(s) == true` (cas Krabi/Chiang Mai
/// dans Bangkok, Rayong+Koh Samet, etc.). L'utilisateur choisit une date
/// dans la liste contrainte par `validInsertionStartDates` ; la sheet
/// retourne cette date au caller, qui la passe à `computeMutation`.
///
/// Pas de date picker calendrier en V2.3 — la liste des dates valides est
/// typiquement courte (≤7 jours) et un calendrier complet avec >75% de
/// jours grisés n'aide pas. Une liste de gros boutons date est plus claire.
library;

import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/services/pinned_dates.dart';

/// Ouvre la sheet et retourne la date choisie, ou `null` si l'utilisateur
/// a fermé sans choisir.
///
/// `validDates` doit déjà être filtrée par `validInsertionStartDates`
/// (V2.1). `insertionDays` = somme des nuits insérées (multi-step =
/// somme totale, ex: Rayong 1 + Koh Samet 2 = 3).
Future<DateTime?> openPickInsertionDateSheet(
  BuildContext context, {
  required String anchorCity,
  required String displayName,
  required int insertionDays,
  required List<DateTime> validDates,
  required SegmentPinnedDates anchorPin,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PickInsertionDateSheet(
      anchorCity: anchorCity,
      displayName: displayName,
      insertionDays: insertionDays,
      validDates: validDates,
      anchorPin: anchorPin,
    ),
  );
}

class _PickInsertionDateSheet extends StatelessWidget {
  final String anchorCity;
  final String displayName;
  final int insertionDays;
  final List<DateTime> validDates;
  final SegmentPinnedDates anchorPin;

  const _PickInsertionDateSheet({
    required this.anchorCity,
    required this.displayName,
    required this.insertionDays,
    required this.validDates,
    required this.anchorPin,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: mq.size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Quand veux-tu ajouter $displayName ?',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                'Lunao découpera $anchorCity autour de $displayName. '
                'Tes vols et hôtels datés ne bougeront pas.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: validDates.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final start = validDates[i];
                    final end = start.add(Duration(days: insertionDays));
                    return _DateOption(
                      start: start,
                      endExclusive: end,
                      anchorCity: anchorCity,
                      onTap: () => Navigator.of(context).pop(start),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Annuler',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateOption extends StatelessWidget {
  final DateTime start;
  final DateTime endExclusive;
  final String anchorCity;
  final VoidCallback onTap;

  const _DateOption({
    required this.start,
    required this.endExclusive,
    required this.anchorCity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lastNight = endExclusive.subtract(const Duration(days: 1));
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatLongDate(start),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'jusqu\'au ${_formatShortDate(lastNight)} '
                      '· retour à $anchorCity',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _frenchWeekdays = [
  'Lundi', 'Mardi', 'Mercredi', 'Jeudi',
  'Vendredi', 'Samedi', 'Dimanche',
];

const _frenchMonths = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
  'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
];

String _formatLongDate(DateTime d) {
  final wd = _frenchWeekdays[(d.weekday - 1).clamp(0, 6)];
  final m = _frenchMonths[d.month - 1];
  return '$wd ${d.day} $m';
}

String _formatShortDate(DateTime d) {
  final m = _frenchMonths[d.month - 1];
  return '${d.day} $m';
}
