import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

final tripsProvider = FutureProvider<List<Trip>>((ref) async {
  final client = ref.watch(supabaseProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];

  final data = await client
      .from('trips')
      .select()
      .eq('user_id', user.id)
      .order('start_date', ascending: true);

  return (data as List).map((e) => Trip.fromJson(e)).toList();
});

final tripByIdProvider = FutureProvider.family<Trip?, String>((ref, id) async {
  final client = ref.watch(supabaseProvider);
  final data = await client.from('trips').select().eq('id', id).maybeSingle();
  if (data == null) return null;
  return Trip.fromJson(data);
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
