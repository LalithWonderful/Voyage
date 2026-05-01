import 'dart:developer' as developer;
import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Synchronise les étapes d'un voyage à partir de ses docs Vol/Train.
///
/// Logique :
/// - Lit les docs Vol/Train du voyage, triés par date.
/// - Pour chaque endpoint (`from`/`to`), garde l'étape candidate seulement
///   si son `*_country_code` == `trip.destinationCountryCode` (= dans le pays
///   du voyage). Si voyage sans `destination_country_code`, fallback "to
///   only" (comportement minimaliste safe).
/// - Dédoublonne avec les segments existants (city normalisé OU haversine
///   < 30 km) pour ne jamais ajouter une étape déjà présente.
/// - Calcule `days` pour les nouvelles étapes : durée jusqu'au prochain vol
///   `from_city == city` (= le voyageur quitte cette ville), ou `trip.endDate`
///   si pas de prochain.
/// - **Conservatif** : ne touche JAMAIS aux segments existants (ni city, ni
///   days, ni position). On ajoute uniquement.
/// - Insère chaque nouvelle étape à sa position chronologique correcte
///   (basé sur la date du vol vs la date calculée des segments existants).
///
/// Retourne la liste des étapes nouvellement ajoutées (pour snackbar info).
class TripSegmentSyncService {
  final SupabaseClient _client;

  TripSegmentSyncService(this._client);

  /// Synchronise les étapes du voyage depuis les docs Vol/Train. Idempotent :
  /// peut être appelé après chaque save de doc, n'ajoute que les manquantes.
  ///
  /// Retourne la liste des étapes nouvellement créées (pour communication UX).
  /// Liste vide = pas de changement.
  Future<List<TripSegment>> syncFromTransportDocs(String tripId) async {
    final tripRow = await _client.from('trips').select().eq('id', tripId).maybeSingle();
    if (tripRow == null) return const [];
    final trip = Trip.fromJson(tripRow);

    final docsRows = await _client
        .from('trip_documents')
        .select()
        .eq('trip_id', tripId)
        .inFilter('category', [DocumentCategory.flight, DocumentCategory.train]);
    final docs = (docsRows as List)
        .map((d) => TripDocument.fromJson(d as Map<String, dynamic>))
        .toList();

    if (docs.isEmpty) return const [];

    // Tri par date du vol/train. Les docs sans date sont skippés.
    final sortedDocs = docs.where((d) {
      final raw = d.metadata['date'] as String?;
      return raw != null && raw.isNotEmpty && DateTime.tryParse(raw) != null;
    }).toList()
      ..sort((a, b) {
        final ad = DateTime.parse(a.metadata['date'] as String);
        final bd = DateTime.parse(b.metadata['date'] as String);
        return ad.compareTo(bd);
      });

    if (sortedDocs.isEmpty) return const [];

    final tripCountry = trip.destinationCountryCode?.trim().toLowerCase();
    final hasTripCountry = tripCountry != null && tripCountry.isNotEmpty;

    // 1. Extraction des candidats (city + lat/lng + date) depuis chaque endpoint.
    final candidates = <_StepCandidate>[];
    for (final doc in sortedDocs) {
      final docDate = DateTime.parse(doc.metadata['date'] as String);
      _appendCandidates(
        meta: doc.metadata,
        prefix: 'from',
        date: docDate,
        candidates: candidates,
        tripCountry: tripCountry,
        hasTripCountry: hasTripCountry,
        keepWhenNoTripCountry: false, // sans country trip, ne pas extraire from
      );
      _appendCandidates(
        meta: doc.metadata,
        prefix: 'to',
        date: docDate,
        candidates: candidates,
        tripCountry: tripCountry,
        hasTripCountry: hasTripCountry,
        keepWhenNoTripCountry: true, // fallback : extraire to seul si pas de country trip
      );
    }
    if (candidates.isEmpty) return const [];

    // 2. Dédoublonnage avec segments existants + entre candidats. Pour chaque
    // ville on ne garde que la PREMIÈRE occurrence (atDate la plus tôt) — c'est
    // la date où le voyageur arrive pour la 1re fois.
    final existing = trip.itinerarySegments;
    final addedNorms = <String>{};
    final newCandidates = <_StepCandidate>[];
    for (final c in candidates) {
      final norm = _normalize(c.city);
      if (addedNorms.contains(norm)) continue;
      if (_existsInSegments(existing, c)) continue;
      newCandidates.add(c);
      addedNorms.add(norm);
    }
    if (newCandidates.isEmpty) return const [];

    // 3. Calcul des `days` pour chaque nouveau candidat. Heuristique :
    // jusqu'au prochain doc dont `from_city == candidate.city` (= départ vers
    // ailleurs), sinon jusqu'à trip.endDate.
    final newSegments = <TripSegment>[];
    for (final c in newCandidates) {
      final days = _computeDays(c, sortedDocs, trip);
      newSegments.add(TripSegment(
        city: c.city,
        days: days,
        country: trip.destinationCountryName,
        latitude: c.lat,
        longitude: c.lng,
      ));
    }

    // 4. Insertion chronologique. On a les segments existants dans `existing`
    // avec des dates calculées via segmentStart(i). Les nouveaux ont des dates
    // candidates `c.atDate`. On combine, on trie par date, on reconstruit.
    final positioned = <_Positioned>[];
    for (var i = 0; i < existing.length; i++) {
      positioned.add(_Positioned(segment: existing[i], date: trip.segmentStart(i), isNew: false));
    }
    for (var i = 0; i < newSegments.length; i++) {
      positioned.add(_Positioned(segment: newSegments[i], date: newCandidates[i].atDate, isNew: true));
    }
    positioned.sort((a, b) => a.date.compareTo(b.date));
    final mergedSegments = positioned.map((p) => p.segment).toList();

    // 5. Persist. Update uniquement le champ itinerary_segments pour ne pas
    // toucher au reste du trip.
    try {
      await _client.from('trips').update({
        'itinerary_segments': mergedSegments.map((s) => s.toJson()).toList(),
      }).eq('id', tripId);
      developer.log(
        '[trip-segment-sync] +${newSegments.length} étape(s) ajoutée(s) au voyage $tripId : ${newSegments.map((s) => s.city).join(', ')}',
        name: 'trip-segment-sync',
      );
    } catch (e) {
      developer.log('[trip-segment-sync] update error : $e', name: 'trip-segment-sync');
      return const [];
    }

    return newSegments;
  }

  /// Extrait un candidat depuis le metadata du doc pour un endpoint donné
  /// (`from` ou `to`). Le candidat est ajouté à `candidates` seulement si
  /// les conditions de pays sont satisfaites.
  void _appendCandidates({
    required Map<String, dynamic> meta,
    required String prefix,
    required DateTime date,
    required List<_StepCandidate> candidates,
    required String? tripCountry,
    required bool hasTripCountry,
    required bool keepWhenNoTripCountry,
  }) {
    final city = (meta['${prefix}_city'] as String?)?.trim();
    if (city == null || city.isEmpty) return;
    final country = (meta['${prefix}_country_code'] as String?)?.trim().toLowerCase();
    final lat = (meta['${prefix}_latitude'] as num?)?.toDouble();
    final lng = (meta['${prefix}_longitude'] as num?)?.toDouble();

    if (hasTripCountry) {
      // Avec destination_country_code : on n'ajoute que si l'endpoint y est.
      if (country == null || country.isEmpty) return;
      if (country != tripCountry) return;
    } else {
      // Sans country trip : fallback "to only" (cf. doc de classe).
      if (!keepWhenNoTripCountry) return;
    }

    candidates.add(_StepCandidate(city: city, lat: lat, lng: lng, atDate: date));
  }

  /// Normalise un nom de ville pour le matching de dédoublonnage.
  /// "Chiang  Mai" et "chiang mai" et " Chiang Mai " matchent.
  String _normalize(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// True si le candidat correspond déjà à un segment existant. Match par
  /// nom normalisé OU par distance haversine < 30 km (gère les cas de
  /// graphies différentes : "Pékin" vs "Beijing", "Munich" vs "München").
  bool _existsInSegments(List<TripSegment> segments, _StepCandidate c) {
    final norm = _normalize(c.city);
    for (final s in segments) {
      if (_normalize(s.city) == norm) return true;
      if (c.lat != null && c.lng != null && s.latitude != null && s.longitude != null) {
        if (_haversineKm(c.lat!, c.lng!, s.latitude!, s.longitude!) < 30) {
          return true;
        }
      }
    }
    return false;
  }

  /// Calcule le nombre de jours pour la nouvelle étape : durée entre la date
  /// d'arrivée (vol vers cette ville) et la date de départ (vol depuis cette
  /// ville). Si pas de vol de départ, jusqu'à `trip.endDate`. Clamp [1, durée
  /// du voyage].
  int _computeDays(_StepCandidate c, List<TripDocument> sortedDocs, Trip trip) {
    final norm = _normalize(c.city);
    DateTime? departureDate;
    for (final doc in sortedDocs) {
      final fromCity = (doc.metadata['from_city'] as String?)?.trim() ?? '';
      if (fromCity.isEmpty) continue;
      if (_normalize(fromCity) != norm) continue;
      final raw = doc.metadata['date'] as String?;
      if (raw == null) continue;
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      if (d.isAfter(c.atDate)) {
        departureDate = d;
        break;
      }
    }
    final endRef = departureDate ?? trip.endDate;
    final endDay = DateTime(endRef.year, endRef.month, endRef.day);
    final startDay = DateTime(c.atDate.year, c.atDate.month, c.atDate.day);
    final diff = endDay.difference(startDay).inDays;
    return diff.clamp(1, trip.durationDays);
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    double toRad(double deg) => deg * (pi / 180);
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthKm * c;
  }
}

class _StepCandidate {
  final String city;
  final double? lat;
  final double? lng;
  final DateTime atDate;
  _StepCandidate({required this.city, this.lat, this.lng, required this.atDate});
}

class _Positioned {
  final TripSegment segment;
  final DateTime date;
  final bool isNew;
  _Positioned({required this.segment, required this.date, required this.isNew});
}
