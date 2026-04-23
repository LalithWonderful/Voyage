import 'dart:async';
import 'dart:developer' as developer;
import 'package:app_links/app_links.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Écoute les deep links `voyage://` et déclenche les actions correspondantes.
///
/// Routes gérées :
/// - `voyage://reset-password?code=...` → établit la session de récupération
///   via `exchangeCodeForSession`, puis navigue vers `/reset-password`.
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final _links = AppLinks();
  StreamSubscription<Uri>? _sub;
  bool _initialized = false;

  Future<void> init({required GoRouter router, required SupabaseClient client}) async {
    if (_initialized) return;
    _initialized = true;

    // Lien initial (cold start depuis un lien cliqué alors que l'app n'était pas lancée)
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) {
        await _handle(initial, router: router, client: client);
      }
    } catch (e) {
      developer.log('getInitialLink error: $e', name: 'deeplink');
    }

    // Liens reçus pendant que l'app tourne
    _sub = _links.uriLinkStream.listen(
      (uri) => _handle(uri, router: router, client: client),
      onError: (Object e) => developer.log('uriLinkStream error: $e', name: 'deeplink'),
    );
  }

  Future<void> _handle(Uri uri, {required GoRouter router, required SupabaseClient client}) async {
    developer.log('Deep link reçu : $uri', name: 'deeplink');
    if (uri.scheme != 'voyage') return;

    // Supabase envoie le lien sous la forme voyage://reset-password?code=<PKCE>
    // Selon la config, le chemin peut être dans `host` ou `path`. On accepte les deux.
    final target = uri.host.isNotEmpty ? uri.host : uri.path.replaceFirst('/', '');

    if (target == 'reset-password') {
      final params = uri.queryParameters;
      try {
        // Cas 1 — flow OTP direct (recommandé, configuré via custom email template) :
        // voyage://reset-password?token_hash=<HASH>&type=recovery
        // L'email pointe directement sur le scheme, pas de browser hop.
        if (params['token_hash'] != null && params['type'] != null) {
          await client.auth.verifyOTP(
            type: _parseOtpType(params['type']!),
            tokenHash: params['token_hash']!,
          );
          router.go('/reset-password');
          return;
        }
        // Cas 2 — flow PKCE classique (passe par le verify endpoint Supabase) :
        // voyage://reset-password?code=<PKCE_CODE>
        // ⚠️ Chrome bloque souvent ce redirect serveur — le cas 1 est préférable.
        if (params['code'] != null) {
          await client.auth.exchangeCodeForSession(params['code']!);
          router.go('/reset-password');
          return;
        }
        developer.log('Aucun code/token_hash dans $uri', name: 'deeplink');
        router.go('/login');
      } catch (e) {
        developer.log('Auth recovery error: $e', name: 'deeplink');
        router.go('/login');
      }
    }
  }

  OtpType _parseOtpType(String raw) {
    switch (raw) {
      case 'recovery': return OtpType.recovery;
      case 'signup': return OtpType.signup;
      case 'invite': return OtpType.invite;
      case 'magiclink': return OtpType.magiclink;
      case 'email_change': return OtpType.emailChange;
      default: return OtpType.recovery;
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _initialized = false;
  }
}
