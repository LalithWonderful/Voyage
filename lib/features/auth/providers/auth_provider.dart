import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseProvider).auth.onAuthStateChange;
});

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(supabaseProvider).auth.currentUser;
});

class AuthService {
  final SupabaseClient _client;
  AuthService(this._client);

  Future<AuthResponse> signUp({required String email, required String password, required String fullName}) async {
    return _client.auth.signUp(
      email: email,
      password: password,
      data: {'full_name': fullName},
    );
  }

  Future<AuthResponse> signIn({required String email, required String password}) async {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Envoie un email de reset password à l'utilisateur.
  /// Le lien reçu par email redirige vers `voyage://reset-password?code=...`
  /// → géré par DeepLinkService → ouvre ResetPasswordScreen dans l'app.
  Future<void> sendPasswordReset(String email) async {
    await _client.auth.resetPasswordForEmail(
      email,
      redirectTo: 'voyage://reset-password',
    );
  }

  Future<bool> hasCompletedOnboarding() async {
    final user = _client.auth.currentUser;
    if (user == null) return false;
    final data = await _client
        .from('user_profiles')
        .select('onboarding_completed_at')
        .eq('id', user.id)
        .maybeSingle();
    return data?['onboarding_completed_at'] != null;
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(ref.watch(supabaseProvider));
});

// Profil utilisateur (age, traveler_type, onboarding_completed_at, etc.)
final userProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final client = ref.watch(supabaseProvider);
  final user = client.auth.currentUser;
  if (user == null) return null;
  return await client.from('user_profiles').select().eq('id', user.id).maybeSingle();
});

// Intérêts de l'utilisateur (liste de clés)
final userInterestsProvider = FutureProvider<List<String>>((ref) async {
  final client = ref.watch(supabaseProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final data = await client.from('user_interests').select('interest_key').eq('user_id', user.id);
  return (data as List).map((e) => e['interest_key'] as String).toList();
});

// true si l'utilisateur a au moins un voyage
final hasTripsProvider = FutureProvider<bool>((ref) async {
  final client = ref.watch(supabaseProvider);
  final user = client.auth.currentUser;
  if (user == null) return false;
  final data = await client.from('trips').select('id').eq('user_id', user.id).limit(1);
  return (data as List).isNotEmpty;
});

/// Mode thème effectif (lit `user_profiles.theme_mode`, fallback "system").
final themeModeProvider = Provider<ThemeMode>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  final raw = profile?['theme_mode'] as String?;
  switch (raw) {
    case 'light': return ThemeMode.light;
    case 'dark': return ThemeMode.dark;
    default: return ThemeMode.system;
  }
});
