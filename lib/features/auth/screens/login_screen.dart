import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      await ref.read(authServiceProvider).signIn(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
      if (mounted) context.go('/trips');
    } catch (e) {
      setState(() => _error = 'Email ou mot de passe incorrect.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final controller = TextEditingController(text: _emailCtrl.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Mot de passe oublié'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Entre ton email. On t\'envoie un lien pour définir un nouveau mot de passe.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'vous@email.com'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(authServiceProvider).sendPasswordReset(email);
      messenger.showSnackBar(
        const SnackBar(content: Text('Email envoyé — vérifie ta boîte de réception (et les spams).')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
      );
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
              Center(child: Text('Voyage', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: AppColors.textPrimary))),
              const SizedBox(height: 40),
              _label('Email'),
              TextField(controller: _emailCtrl, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'vous@email.com')),
              const SizedBox(height: 14),
              _label('Mot de passe'),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  hintText: '••••••••',
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: _forgotPassword, child: Text('Mot de passe oublié ?', style: TextStyle(color: AppColors.primary, fontSize: 12))),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _loading ? null : _signIn,
                child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Se connecter'),
              ),
              Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Row(children: [
                  Expanded(child: Divider()),
                  Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('ou', style: TextStyle(color: AppColors.textSecondary, fontSize: 12))),
                  Expanded(child: Divider()),
                ]),
              ),
              const SizedBox(height: 24),
              Center(
                child: GestureDetector(
                  onTap: () => context.go('/register'),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: 'Pas encore de compte ? ', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    TextSpan(text: 'S\'inscrire', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
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
