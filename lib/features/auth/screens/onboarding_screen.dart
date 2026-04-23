import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _page = 0;

  final _slides = [
    ('✈️', 'Voyagez sans stress', 'Dites-nous qui vous êtes, Voyage construit un planning sur mesure. Simple et personnel.'),
    ('🗺️', 'Planning intelligent', 'Activités, horaires, suggestions personnalisées selon votre profil voyageur.'),
    ('💼', 'Tout en un endroit', 'Billets, documents, carte et assistant — tout ce qu\'il vous faut pour voyager serein.'),
  ];

  @override
  Widget build(BuildContext context) {
    final slide = _slides[_page];
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: () => context.go('/login'),
                  child: Text('Passer', style: TextStyle(color: AppColors.textSecondary)),
                ),
              ),
              const Spacer(),
              Container(
                width: 140,
                height: 140,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFFDBEAFE), Color(0xFFFCE7F3)],
                  ),
                ),
                child: Center(child: Text(slide.$1, style: const TextStyle(fontSize: 70))),
              ),
              const SizedBox(height: 32),
              Text(slide.$2, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textPrimary), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(slide.$3, style: TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.5), textAlign: TextAlign.center),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                )),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  if (_page < 2) {
                    setState(() => _page++);
                  } else {
                    context.go('/login');
                  }
                },
                child: Text(_page < 2 ? 'Suivant →' : 'Commencer →'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
