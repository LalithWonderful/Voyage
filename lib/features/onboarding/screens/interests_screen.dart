import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

class InterestsScreen extends ConsumerStatefulWidget {
  const InterestsScreen({super.key});

  @override
  ConsumerState<InterestsScreen> createState() => _InterestsScreenState();
}

class _InterestsScreenState extends ConsumerState<InterestsScreen> {
  final Set<int> _selected = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final existing = await ref.read(userInterestsProvider.future);
    if (!mounted || existing.isEmpty) return;
    setState(() {
      for (final key in existing) {
        final i = _interests.indexWhere((t) => t.$2 == key);
        if (i >= 0) _selected.add(i);
      }
    });
  }

  Future<void> _continue() async {
    if (_selected.isEmpty) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;

      await client.from('user_interests').delete().eq('user_id', userId);
      final inserted = await client.from('user_interests').insert(
        _selected.map((i) => {'user_id': userId, 'interest_key': _interests[i].$2}).toList(),
      ).select();

      if ((inserted as List).isEmpty) {
        throw Exception('Aucun intérêt inséré (vérifie les policies RLS INSERT sur user_interests).');
      }
      ref.invalidate(userInterestsProvider);

      // Si l'utilisateur a déjà des voyages, on saute l'écran "où tu pars"
      final hasTrips = await ref.read(hasTripsProvider.future);
      if (!mounted) return;
      context.go(hasTrips ? '/trips' : '/onboarding/destination');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur de sauvegarde : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  final _interests = [
    ('🥾', 'Randonnée'), ('🛍️', 'Shopping'), ('🌙', 'Nightlife'),
    ('📸', 'Spots populaires'), ('🗺️', 'Hors circuit'), ('💡', 'Bons plans'),
    ('🧘', 'Wellness'), ('🎨', 'Esthétique'), ('🍽️', 'Gastronomie'),
    ('🏛️', 'Culture'), ('🏖️', 'Plage'), ('⛷️', 'Sports'),
    ('🐾', 'Nature'), ('🎭', 'Événements'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildProgress(1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Vos centres\nd\'intérêt', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    const SizedBox(height: 6),
                    Text('Sélectionnez tout ce qui vous fait vibrer. ${_selected.length} sélectionnés', style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
                    const SizedBox(height: 16),
                    GridView.count(
                      crossAxisCount: 2,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.5,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: List.generate(_interests.length, (i) {
                        final sel = _selected.contains(i);
                        return GestureDetector(
                          onTap: () => setState(() => sel ? _selected.remove(i) : _selected.add(i)),
                          child: Container(
                            decoration: BoxDecoration(
                              color: sel ? AppColors.primaryLight : AppColors.surface,
                              border: Border.all(color: sel ? AppColors.primary : AppColors.border, width: sel ? 1.5 : 1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(_interests[i].$1, style: const TextStyle(fontSize: 24)),
                                const SizedBox(height: 4),
                                Text(_interests[i].$2, style: TextStyle(fontSize: 12, fontWeight: sel ? FontWeight.w600 : FontWeight.w500, color: sel ? AppColors.primary : AppColors.textPrimary)),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: (_loading || _selected.isEmpty) ? null : _continue,
                      child: _loading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text('Continuer → (${_selected.length} sélectionnés)'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress(int step) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: List.generate(3, (i) => Expanded(
            child: Container(
              height: 3,
              margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
              decoration: BoxDecoration(
                color: i < step ? AppColors.success : (i == step ? AppColors.primary : AppColors.border),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ))),
          const SizedBox(height: 8),
          Row(children: [
            GestureDetector(onTap: () => context.go('/onboarding/traveler-type'), child: const Text('←', style: TextStyle(fontSize: 20))),
            const SizedBox(width: 10),
            Text('Étape ${step + 1} / 3', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const Spacer(),
            TextButton(
              onPressed: () => context.go('/trips'),
              child: Text('Passer', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ),
          ]),
        ],
      ),
    );
  }
}
