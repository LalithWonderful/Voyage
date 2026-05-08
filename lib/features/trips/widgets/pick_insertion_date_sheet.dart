/// Sheet "Quand veux-tu ajouter `<ville>` ?" — V2.3 + multi-window.
///
/// Ouverte depuis `improve_itinerary_sheet.dart` quand l'utilisateur tape
/// une suggestion structurelle dont
/// `suggestionRequiresInsertionDate(s) == true` (cas Krabi/Chiang Mai
/// dans Bangkok, Rayong+Koh Samet, etc.).
///
/// Multi-window (Lalith 2026-05-08) : si la même ville d'ancrage apparaît
/// plusieurs fois dans le voyage (Bangkok aller + retour), une seule
/// card `Krabi` est affichée mais le picker liste les dates valides
/// regroupées par fenêtre ("Avant Phú Quốc", "Après Hội An"). L'user
/// choisit la fenêtre ET la date en un seul geste.
///
/// Pas de date picker calendrier — la liste des dates valides est
/// typiquement courte (≤30 jours par fenêtre) et un calendrier complet
/// avec >75 % de jours grisés n'aide pas. Une liste de gros boutons est
/// plus claire.
library;

import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';

/// Détail d'un segment inséré pour l'affichage (ex: Rayong 1 nuit).
typedef InsertionSegmentSummary = ({String city, int nights});

/// Une fenêtre d'insertion compatible. Pour Krabi 3n quand Bangkok
/// apparaît 2 fois dans le voyage, on émet 2 `InsertionWindow` :
/// - "Avant Phú Quốc" : anchorSegmentIndex=0, validStartDates=[22/06..29/06]
/// - "Après Hội An"   : anchorSegmentIndex=4, validStartDates=[15/07..02/08]
class InsertionWindow {
  /// Index du segment d'ancrage dans la liste de segments AU MOMENT du
  /// calcul. Sert à `computeMutation` (via `anchorOverrideIndex`) pour
  /// cibler le bon Bangkok à l'application.
  final int anchorSegmentIndex;

  /// Label compact pour distinguer les fenêtres ("Avant Phú Quốc",
  /// "Après Hội An"). Null/vide quand une seule fenêtre est dispo
  /// (rendu sans en-tête de section).
  final String? label;

  /// Dates de début d'insertion valides (déjà filtrées par
  /// `validInsertionStartDates` côté caller).
  final List<DateTime> validStartDates;

  const InsertionWindow({
    required this.anchorSegmentIndex,
    required this.label,
    required this.validStartDates,
  });
}

/// Résultat du picker : la date de début ET le segment d'ancrage choisi.
typedef PickedInsertion = ({DateTime startDate, int anchorSegmentIndex});

/// Ouvre la sheet et retourne `(date, anchorIndex)`, ou `null` si
/// l'utilisateur a fermé sans choisir.
///
/// `windows` doit contenir au moins une fenêtre. Le rendu est
/// automatique :
/// - 1 fenêtre → liste plate sans en-tête.
/// - ≥2 fenêtres → sections avec labels.
Future<PickedInsertion?> openPickInsertionDateSheet(
  BuildContext context, {
  required String anchorCity,
  required String displayName,
  required List<InsertionSegmentSummary> insertedSegments,
  required List<InsertionWindow> windows,
}) {
  return showModalBottomSheet<PickedInsertion>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PickInsertionDateSheet(
      anchorCity: anchorCity,
      displayName: displayName,
      insertedSegments: insertedSegments,
      windows: windows,
    ),
  );
}

class _PickInsertionDateSheet extends StatelessWidget {
  final String anchorCity;
  final String displayName;
  final List<InsertionSegmentSummary> insertedSegments;
  final List<InsertionWindow> windows;

  const _PickInsertionDateSheet({
    required this.anchorCity,
    required this.displayName,
    required this.insertedSegments,
    required this.windows,
  });

  int get _insertionNights =>
      insertedSegments.fold<int>(0, (sum, s) => sum + s.nights);

  bool get _multiWindow => windows.length >= 2;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: mq.size.height * 0.75,
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
                _multiWindow
                    ? 'Plusieurs créneaux à $anchorCity sont compatibles. '
                        'Tes vols et hôtels datés ne bougeront pas.'
                    : 'Lunao découpera $anchorCity autour de $displayName. '
                        'Tes vols et hôtels datés ne bougeront pas.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _buildItems(context),
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

  List<Widget> _buildItems(BuildContext context) {
    final items = <Widget>[];
    for (var w = 0; w < windows.length; w++) {
      final window = windows[w];
      // En-tête de section (uniquement si ≥2 fenêtres et label présent).
      if (_multiWindow && (window.label?.isNotEmpty ?? false)) {
        if (w > 0) items.add(const SizedBox(height: 16));
        items.add(_SectionHeader(label: window.label!));
        items.add(const SizedBox(height: 8));
      }
      for (var i = 0; i < window.validStartDates.length; i++) {
        final start = window.validStartDates[i];
        final end = start.add(Duration(days: _insertionNights));
        items.add(_DateOption(
          start: start,
          endExclusive: end,
          breakdown: _formatBreakdown(insertedSegments),
          onTap: () => Navigator.of(context).pop((
            startDate: start,
            anchorSegmentIndex: window.anchorSegmentIndex,
          )),
        ));
        if (i < window.validStartDates.length - 1) {
          items.add(const SizedBox(height: 8));
        }
      }
    }
    return items;
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _DateOption extends StatelessWidget {
  final DateTime start;
  final DateTime endExclusive;

  /// "Rayong 1 nuit + Koh Samet 2 nuits" / "Krabi 3 nuits".
  final String breakdown;
  final VoidCallback onTap;

  const _DateOption({
    required this.start,
    required this.endExclusive,
    required this.breakdown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
                      '$breakdown · retour le '
                      '${_formatShortDate(endExclusive)}',
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

/// "Rayong 1 nuit + Koh Samet 2 nuits" pour multi-step,
/// "Krabi 3 nuits" pour single-step.
String _formatBreakdown(List<InsertionSegmentSummary> segments) {
  String label(int n) => n <= 1 ? '1 nuit' : '$n nuits';
  return segments.map((s) => '${s.city} ${label(s.nights)}').join(' + ');
}
