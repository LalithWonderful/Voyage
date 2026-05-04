import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/data/destination_seasonality.dart';

/// Résultat retourné par la sheet "Quand partir au {pays} ?".
/// `month` (1-12) et `year` représentent le mois recommandé que l'utilisateur
/// a choisi. La sheet retourne null si l'utilisateur ferme sans choisir.
class SeasonalityChoice {
  final int month;
  final int year;
  const SeasonalityChoice({required this.month, required this.year});

  /// Format YYYY-MM pour stockage dans `trip.target_period`.
  String get targetPeriod =>
      '$year-${month.toString().padLeft(2, '0')}';
}

/// Bottom sheet d'aide au choix de la période, alimentée par la table
/// statique `destination_seasonality.dart`. Pas d'appel IA.
///
/// Structure :
/// - Header : "Quand partir au {pays} ?"
/// - Section "Meilleures périodes" : mois `bestMonths` regroupés en plages
///   lisibles ("Mai à septembre", "Décembre à mars")
/// - Section "Bons mois aussi" (si `okMonths`) : mois corrects
/// - Section "À savoir" : `notes` (1 phrase chacune, bullet)
/// - Section "Événements" (si `events`) : nom + mois + note
/// - CTAs :
///   - Primary "Choisir [premier bestMonth futur]" → retourne SeasonalityChoice
///   - Secondary "Voir un autre mois" → ouvre le picker mois standard
///     en propageant `picked-other-month` dans le pop (le caller bascule
///     sur le mois picker classique)
Future<SeasonalityChoice?> showSeasonalitySheet(
  BuildContext context, {
  required DestinationSeasonality seasonality,
}) {
  return showModalBottomSheet<SeasonalityChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (sheetCtx) => _SeasonalityContent(seasonality: seasonality),
  );
}

class _SeasonalityContent extends StatelessWidget {
  final DestinationSeasonality seasonality;
  const _SeasonalityContent({required this.seasonality});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final recommendedMonth = seasonality.defaultRecommendedMonth(now);
    final recommendedYear = seasonality.defaultRecommendedYear(now);
    final recommendedLabel =
        '${_monthName(recommendedMonth)} $recommendedYear';

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollCtrl) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Quand partir ?',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5),
                ),
                const SizedBox(height: 4),
                Text(
                  seasonality.displayName,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    controller: scrollCtrl,
                    padding: EdgeInsets.zero,
                    children: [
                      _SectionTitle('Meilleures périodes'),
                      ...formatMonthRanges(seasonality.bestMonths).map(
                        (range) => _Bullet(emoji: '🟢', text: range, fontWeight: FontWeight.w600),
                      ),
                      if (seasonality.okMonths.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _SectionTitle('Bons mois aussi'),
                        ...formatMonthRanges(seasonality.okMonths).map(
                          (range) => _Bullet(emoji: '🟡', text: range),
                        ),
                      ],
                      if (seasonality.avoidMonths.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _SectionTitle('À éviter si possible'),
                        ...formatMonthRanges(seasonality.avoidMonths).map(
                          (range) => _Bullet(emoji: '🔴', text: range),
                        ),
                      ],
                      if (seasonality.notes.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SectionTitle('À savoir'),
                        ...seasonality.notes.map(
                          (n) => _Bullet(emoji: '💡', text: n),
                        ),
                      ],
                      if (seasonality.events.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SectionTitle('Événements notables'),
                        ...seasonality.events.map(
                          (e) => _Bullet(
                            emoji: '🎉',
                            text: '${e.name} — ${formatMonthRanges(e.months).join(", ")}\n${e.note}',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop(SeasonalityChoice(month: recommendedMonth, year: recommendedYear));
                  },
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text('Choisir $recommendedLabel', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('Voir un autre mois', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String emoji;
  final String text;
  final FontWeight fontWeight;
  const _Bullet({required this.emoji, required this.text, this.fontWeight = FontWeight.w400});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.4, fontWeight: fontWeight),
            ),
          ),
        ],
      ),
    );
  }
}

/// Formate une liste de mois (1-12) en plages contiguës lisibles.
/// Ex: [5,6,7,8,9] → ["Mai à septembre"]. [11,12,1,2] → ["Novembre à février"]
/// (boucle gérée). [3] → ["Mars"]. [3,5] → ["Mars", "Mai"] (non contigus).
List<String> formatMonthRanges(List<int> months) {
  if (months.isEmpty) return const [];
  final sorted = [...months]..sort();

  // Détection du "wrap" décembre→janvier : si 12 et 1 sont présents, on
  // réordonne pour que la plage commence après le trou (ex: [11,12,1,2] →
  // affichée comme "Novembre à février").
  final hasWrap = sorted.contains(12) && sorted.contains(1);
  List<int> ordered;
  if (hasWrap) {
    // Trouve le 1er trou : commencer après ce trou
    int gapStart = -1;
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] - sorted[i - 1] > 1) { gapStart = i; break; }
    }
    if (gapStart > 0) {
      ordered = [...sorted.sublist(gapStart), ...sorted.sublist(0, gapStart)];
    } else {
      ordered = sorted;
    }
  } else {
    ordered = sorted;
  }

  final ranges = <String>[];
  int? rangeStart;
  int? rangeEnd;
  for (final m in ordered) {
    if (rangeStart == null) {
      rangeStart = m; rangeEnd = m;
    } else {
      // Contiguïté : m == rangeEnd + 1 (modulo 12 pour le wrap)
      final expectedNext = (rangeEnd! % 12) + 1;
      if (m == expectedNext) {
        rangeEnd = m;
      } else {
        ranges.add(_formatRange(rangeStart, rangeEnd));
        rangeStart = m; rangeEnd = m;
      }
    }
  }
  if (rangeStart != null) {
    ranges.add(_formatRange(rangeStart, rangeEnd!));
  }
  return ranges;
}

String _formatRange(int start, int end) {
  if (start == end) return _monthName(start);
  return '${_monthName(start)} à ${_monthName(end).toLowerCase()}';
}

String _monthName(int month) {
  const names = [
    'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
    'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre',
  ];
  return names[month - 1];
}
