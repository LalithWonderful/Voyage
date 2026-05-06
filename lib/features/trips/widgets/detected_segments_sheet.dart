import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/trips/services/trip_segment_sync_service.dart';

/// Sheet de validation des étapes détectées dans les vols/trains du wallet.
/// Affichée après le save d'un doc Vol/Train quand le service a trouvé au
/// moins un candidat (ville pas encore dans `itinerary_segments`).
///
/// L'utilisateur coche les villes qu'il veut ajouter au circuit. Les villes
/// du même pays que la destination sont cochées par défaut (haute confiance) ;
/// les extensions hors pays sont décochées par défaut. L'utilisateur curate
/// pour éviter d'auto-ajouter une éventuelle hallucination d'extraction.
class DetectedSegmentsSheet extends StatefulWidget {
  final List<SegmentCandidate> candidates;
  final String tripDestination;

  const DetectedSegmentsSheet({
    super.key,
    required this.candidates,
    required this.tripDestination,
  });

  /// Helper pour ouvrir la sheet. Retourne la liste des candidats sélectionnés
  /// (vide si l'utilisateur a annulé).
  static Future<List<SegmentCandidate>> show(
    BuildContext context, {
    required List<SegmentCandidate> candidates,
    required String tripDestination,
  }) async {
    final result = await showModalBottomSheet<List<SegmentCandidate>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DetectedSegmentsSheet(
        candidates: candidates,
        tripDestination: tripDestination,
      ),
    );
    return result ?? const [];
  }

  @override
  State<DetectedSegmentsSheet> createState() => _DetectedSegmentsSheetState();
}

class _DetectedSegmentsSheetState extends State<DetectedSegmentsSheet> {
  late final Map<int, bool> _checked;

  @override
  void initState() {
    super.initState();
    _checked = {
      for (var i = 0; i < widget.candidates.length; i++)
        i: widget.candidates[i].suggestedByDefault,
    };
  }

  int get _selectedCount => _checked.values.where((v) => v).length;

  void _toggleAll(bool checkAll) {
    setState(() {
      for (final k in _checked.keys) {
        _checked[k] = checkAll;
      }
    });
  }

  List<SegmentCandidate> _selectedCandidates() {
    final out = <SegmentCandidate>[];
    for (var i = 0; i < widget.candidates.length; i++) {
      if (_checked[i] == true) out.add(widget.candidates[i]);
    }
    // Tri par date pour respecter la chronologie du voyage.
    out.sort((a, b) => a.atDate.compareTo(b.atDate));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final allChecked = _checked.values.every((v) => v);
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "✨ Étapes détectées dans tes vols",
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Coche les villes que tu veux ajouter au circuit "
                    "${widget.tripDestination}. Tu peux toujours en ajouter "
                    "d'autres manuellement plus tard.",
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Toggle "tout cocher / tout décocher"
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _toggleAll(!allChecked),
                  icon: Icon(
                    allChecked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 16,
                  ),
                  label: Text(
                    allChecked ? 'Tout décocher' : 'Tout cocher',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
            Container(height: 1, color: AppColors.border),
            // Liste des candidats
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.candidates.length,
                itemBuilder: (ctx, i) {
                  final c = widget.candidates[i];
                  final isChecked = _checked[i] ?? false;
                  return _CandidateRow(
                    candidate: c,
                    checked: isChecked,
                    onChanged: (v) => setState(() => _checked[i] = v ?? false),
                  );
                },
              ),
            ),
            Container(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Annuler'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: _selectedCount == 0
                          ? null
                          : () => Navigator.of(context).pop(_selectedCandidates()),
                      child: Text(
                        _selectedCount == 0
                            ? 'Aucune sélection'
                            : 'Ajouter $_selectedCount étape${_selectedCount > 1 ? 's' : ''}',
                        style: const TextStyle(
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

class _CandidateRow extends StatelessWidget {
  final SegmentCandidate candidate;
  final bool checked;
  final ValueChanged<bool?> onChanged;

  const _CandidateRow({
    required this.candidate,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final country = candidate.country ?? candidate.countryCode?.toUpperCase();
    final dateLabel = _fmtDate(candidate.atDate);
    return InkWell(
      onTap: () => onChanged(!checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        candidate.city,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (country != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: candidate.suggestedByDefault
                                ? AppColors.primaryLight
                                : AppColors.accentLight.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            country,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: candidate.suggestedByDefault
                                  ? AppColors.primaryDark
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$dateLabel · ${candidate.sourceDocName}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!candidate.suggestedByDefault) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Hors pays principal — extension du circuit',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.accent,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}
