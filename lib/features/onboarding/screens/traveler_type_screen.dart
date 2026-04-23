import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

class TravelerTypeScreen extends ConsumerStatefulWidget {
  const TravelerTypeScreen({super.key});

  @override
  ConsumerState<TravelerTypeScreen> createState() => _TravelerTypeScreenState();
}

class _TravelerTypeScreenState extends ConsumerState<TravelerTypeScreen> {
  int _selected = 0;
  final _ageCtrl = TextEditingController();
  bool _loading = false;
  String? _ageError;

  final _types = [
    ('🚐', 'Road-trip', 'La liberté sur la route, les arrêts improvisés', [Color(0xFFFEF3C7), Color(0xFFFDE68A)]),
    ('✨', 'Grand luxe', 'Palaces, expériences rares, service au top', [Color(0xFFEDE9FE), Color(0xFFDDD6FE)]),
    ('💰', 'Meilleur prix', 'Voyager malin, faire durer le budget', [Color(0xFFD1FAE5), Color(0xFFA7F3D0)]),
    ('🎒', 'Backpack', 'Aventure sac au dos, hostels, rencontres', [Color(0xFFFEE2E2), Color(0xFFFECACA)]),
    ('👨‍👩‍👧', 'En famille', 'Adapté aux enfants, rythme tranquille', [Color(0xFFDBEAFE), Color(0xFFBFDBFE)]),
    ('💼', 'Voyage pro', 'Efficace, proche du centre, wifi & calme', [Color(0xFFFCE7F3), Color(0xFFFBCFE8)]),
  ];

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final profile = await ref.read(userProfileProvider.future);
    if (profile == null || !mounted) return;
    final age = profile['age'];
    final type = profile['traveler_type'] as String?;
    setState(() {
      if (age != null) _ageCtrl.text = age.toString();
      if (type != null) {
        final i = _types.indexWhere((t) => t.$2 == type);
        if (i >= 0) _selected = i;
      }
    });
  }

  @override
  void dispose() {
    _ageCtrl.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final age = int.tryParse(_ageCtrl.text.trim());
    if (age == null || age < 10 || age > 120) {
      setState(() => _ageError = 'Veuillez entrer un âge valide.');
      return;
    }
    setState(() { _loading = true; _ageError = null; });

    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;
      final result = await client.from('user_profiles').update({
        'age': age,
        'traveler_type': _types[_selected].$2,
      }).eq('id', userId).select();

      if ((result as List).isEmpty) {
        throw Exception('Aucune ligne mise à jour (vérifie les policies RLS UPDATE sur user_profiles).');
      }
      ref.invalidate(userProfileProvider);
      if (mounted) context.go('/onboarding/interests');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildProgress(0),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Quel voyageur\nêtes-vous ?', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    const SizedBox(height: 6),
                    Text('Choisissez le style qui vous ressemble le plus.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
                    const SizedBox(height: 20),

                    // Champ âge
                    Text('VOTRE ÂGE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _ageCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                      decoration: InputDecoration(
                        hintText: 'Ex : 28',
                        suffixText: 'ans',
                        errorText: _ageError,
                      ),
                    ),
                    const SizedBox(height: 20),

                    Text('VOTRE STYLE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 10),
                    ...List.generate(_types.length, (i) => _TravelerCard(
                      emoji: _types[i].$1,
                      name: _types[i].$2,
                      tagline: _types[i].$3,
                      colors: _types[i].$4,
                      selected: _selected == i,
                      onTap: () => setState(() => _selected = i),
                    )),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loading ? null : _continue,
                      child: _loading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Continuer →'),
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
                color: i <= step ? AppColors.primary : AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ))),
          const SizedBox(height: 8),
          Row(children: [
            GestureDetector(onTap: () => context.go('/login'), child: const Text('←', style: TextStyle(fontSize: 20))),
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

class _TravelerCard extends StatelessWidget {
  final String emoji, name, tagline;
  final List<Color> colors;
  final bool selected;
  final VoidCallback onTap;

  const _TravelerCard({required this.emoji, required this.name, required this.tagline, required this.colors, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), gradient: LinearGradient(colors: colors)),
              child: Center(child: Text(emoji, style: const TextStyle(fontSize: 24))),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(tagline, style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4)),
              ],
            )),
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.primary : Colors.transparent,
                border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: 2),
              ),
              child: selected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
            ),
          ],
        ),
      ),
    );
  }
}
