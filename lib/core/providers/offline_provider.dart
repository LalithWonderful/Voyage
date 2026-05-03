import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyage/core/services/local_trips_cache_service.dart';

/// Instance partagée de `SharedPreferences`. Init asynchrone au 1er watch,
/// ensuite sync via `valueOrNull`.
final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) async {
  return SharedPreferences.getInstance();
});

/// Service de cache local lecture-seule pour les trips/activities/docs.
/// Initialisé après `sharedPreferencesProvider`. Voir
/// `LocalTripsCacheService` pour la stratégie offline-first.
final localTripsCacheServiceProvider = FutureProvider<LocalTripsCacheService>((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  return LocalTripsCacheService(prefs);
});

/// État global "hors ligne" — vrai dès qu'un provider Trip a fallback sur
/// le cache local au cours de la session courante. Réinitialisé au prochain
/// fetch Supabase réussi. Sert à afficher une icône `cloud_off` discrète
/// dans l'AppBar et à désactiver les actions d'écriture qui n'ont pas de
/// sens hors ligne.
///
/// Stocké comme StateProvider plutôt que dérivé d'une exception — un seul
/// fallback détecté en lecture suffit à signaler l'état, pas besoin de
/// recompter à chaque rebuild.
final isOfflineProvider = StateProvider<bool>((ref) => false);
