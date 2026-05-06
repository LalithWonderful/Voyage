import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/assistant/providers/assistant_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

/// Chip horizontale en haut de l'écran Assistant : montre le voyage que
/// Lunao utilise pour répondre, ouvre une bottom sheet pour en changer.
class TripContextChip extends ConsumerWidget {
  const TripContextChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripsAsync = ref.watch(tripsProvider);
    final selectedId = ref.watch(selectedAssistantTripIdProvider);

    return tripsAsync.when(
      loading: () => const SizedBox(
        height: 40,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, _) => _buildChip(
        context,
        label: '🌍 Choisir un voyage',
        onTap: () {},
      ),
      data: (trips) {
        final selected = selectedId == null
            ? null
            : trips.where((t) => t.id == selectedId).firstOrNull;
        final label = selected == null
            ? '🌍 Choisir un voyage'
            : '🗺️ Voyage : ${selected.destination}';
        return _buildChip(
          context,
          label: label,
          onTap: () => _openSheet(context, ref, trips, selectedId),
        );
      },
    );
  }

  Widget _buildChip(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryDark,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: AppColors.primaryDark),
          ],
        ),
      ),
    );
  }

  void _openSheet(
    BuildContext context,
    WidgetRef ref,
    List<Trip> trips,
    String? selectedId,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return _TripSelectionSheet(
          trips: trips,
          initialSelectedId: selectedId,
          onConfirm: (newId) {
            ref.read(selectedAssistantTripIdProvider.notifier).state = newId;
            Navigator.of(sheetCtx).pop();
          },
        );
      },
    );
  }
}

/// Sheet stateful : la sélection se fait au tap (highlight visuel) mais
/// n'est appliquée qu'au clic sur "Continuer". Ça rassure l'utilisateur
/// qu'il peut explorer les options sans engagement immédiat.
class _TripSelectionSheet extends StatefulWidget {
  final List<Trip> trips;
  final String? initialSelectedId;
  final ValueChanged<String?> onConfirm;

  const _TripSelectionSheet({
    required this.trips,
    required this.initialSelectedId,
    required this.onConfirm,
  });

  @override
  State<_TripSelectionSheet> createState() => _TripSelectionSheetState();
}

class _TripSelectionSheetState extends State<_TripSelectionSheet> {
  late String? _pendingId;

  @override
  void initState() {
    super.initState();
    _pendingId = widget.initialSelectedId;
  }

  bool get _hasChanged => _pendingId != widget.initialSelectedId;

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Sur quel voyage veux-tu que je t'aide ?",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Je m'appuierai sur ce voyage pour te répondre plus précisément.",
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  _SheetTile(
                    emoji: '🌍',
                    title: 'Aucun voyage',
                    subtitle: 'Préparer une destination, comparer, organiser une idée',
                    selected: _pendingId == null,
                    onTap: () => setState(() => _pendingId = null),
                  ),
                  if (widget.trips.isNotEmpty) const Divider(height: 1),
                  for (final trip in widget.trips)
                    _SheetTile(
                      emoji: trip.coverEmoji,
                      title: trip.destination,
                      subtitle: _tripSubtitle(trip),
                      selected: _pendingId == trip.id,
                      onTap: () => setState(() => _pendingId = trip.id),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _hasChanged
                      ? () => widget.onConfirm(_pendingId)
                      : () => Navigator.of(context).pop(),
                  child: Text(
                    _hasChanged ? 'Continuer' : 'Fermer',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _tripSubtitle(Trip t) {
    if (t.hasExactDates) {
      return 'Du ${_fmtDate(t.startDate)} au ${_fmtDate(t.endDate)}';
    }
    if (t.hasRecommendedPeriod) return 'Recommandé : ${t.targetPeriodLabel ?? '—'}';
    if (t.hasUnspecifiedPeriod) return 'Dates à préciser';
    return t.targetPeriodLabel ?? '${t.durationDays} jours';
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

class _SheetTile extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _SheetTile({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 20, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}
