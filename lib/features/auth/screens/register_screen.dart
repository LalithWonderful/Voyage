import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (_nameCtrl.text.trim().isEmpty || _emailCtrl.text.trim().isEmpty || _passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Veuillez remplir tous les champs.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await ref.read(authServiceProvider).signUp(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        fullName: _nameCtrl.text.trim(),
      );
      if (mounted) context.go('/onboarding/traveler-type');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              const Center(child: Text('✈️', style: TextStyle(fontSize: 48))),
              Center(child: Text('Créer un compte', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textPrimary))),
              const SizedBox(height: 8),
              Center(child: Text('Commencez à planifier vos aventures', style: TextStyle(fontSize: 13, color: AppColors.textSecondary))),
              const SizedBox(height: 36),
              _label('Nom complet'),
              TextField(controller: _nameCtrl, decoration: const InputDecoration(hintText: 'Jean Dupont')),
              const SizedBox(height: 14),
              _label('Email'),
              TextField(controller: _emailCtrl, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'vous@email.com')),
              const SizedBox(height: 14),
              _label('Mot de passe'),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  hintText: '8 caractères minimum',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    tooltip: _obscurePassword ? 'Afficher' : 'Masquer',
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: AppColors.error, fontSize: 13)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _signUp,
                child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Créer mon compte'),
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () => context.go('/login'),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: 'Déjà un compte ? ', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    TextSpan(text: 'Se connecter', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                  ])),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
  );
}
