import 'package:flutter_riverpod/flutter_riverpod.dart';
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
