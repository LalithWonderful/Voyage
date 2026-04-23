import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

const _coverEmojis = ['✈️', '🏝️', '🏔️', '🏙️', '🏞️', '🌴', '🛶', '🚐', '🎡', '🎿', '🗺️', '🌍'];

const _travelerTypes = [
  ('🚐', 'Road-trip'),
  ('✨', 'Grand luxe'),
  ('💰', 'Meilleur prix'),
  ('🎒', 'Backpack'),
  ('👨‍👩‍👧', 'En famille'),
  ('💼', 'Voyage pro'),
];

const _availableInterests = [
  ('🥾', 'Randonnée'), ('🛍️', 'Shopping'), ('🌙', 'Nightlife'),
  ('📸', 'Spots populaires'), ('🗺️', 'Hors circuit'), ('💡', 'Bons plans'),
  ('🧘', 'Wellness'), ('🎨', 'Esthétique'), ('🍽️', 'Gastronomie'),
  ('🏛️', 'Culture'), ('🏖️', 'Plage'), ('⛷️', 'Sports'),
  ('🐾', 'Nature'), ('🎭', 'Événements'),
];

Future<void> openTripEditSheet(BuildContext context, WidgetRef ref, {required Trip trip}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _TripEditSheet(trip: trip),
  );
}

class _TripEditSheet extends ConsumerStatefulWidget {
  final Trip trip;
  const _TripEditSheet({required this.trip});

  @override
  ConsumerState<_TripEditSheet> createState() => _TripEditSheetState();
}

class _TripEditSheetState extends ConsumerState<_TripEditSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _destCtrl;
  late DateTime _start;
  late DateTime _end;
  late String _emoji;
  late List<Traveler> _travelers;
  String? _travelerType;
  late Set<String> _interests;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.trip.title);
    _destCtrl = TextEditingController(text: widget.trip.destination);
    _start = widget.trip.startDate;
    _end = widget.trip.endDate;
    _emoji = widget.trip.coverEmoji;
    _travelers = [...widget.trip.travelers];
    _travelerType = widget.trip.travelerType;
    _interests = Set<String>.from(widget.trip.interests ?? const []);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _start : _end;
    final first = isStart ? DateTime(initial.year - 2) : _start;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(initial.year + 3),
      locale: const Locale('fr'),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
        if (_end.isBefore(picked)) _end = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _addTraveler() async {
    final result = await showDialog<Traveler>(
      context: context,
      builder: (_) => const _AddTravelerDialog(),
    );
    if (result != null) setState(() => _travelers.add(result));
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final dest = _destCtrl.text.trim();
    if (title.isEmpty || dest.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Titre et destination sont requis.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(supabaseProvider).from('trips').update({
        'title': title,
        'destination': dest,
        'start_date': _start.toIso8601String().split('T').first,
        'end_date': _end.toIso8601String().split('T').first,
        'cover_emoji': _emoji,
        'travelers': _travelers.map((t) => t.toJson()).toList(),
        'traveler_type': _travelerType,
        'interests': _interests.toList(),
      }).eq('id', widget.trip.id);
      ref.invalidate(tripsProvider);
      ref.invalidate(tripByIdProvider(widget.trip.id));
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
        height: MediaQuery.of(context).size.height * 0.9,
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
                    child: Text('Modifier le voyage', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
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
                    Text('EMOJI', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _coverEmojis.map((e) {
                        final sel = _emoji == e;
                        return GestureDetector(
                          onTap: () => setState(() => _emoji = e),
                          child: Container(
                            width: 42, height: 42,
                            decoration: BoxDecoration(
                              color: sel ? AppColors.primaryLight : AppColors.surface,
                              border: Border.all(color: sel ? AppColors.primary : AppColors.border, width: sel ? 2 : 1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(child: Text(e, style: const TextStyle(fontSize: 22))),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    Text('TITRE *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextField(controller: _titleCtrl),
                    const SizedBox(height: 14),

                    Text('DESTINATION *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextField(controller: _destCtrl),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(child: _dateField(label: 'Départ', value: _fmtDate(_start), onTap: () => _pickDate(isStart: true))),
                        const SizedBox(width: 10),
                        Expanded(child: _dateField(label: 'Retour', value: _fmtDate(_end), onTap: () => _pickDate(isStart: false))),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Style de ce voyage (optionnel, override du profil global)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('STYLE DE CE VOYAGE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        if (_travelerType != null || _interests.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() {
                              _travelerType = null;
                              _interests.clear();
                            }),
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                            child: Text('Utiliser mon profil', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _travelerType == null && _interests.isEmpty
                          ? 'Vide = l\'IA utilise ton profil voyageur global.'
                          : 'Préférences spécifiques à ce voyage, utilisées par l\'IA.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                    ),
                    const SizedBox(height: 10),

                    Text('Type de voyageur', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _travelerTypes.map((t) {
                        final sel = _travelerType == t.$2;
                        return GestureDetector(
                          onTap: () => setState(() => _travelerType = sel ? null : t.$2),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: sel ? AppColors.primary : AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('${t.$1} ${t.$2}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : AppColors.primary)),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),

                    Text('Centres d\'intérêt', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _availableInterests.map((t) {
                        final sel = _interests.contains(t.$2);
                        return GestureDetector(
                          onTap: () => setState(() => sel ? _interests.remove(t.$2) : _interests.add(t.$2)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: sel ? AppColors.primary : AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('${t.$1} ${t.$2}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : AppColors.primary)),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 18),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('VOYAGEURS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        Text('${_travelers.length} ${_travelers.length > 1 ? 'personnes' : 'personne'}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._travelers.asMap().entries.map((e) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: Text('${e.value.name} · ${e.value.age} ans', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                          IconButton(
                            onPressed: () => setState(() => _travelers.removeAt(e.key)),
                            icon: const Icon(Icons.close, size: 18),
                            color: AppColors.textSecondary,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          ),
                        ],
                      ),
                    )),
                    OutlinedButton.icon(
                      onPressed: _addTraveler,
                      icon: const Icon(Icons.person_add_alt_1, size: 18),
                      label: const Text('Ajouter un voyageur'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 44),
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
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
                      : const Text('Enregistrer'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateField({required String label, required String value, required VoidCallback onTap}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
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
                Icon(Icons.calendar_today, size: 16, color: AppColors.textSecondary),
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

class _AddTravelerDialog extends StatefulWidget {
  const _AddTravelerDialog();

  @override
  State<_AddTravelerDialog> createState() => _AddTravelerDialogState();
}

class _AddTravelerDialogState extends State<_AddTravelerDialog> {
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final age = int.tryParse(_ageCtrl.text.trim());
    if (name.isEmpty) {
      setState(() => _error = 'Le prénom est requis.');
      return;
    }
    if (age == null || age < 0 || age > 120) {
      setState(() => _error = 'Âge invalide.');
      return;
    }
    Navigator.of(context).pop(Traveler(name: name, age: age));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ajouter un voyageur'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Prénom'), textCapitalization: TextCapitalization.words, autofocus: true),
          const SizedBox(height: 12),
          TextField(
            controller: _ageCtrl,
            decoration: InputDecoration(labelText: 'Âge', suffixText: 'ans', errorText: _error),
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        ElevatedButton(onPressed: _submit, child: const Text('Ajouter')),
      ],
    );
  }
}
