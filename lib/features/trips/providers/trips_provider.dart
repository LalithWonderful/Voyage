import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/core/providers/offline_provider.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Liste des voyages de l'utilisateur. Stratégie offline-first :
/// 1. Tente fetch Supabase. Si succès → écrit cache local, reset offline,
///    retourne fresh data.
/// 2. Si échec réseau → lit cache local. Si cache présent, signale offline
///    et retourne cached. Sinon relance l'erreur (UI affichera).
final tripsProvider = FutureProvider<List<Trip>>((ref) async {
  final client = ref.watch(supabaseProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];

  final cache = await ref.watch(localTripsCacheServiceProvider.future);

  try {
    final data = await client
        .from('trips')
        .select()
        .eq('user_id', user.id)
        .order('start_date', ascending: true);
    final rows = (data as List).whereType<Map<String, dynamic>>().toList();
    // Best-effort write : on ne bloque pas la réponse user si le cache
    // foire (improbable, juste un disk write).
    cache.writeTrips(rows);
    // Au succès, on reset l'état offline (l'user était peut-être en zone
    // blanche et a retrouvé le réseau, on rafraîchit le banner).
    ref.read(isOfflineProvider.notifier).state = false;
    return rows.map((e) => Trip.fromJson(e)).toList();
  } catch (e) {
    final cached = cache.readTrips();
    if (cached.isEmpty) {
      // Pas de cache → on remonte l'erreur, l'UI affichera "Erreur de
      // chargement" comme avant.
      rethrow;
    }
    developer.log('[trips] fetch failed, using cache (${cached.length} trips) : $e', name: 'cache');
    ref.read(isOfflineProvider.notifier).state = true;
    return cached;
  }
});

/// Trip individuel avec fallback cache. Lit depuis `tripsProvider` (qui a
/// déjà sa logique cache) au lieu de refaire un fetch séparé — évite les
/// doubles appels et les états désynchronisés entre la liste et le détail.
final tripByIdProvider = FutureProvider.family<Trip?, String>((ref, id) async {
  final trips = await ref.watch(tripsProvider.future);
  return trips.where((t) => t.id == id).firstOrNull;
});

/// Supprime un voyage avec cascade propre :
/// - Supprime les trajets (trip_transports)
/// - Supprime les activités (trip_activities)
/// - DÉTACHE les documents (trip_documents.trip_id := null) — les conserve dans le
///   wallet pour que l'utilisateur puisse les réutiliser sur un autre voyage
/// - Supprime enfin la ligne trips
///
/// Ordre important : on supprime d'abord les tables qui référencent trips pour éviter
/// tout blocage de FK, puis trips lui-même. L'appelant doit invalider les providers
/// pertinents après succès (tripsProvider, hasTripsProvider, documentsProvider).
Future<void> deleteTripCascade(SupabaseClient client, String tripId) async {
  await client.from('trip_transports').delete().eq('trip_id', tripId);
  await client.from('trip_activities').delete().eq('trip_id', tripId);
  await client.from('trip_documents').update({'trip_id': null}).eq('trip_id', tripId);
  await client.from('trips').delete().eq('id', tripId);
}
