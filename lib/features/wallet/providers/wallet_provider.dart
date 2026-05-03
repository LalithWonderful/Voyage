import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/providers/offline_provider.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Tous les documents de l'utilisateur (Wallet global) avec fallback cache.
/// Cf. `LocalTripsCacheService` pour la stratégie offline-first.
final documentsProvider = FutureProvider<List<TripDocument>>((ref) async {
  final client = ref.watch(supabaseProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final cache = await ref.watch(localTripsCacheServiceProvider.future);
  try {
    final data = await client
        .from('trip_documents')
        .select()
        .eq('user_id', user.id)
        .order('created_at', ascending: false);
    final rows = (data as List).whereType<Map<String, dynamic>>().toList();
    cache.writeAllDocuments(rows);
    ref.read(isOfflineProvider.notifier).state = false;
    return rows.map((e) => TripDocument.fromJson(e)).toList();
  } catch (e) {
    ref.read(isOfflineProvider.notifier).state = true;
    return cache.readAllDocuments();
  }
});

/// Documents d'un voyage avec fallback cache. Comportement offline : si le
/// cache est vide pour ce voyage spécifique (jamais consulté avant la
/// coupure réseau), retourne `[]` silencieusement — pas d'erreur écran.
final tripDocumentsProvider = FutureProvider.family<List<TripDocument>, String>((ref, tripId) async {
  final client = ref.watch(supabaseProvider);
  final cache = await ref.watch(localTripsCacheServiceProvider.future);
  try {
    final data = await client
        .from('trip_documents')
        .select()
        .eq('trip_id', tripId)
        .order('created_at', ascending: false);
    final rows = (data as List).whereType<Map<String, dynamic>>().toList();
    cache.writeDocuments(tripId, rows);
    ref.read(isOfflineProvider.notifier).state = false;
    return rows.map((e) => TripDocument.fromJson(e)).toList();
  } catch (e) {
    ref.read(isOfflineProvider.notifier).state = true;
    return cache.readDocuments(tripId);
  }
});

DateTime? _hotelCheckIn(TripDocument d) {
  final v = d.metadata['check_in'];
  return v is String ? DateTime.tryParse(v) : null;
}

DateTime? _hotelCheckOut(TripDocument d) {
  final v = d.metadata['check_out'];
  return v is String ? DateTime.tryParse(v) : null;
}

/// Tous les hébergements d'un voyage, triés par date de check-in croissante
/// (les docs sans date finissent en dernier, dans l'ordre de création).
final tripHotelsProvider = FutureProvider.family<List<TripDocument>, String>((ref, tripId) async {
  final docs = await ref.watch(tripDocumentsProvider(tripId).future);
  final hotels = docs.where((d) => d.category == DocumentCategory.hotel).toList();
  hotels.sort((a, b) {
    final ai = _hotelCheckIn(a);
    final bi = _hotelCheckIn(b);
    if (ai == null && bi == null) return 0;
    if (ai == null) return 1;
    if (bi == null) return -1;
    return ai.compareTo(bi);
  });
  return hotels;
});

/// Hôtel principal (shim pour les appelants historiques qui n'ont pas besoin de gérer
/// le multi-hébergement). Retourne le premier par ordre de check-in.
final tripHotelProvider = FutureProvider.family<TripDocument?, String>((ref, tripId) async {
  final hotels = await ref.watch(tripHotelsProvider(tripId).future);
  return hotels.isEmpty ? null : hotels.first;
});

/// Nuits où le voyageur dort dans cet hôtel : [check_in, check_in+1, ..., check_out-1].
/// La journée de check-out N'EST PAS une nuit (on part le matin).
List<DateTime> sleepNightsRange(TripDocument h) => _sleepNightsRange(h);

/// Format ISO 'YYYY-MM-DD' d'un jour (utilisé comme clé dans `metadata.sleep_nights`).
String isoDay(DateTime d) => _isoDay(d);

/// Liste des hôtels qui couvrent la nuit du [day] (check-in ≤ day < check-out).
List<TripDocument> hotelsSleepingOnNight(List<TripDocument> hotels, DateTime day) {
  final d = DateTime(day.year, day.month, day.day);
  return hotels
      .where((h) => _sleepNightsRange(h).any((n) => n.isAtSameMomentAs(d)))
      .toList();
}

/// Set des nuits explicitement confirmées pour un hôtel (iso strings).
Set<String> confirmedSleepNights(TripDocument h) => _confirmedSleepNights(h);

List<DateTime> _sleepNightsRange(TripDocument h) {
  final ci = _hotelCheckIn(h);
  final co = _hotelCheckOut(h);
  if (ci == null || co == null) return const [];
  final start = DateTime(ci.year, ci.month, ci.day);
  final end = DateTime(co.year, co.month, co.day);
  final result = <DateTime>[];
  for (var d = start; d.isBefore(end); d = d.add(const Duration(days: 1))) {
    result.add(d);
  }
  return result;
}

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Calcule les nuits qui chevauchent entre [hotel] et les autres hôtels du voyage.
/// Retourne la liste triée des dates (jour de check-in de la nuit, pas de check-out).
List<DateTime> overlappingNights(TripDocument hotel, List<TripDocument> allHotels) {
  final mine = _sleepNightsRange(hotel).toSet();
  final overlap = <DateTime>{};
  for (final other in allHotels) {
    if (other.id == hotel.id) continue;
    final otherNights = _sleepNightsRange(other).toSet();
    overlap.addAll(mine.intersection(otherNights));
  }
  final sorted = overlap.toList()..sort();
  return sorted;
}

/// Nuits explicitement confirmées par l'utilisateur pour cet hôtel (Option C).
/// Stockées dans `metadata.sleep_nights` comme liste de strings ISO 'YYYY-MM-DD'.
Set<String> _confirmedSleepNights(TripDocument h) {
  final raw = h.metadata['sleep_nights'];
  if (raw is! List) return const {};
  return raw.whereType<String>().toSet();
}

/// Retourne l'hôtel où le voyageur dort la NUIT du [day].
/// Logique :
/// - Si un seul hôtel couvre la nuit → c'est lui.
/// - Si plusieurs hôtels couvrent la même nuit (chevauchement) :
///   1. **Option C** : le premier dont `metadata.sleep_nights` contient explicitement ce jour gagne.
///   2. **Option B (fallback)** : le séjour le plus court gagne (heuristique "ça doit être
///      l'hébergement secondaire réservé pendant un séjour principal plus long").
/// - Si aucun hôtel ne couvre → fallback : le premier de la liste (rétrocompatibilité).
TripDocument? hotelForDay(List<TripDocument> hotels, DateTime day) {
  if (hotels.isEmpty) return null;
  final d = DateTime(day.year, day.month, day.day);
  final iso = _isoDay(d);

  final candidates = <TripDocument>[];
  for (final h in hotels) {
    final nights = _sleepNightsRange(h);
    if (nights.any((n) => n.isAtSameMomentAs(d))) {
      candidates.add(h);
    }
  }
  if (candidates.isEmpty) return hotels.first;
  if (candidates.length == 1) return candidates.first;

  // Option C : choix explicite de l'utilisateur
  for (final h in candidates) {
    if (_confirmedSleepNights(h).contains(iso)) return h;
  }

  // Option B : heuristique — le séjour le plus court prend la nuit
  candidates.sort((a, b) => _sleepNightsRange(a).length.compareTo(_sleepNightsRange(b).length));
  return candidates.first;
}
