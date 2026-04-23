import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';

const _availableTags = [
  'Repas', 'Visite', 'Nightlife', 'Transport', 'Hébergement',
  'Nature', 'Shopping', 'Culture', 'Wellness', 'Sport', 'Activité',
];

Future<void> openActivityCreateSheet(
  BuildContext context,
  WidgetRef ref, {
  required String tripId,
  required DateTime defaultDay,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _ActivityCreateSheet(tripId: tripId, defaultDay: defaultDay),
  );
}

class _ActivityCreateSheet extends ConsumerStatefulWidget {
  final String tripId;
  final DateTime defaultDay;
  const _ActivityCreateSheet({required this.tripId, required this.defaultDay});

  @override
  ConsumerState<_ActivityCreateSheet> createState() => _ActivityCreateSheetState();
}

class _ActivityCreateSheetState extends ConsumerState<_ActivityCreateSheet> {
  final _titleCtrl = TextEditingController();
  final _detailCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _durationCtrl = TextEditingController(text: '60');
  late DateTime _dayDate;
  String _startTime = '12:00';
  String _tag = 'Activité';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _dayDate = widget.defaultDay;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _detailCtrl.dispose();
    _priceCtrl.dispose();
    _durationCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dayDate,
      firstDate: DateTime(_dayDate.year - 1),
      lastDate: DateTime(_dayDate.year + 3),
      locale: const Locale('fr'),
    );
    if (picked != null) setState(() => _dayDate = picked);
  }

  Future<void> _pickTime() async {
    final parts = _startTime.split(':');
    TimeOfDay initial = const TimeOfDay(hour: 12, minute: 0);
    if (parts.length == 2) {
      final h = int.tryParse(parts[0]) ?? 12;
      final m = int.tryParse(parts[1]) ?? 0;
      initial = TimeOfDay(hour: h, minute: m);
    }
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() => _startTime = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
    }
  }

  /// Déclenche en arrière-plan les fetch Places + Gemini pour préremplir
  /// le cache DB. La detail sheet sera instantanée la 1ère fois qu'on l'ouvre.
  Future<void> _prefetchEnrichment(TripActivity activity) async {
    try {
      // Places (photos/rating/price_level) — upsert auto dans places_cache et trip_activities
      unawaited(ref.read(activityPlaceInfoProvider(activity).future));
      // Description Gemini — upsert auto dans trip_activities.description
      unawaited(ref.read(activityDescriptionProvider(activity).future));
    } catch (_) {
      // Silencieux : si ça échoue, la detail sheet fera les appels à l'ouverture (comportement actuel)
    }
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le titre est requis.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final inserted = await ref.read(supabaseProvider).from('trip_activities').insert({
        'trip_id': widget.tripId,
        'day_date': _dayDate.toIso8601String().split('T').first,
        'start_time': _startTime,
        'title': title,
        'detail': _detailCtrl.text.trim().isEmpty ? null : _detailCtrl.text.trim(),
        'tag': _tag,
        'duration_minutes': int.tryParse(_durationCtrl.text.trim()),
        'price_estimate': _priceCtrl.text.trim().isEmpty ? null : _priceCtrl.text.trim(),
        'suggested': false,
      }).select();

      if ((inserted as List).isEmpty) {
        throw Exception('Aucune activité insérée (vérifie les policies RLS sur trip_activities).');
      }

      // Prefetch en arrière-plan : Places (photos/rating/price_level) + description Gemini.
      // Ainsi, la 1ère ouverture de la detail sheet sera instantanée (données cached DB).
      final activity = TripActivity.fromJson(inserted.first);
      unawaited(_prefetchEnrichment(activity));

      ref.invalidate(tripActivitiesProvider(widget.tripId));
      if (mounted) Navigator.of(context).pop();
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

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Nouvelle activité', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: AppColors.textSecondary,
                    tooltip: 'Fermer',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TITRE *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _titleCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(hintText: 'Ex : Déjeuner au Time Out Market'),
                    ),
                    const SizedBox(height: 14),

                    Text('DÉTAIL / ADRESSE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextField(controller: _detailCtrl, minLines: 1, maxLines: 3),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(child: _tappableField(
                          label: 'DATE',
                          value: _fmtDate(_dayDate),
                          icon: Icons.calendar_today,
                          onTap: _pickDate,
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: _tappableField(
                          label: 'HEURE',
                          value: _startTime,
                          icon: Icons.access_time,
                          onTap: _pickTime,
                        )),
                      ],
                    ),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('DURÉE (MIN)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _durationCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              decoration: const InputDecoration(hintText: 'Ex : 90'),
                            ),
                          ],
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PRIX', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _priceCtrl,
                              decoration: const InputDecoration(hintText: '~15€'),
                            ),
                          ],
                        )),
                      ],
                    ),
                    const SizedBox(height: 14),

                    Text('CATÉGORIE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _availableTags.map((t) {
                        final sel = _tag == t;
                        return GestureDetector(
                          onTap: () => setState(() => _tag = t),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: sel ? AppColors.primary : AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : AppColors.primary)),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
              child: SafeArea(
                top: false,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Ajouter l\'activité'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tappableField({required String label, required String value, required IconData icon, required VoidCallback onTap}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
