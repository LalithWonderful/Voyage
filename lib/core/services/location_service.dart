import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';

class UserLocation {
  final double latitude;
  final double longitude;
  final DateTime capturedAt;
  const UserLocation({required this.latitude, required this.longitude, required this.capturedAt});
}

/// Service singleton qui gère la position GPS de l'utilisateur.
/// Cache en mémoire 1h pour éviter de rappeler le GPS sur des clics rapprochés (ex. 10x Suggérer).
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  UserLocation? _cached;
  static const _ttl = Duration(hours: 1);

  /// Récupère la position courante. Retourne null si refusée ou indisponible.
  /// Cache 1h : si on a fetché il y a moins d'1h, on réutilise directement.
  Future<UserLocation?> getCurrentLocation() async {
    if (_cached != null && DateTime.now().difference(_cached!.capturedAt) < _ttl) {
      developer.log('Position cached (${_cached!.capturedAt})', name: 'location');
      return _cached;
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        developer.log('Service de localisation désactivé', name: 'location');
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        developer.log('Permission refusée : $permission', name: 'location');
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 10)),
      );
      _cached = UserLocation(
        latitude: pos.latitude,
        longitude: pos.longitude,
        capturedAt: DateTime.now(),
      );
      developer.log('Position fetched : ${pos.latitude}, ${pos.longitude}', name: 'location');
      return _cached;
    } catch (e) {
      developer.log('Erreur GPS : $e', name: 'location');
      return null;
    }
  }

  /// Invalide le cache (utile si l'utilisateur signale un changement manuel de lieu).
  void invalidateCache() {
    _cached = null;
  }
}

/// Distance à vol d'oiseau en kilomètres (formule haversine).
double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const earthRadiusKm = 6371.0;
  final dLat = _toRad(lat2 - lat1);
  final dLng = _toRad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_toRad(lat1)) * math.cos(_toRad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusKm * c;
}

/// Estimation grossière du temps de trajet (minutes) pour une distance en km.
/// Hypothèse pragmatique : 35 km/h en moyenne (trafic urbain + transports).
int estimatedTravelMinutes(double distanceKm) {
  const avgSpeedKmh = 35.0;
  return (distanceKm / avgSpeedKmh * 60).round();
}

double _toRad(double deg) => deg * math.pi / 180;
