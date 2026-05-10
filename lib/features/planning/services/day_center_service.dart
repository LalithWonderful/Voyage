import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:voyage/features/planning/data/segment_city_canonicals.dart';
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
  // V2 (2026-05-08) : on passe `itineraryCity = trip.cityForDay(day)` pour
  // que l'inférence par itinéraire (Option D) désambiguise les overlaps
  // long-stay (apparts Bangkok 47j) vs hôtel local (Phú Quốc 5j).
  // V6 (Lalith bug fix 2026-05-10) — l'Option D dans `hotelForDay` ne
  // fire QUE si plusieurs candidats overlappent le jour. Pour un trip
  // avec UNE SEULE base longue durée (Bangna 22/06–06/08) + side trips
  // sans hôtel local (Rayong/Koh Samet), `hotelForDay` retournait la
  // base parce qu'il n'y a qu'un candidat → `hotelCovers=true` →
  // search center = Bangkok. Bug : les activités du 29 juin (segment
  // Rayong) tombent toutes en banlieue de Bangkok.
  // Fix : si la ville du segment ≠ ville de l'hôtel candidat, on
  // considère l'hôtel comme une « base off-trip » et on saute au
  // niveau 2 (segment city). Ne se déclenche QUE pour les hôtels
  // bases longue durée où segment.city diverge.
  final segmentCity = trip.cityForDay(day);
  final hotel =
      hotelForDay(hotels, day, itineraryCity: segmentCity);
  final dayKey = DateTime(day.year, day.month, day.day);
  final hotelCovers = hotel != null &&
      sleepNightsRange(hotel).any((n) => n.isAtSameMomentAs(dayKey));
  final hotelMatchesSegment = hotel != null &&
      segmentCity.isNotEmpty &&
      hotelMatchesCity(hotel, segmentCity);
  if (hotel != null && hotelCovers && hotelMatchesSegment) {
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
  } else if (hotel != null && hotelCovers && !hotelMatchesSegment) {
    developer.log(
      'Centre du jour ${_iso(day)} : hôtel "${hotel.name}" couvre la nuit '
      'mais ville segment "$segmentCity" diffère — fallback ville segment '
      '(side trip off-base, cf. bug fix 2026-05-10).',
      name: 'day_center',
    );
  }

  // 2. Ville du segment (multi-villes) — `cityForDay` retourne la destination
  // si pas de segment ne couvre ce jour. Réutilise la variable
  // `segmentCity` calculée plus haut (V6 bug fix).
  //
  // V6.3 (bug fix 2026-05-10) — désambiguïsation des villes courtes /
  // ambiguës (« Koh Samet » → île OU district de Rayong), on enrichit
  // la query avec le pays du segment quand disponible, ET on passe
  // `regionHint` ISO 2 au geocoder. Le bug observé : "Koh Samet" seul
  // remontait des coords proches du continent Rayong → activités du
  // 30/06 et 01/07 cherchées en mer mais avec radius débordant sur le
  // continent → résultats Rayong au lieu de l'île.
  if (segmentCity.isNotEmpty && segmentCity != trip.destination) {
    final segment = trip.segmentForDay(day);
    final segCountry = segment?.country?.trim() ?? '';
    // V8.18 (Lalith 2026-05-10 — Q1D segment city resolution) —
    // canonical aliases pour les villes ambiguës (« Hoi An » résout
    // sur Hoi An An Giang au lieu de Hội An Quảng Nam, « Koh Samet »
    // peut tomber sur Rayong continent, etc.). Le canonical définit :
    // - une query enrichie province + country pour le geocoder.
    // - des coords expectedLat/Lng pour validation post-geocode.
    // Si le geocoder dérive (>50km de l'expected), on force les
    // coords canoniques — la map est authoritative pour ces villes.
    final canonical =
        getCanonicalSegmentCity(segmentCity, country: segCountry);
    final query = canonical?.canonicalQuery ??
        (segCountry.isNotEmpty ? '$segmentCity, $segCountry' : segmentCity);
    final regionHint = canonical?.countryCode ??
        trip.destinationCountryCode?.trim().toLowerCase();
    final geo = await geocoder.geocode(query, regionHint: regionHint);
    if (geo != null) {
      // V8.18 — validation contre coords canoniques.
      if (canonical != null) {
        final dKm = _haversineKmDayCenter(
          geo.latitude, geo.longitude,
          canonical.expectedLat, canonical.expectedLng,
        );
        if (dKm > 50.0) {
          // Geocoder a dérivé (homonyme régional) — override avec
          // les coords canoniques.
          // ignore: avoid_print
          print(
            '[segment_resolve_reject] input="$segmentCity" '
            'rejected=(${geo.latitude.toStringAsFixed(3)},'
            '${geo.longitude.toStringAsFixed(3)}) '
            'distFromCanonical=${dKm.toStringAsFixed(0)}km '
            'reason=wrong_region '
            'expected="${canonical.canonicalQuery}" '
            '(${canonical.expectedLat},${canonical.expectedLng})',
          );
          // ignore: avoid_print
          print(
            '[segment_resolve] input="$segmentCity" country="$segCountry" '
            'resolved="${canonical.canonicalQuery}" '
            'lat=${canonical.expectedLat} lng=${canonical.expectedLng} '
            'source=canonical_override',
          );
          return DayCenter(
            latitude: canonical.expectedLat,
            longitude: canonical.expectedLng,
            source: 'segment_city',
          );
        }
        // ignore: avoid_print
        print(
          '[segment_resolve] input="$segmentCity" country="$segCountry" '
          'resolved="$query" lat=${geo.latitude} lng=${geo.longitude} '
          'source=canonical_alias',
        );
      }
      developer.log(
        'Centre du jour ${_iso(day)} = ville segment "$query" '
        '(region=$regionHint) → ${geo.latitude},${geo.longitude}',
        name: 'day_center',
      );
      return DayCenter(latitude: geo.latitude, longitude: geo.longitude, source: 'segment_city');
    }
    // V8.18 — geocoder a échoué mais on a un canonical → fallback hard.
    if (canonical != null) {
      // ignore: avoid_print
      print(
        '[segment_resolve] input="$segmentCity" country="$segCountry" '
        'resolved="${canonical.canonicalQuery}" '
        'lat=${canonical.expectedLat} lng=${canonical.expectedLng} '
        'source=canonical_fallback (geocoder=null)',
      );
      return DayCenter(
        latitude: canonical.expectedLat,
        longitude: canonical.expectedLng,
        source: 'segment_city',
      );
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

/// V8.18 (Lalith 2026-05-10) — haversine km utilisé pour valider la
/// résolution canonical des segment cities. Identique à
/// `_haversineKmBetween` de places_first_pipeline mais isolé ici
/// pour éviter une dépendance circulaire.
double _haversineKmDayCenter(
  double lat1,
  double lng1,
  double lat2,
  double lng2,
) {
  const earthKm = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return earthKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
