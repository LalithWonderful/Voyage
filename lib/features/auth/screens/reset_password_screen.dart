import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

/// Écran de définition d'un nouveau mot de passe après clic sur le lien email.
/// Attend que la session de récupération soit déjà ouverte (via deep link +
/// exchangeCodeForSession côté listener). Si pas de session active, redirige vers /login.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePwd = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);

    final pwd = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (pwd.length < 8) {
      setState(() => _error = 'Le mot de passe doit faire au moins 8 caractères.');
      return;
    }
    if (pwd != confirm) {
      setState(() => _error = 'Les deux mots de passe ne correspondent pas.');
      return;
    }

    setState(() { _loading = true; _error = null; });
    try {
      final client = ref.read(supabaseProvider);
      // La session de récupération a déjà été établie par le deep link handler.
      if (client.auth.currentSession == null) {
        setState(() => _error = 'Session expirée. Redemande un email de réinitialisation.');
        return;
      }
      await client.auth.updateUser(UserAttributes(password: pwd));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mot de passe mis à jour.')),
      );
      // Déconnecte pour forcer une reconnexion propre avec le nouveau mdp
      await client.auth.signOut();
      if (!mounted) return;
      context.go('/login');
    } catch (e) {
      setState(() => _error = 'Erreur : $e');
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
              const Center(child: Text('🔐', style: TextStyle(fontSize: 48))),
              Center(child: Text('Nouveau mot de passe', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary))),
              const SizedBox(height: 8),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Choisis un nouveau mot de passe. Il sera actif dès que tu te reconnectes.',
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _label('Nouveau mot de passe'),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscurePwd,
                decoration: InputDecoration(
                  hintText: '8 caractères minimum',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePwd ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscurePwd = !_obscurePwd),
                    tooltip: _obscurePwd ? 'Afficher' : 'Masquer',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _label('Confirmer le mot de passe'),
              TextField(
                controller: _confirmCtrl,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  hintText: 'Retape le même',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                    tooltip: _obscureConfirm ? 'Afficher' : 'Masquer',
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: AppColors.error, fontSize: 13)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Mettre à jour'),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _loading ? null : () => context.go('/login'),
                  child: Text('Annuler', style: TextStyle(color: AppColors.textSecondary)),
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
