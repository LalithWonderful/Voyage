import 'dart:developer' as developer;
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Coordonnées (lat, lng) du centre de recherche Places pour un jour donné.
class DayCenter {
  final double latitude;
  final double longitude;
  /// Source du centre, pour debug : 'hotel', 'segment_city', 'destination'.
  final String source;
  const DayCenter({required this.latitude, required this.longitude, required this.source});
}

/// Calcule le point d'ancrage (lat, lng) à utiliser pour les recherches Places
/// du jour donné. Priorité :
/// 1. **Hôtel actif** : si un document hôtel couvre le jour (check-in ≤ day ≤ check-out),
///    on géocode son adresse. C'est le centre le plus pertinent — le voyageur va
///    rayonner depuis là.
/// 2. **Ville du segment** : si le voyage a des étapes structurées et que le jour
///    tombe dans une étape, on géocode `segment.city`.
/// 3. **Destination du voyage** : fallback générique.
///
/// Renvoie `null` si rien n'a pu être géocodé (clé API manquante, lieu inconnu).
Future<DayCenter?> centerForDay({
  required Trip trip,
  required DateTime day,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
}) async {
  // 1. Hôtel actif — uniquement s'il couvre VRAIMENT ce jour.
  // `hotelForDay` retourne `hotels.first` en fallback rétrocompat même quand
  // aucun hôtel ne couvre, ce qui pour un voyage multi-villes (ex: Nancy/Épinal,
  // hôtel Nancy seul) ancrerait J7-J8 Épinal sur l'hôtel Nancy. On force donc
  // une vérification explicite via `sleepNightsRange` pour basculer au
  // fallback "ville du segment" quand pas de couverture réelle.
  final hotel = hotelForDay(hotels, day);
  final dayKey = DateTime(day.year, day.month, day.day);
  final hotelCovers = hotel != null &&
      sleepNightsRange(hotel).any((n) => n.isAtSameMomentAs(dayKey));
  if (hotel != null && hotelCovers) {
    final addr = (hotel.metadata['address'] as String?)?.trim();
    final query = (addr != null && addr.isNotEmpty) ? addr : hotel.name;
    if (query.isNotEmpty) {
      final geo = await geocoder.geocode(query);
      if (geo != null) {
        developer.log(
          'Centre du jour ${_iso(day)} = hôtel "$query" → ${geo.latitude},${geo.longitude}',
          name: 'day_center',
        );
        return DayCenter(latitude: geo.latitude, longitude: geo.longitude, source: 'hotel');
      }
    }
  }

  // 2. Ville du segment (multi-villes) — `cityForDay` retourne la destination
  // si pas de segment ne couvre ce jour.
  final segmentCity = trip.cityForDay(day);
  if (segmentCity.isNotEmpty && segmentCity != trip.destination) {
    final geo = await geocoder.geocode(segmentCity);
    if (geo != null) {
      developer.log(
        'Centre du jour ${_iso(day)} = ville segment "$segmentCity" → ${geo.latitude},${geo.longitude}',
        name: 'day_center',
      );
      return DayCenter(latitude: geo.latitude, longitude: geo.longitude, source: 'segment_city');
    }
  }

  // 3. Destination du voyage
  if (trip.destination.isNotEmpty) {
    final geo = await geocoder.geocode(trip.destination);
    if (geo != null) {
      developer.log(
        'Centre du jour ${_iso(day)} = destination "${trip.destination}" → ${geo.latitude},${geo.longitude}',
        name: 'day_center',
      );
      return DayCenter(latitude: geo.latitude, longitude: geo.longitude, source: 'destination');
    }
  }

  developer.log('Aucun centre géocodable pour le jour ${_iso(day)}', name: 'day_center');
  return null;
}

String _iso(DateTime d) => d.toIso8601String().split('T').first;
