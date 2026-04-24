import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Affiche la sheet de confirmation des nuits quand plusieurs hébergements se chevauchent.
/// Persiste le choix de l'utilisateur dans `trip_documents.metadata.sleep_nights`
/// pour chaque hôtel affecté. Retourne `true` si l'utilisateur a confirmé, `false` sinon.
Future<bool> openOverlapNightsSheet(
  BuildContext context,
  WidgetRef ref, {
  required String tripId,
  required List<DateTime> overlapNights,
  required List<TripDocument> allHotels,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _OverlapNightsSheet(
      tripId: tripId,
      overlapNights: overlapNights,
      allHotels: allHotels,
    ),
  );
  return confirmed ?? false;
}

class _OverlapNightsSheet extends ConsumerStatefulWidget {
  final String tripId;
  final List<DateTime> overlapNights;
  final List<TripDocument> allHotels;
  const _OverlapNightsSheet({
    required this.tripId,
    required this.overlapNights,
    required this.allHotels,
  });

  @override
  ConsumerState<_OverlapNightsSheet> createState() => _OverlapNightsSheetState();
}

class _OverlapNightsSheetState extends ConsumerState<_OverlapNightsSheet> {
  static const _months = [
    'janv.', 'févr.', 'mars', 'avril', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];

  final Map<String, String> _choices = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Pré-remplit chaque nuit avec le résultat de l'heuristique actuelle
    // (Option B : stay le plus court gagne, ou choix Option C existant).
    for (final night in widget.overlapNights) {
      final iso = isoDay(night);
      final suggested = hotelForDay(widget.allHotels, night);
      if (suggested != null) _choices[iso] = suggested.id;
    }
  }

  String _formatNight(DateTime night) {
    final next = night.add(const Duration(days: 1));
    return 'Nuit du ${night.day} ${_months[night.month - 1]} au ${next.day} ${_months[next.month - 1]}';
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      final client = ref.read(supabaseProvider);
      final overlapIsos = widget.overlapNights.map(isoDay).toSet();

      // IDs des hôtels affectés par au moins une des nuits de chevauchement.
      final affectedIds = <String>{};
      for (final night in widget.overlapNights) {
        for (final h in hotelsSleepingOnNight(widget.allHotels, night)) {
          affectedIds.add(h.id);
        }
      }

      for (final hId in affectedIds) {
        // Relit le metadata frais directement depuis la DB juste avant d'écrire : évite
        // d'écraser accidentellement les modifs récentes (adresse, check_in...) si
        // widget.allHotels était un poil stale entre l'ouverture de la sheet et la confirmation.
        final freshRow = await client
            .from('trip_documents')
            .select('metadata')
            .eq('id', hId)
            .maybeSingle();
        final currentMetadata = Map<String, dynamic>.from(
          (freshRow?['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        final storedNights = (currentMetadata['sleep_nights'] as List?)
                ?.whereType<String>()
                .toSet() ??
            <String>{};
        final newSet = storedNights.toSet();
        // On rewrite uniquement les nuits posées dans cette sheet (préserve les décisions
        // antérieures sur d'autres chevauchements si un 3e hôtel existait).
        newSet.removeAll(overlapIsos);
        for (final entry in _choices.entries) {
          if (entry.value == hId) newSet.add(entry.key);
        }
        currentMetadata['sleep_nights'] = (newSet.toList()..sort());
        await client.from('trip_documents').update({'metadata': currentMetadata}).eq('id', hId);
      }

      ref.invalidate(tripDocumentsProvider(widget.tripId));
      ref.invalidate(tripHotelsProvider(widget.tripId));
      ref.invalidate(tripActivitiesProvider(widget.tripId));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.75;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🏨 Chevauchement d\'hébergements',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  'Précise où tu dors chaque nuit de chevauchement.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: widget.overlapNights.length,
              separatorBuilder: (_, _) => const SizedBox(height: 16),
              itemBuilder: (_, index) {
                final night = widget.overlapNights[index];
                final iso = isoDay(night);
                final candidates = hotelsSleepingOnNight(widget.allHotels, night);
                final selected = _choices[iso];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatNight(night),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    ...candidates.map((h) {
                      final isSelected = selected == h.id;
                      return InkWell(
                        onTap: _saving ? null : () => setState(() => _choices[iso] = h.id),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primaryLight : AppColors.surface,
                            border: Border.all(
                              color: isSelected ? AppColors.primary : AppColors.border,
                              width: isSelected ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                size: 18,
                                color: isSelected ? AppColors.primary : AppColors.textSecondary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  h.name.isNotEmpty ? h.name : 'Hébergement sans nom',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Plus tard'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _confirm,
                    child: _saving
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('Confirmer'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
