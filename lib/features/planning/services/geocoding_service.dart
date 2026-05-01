import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/planning/services/place_components.dart';

class GeocodingResult {
  final double latitude;
  final double longitude;
  final String formattedAddress;
  /// Code pays ISO 2 (lowercase) extrait des `address_components` quand
  /// présent. Permet de signaler les vols/trains hors du pays du voyage
  /// même quand on est passé par le fallback Geocoding texte (pas de
  /// placeId dispo).
  final String? countryCode;
  /// Nom de la ville (locality / postal_town / sublocality_level_1) extrait
  /// des `address_components`. Permet de déduire l'étape voyage (city) depuis
  /// un aéroport ou une gare. Null si pas de locality dans la réponse.
  final String? city;

  const GeocodingResult({
    required this.latitude,
    required this.longitude,
    required this.formattedAddress,
    this.countryCode,
    this.city,
  });
}

class GeocodingService {
  Future<GeocodingResult?> geocode(String query, {String? regionHint}) async {
    if (AiConstants.googleMapsApiKey == 'COLLE_TA_CLE_MAPS_ICI' || AiConstants.googleMapsApiKey.isEmpty) {
      developer.log('Clé Google Maps manquante — skip géocodage', name: 'geocoding');
      return null;
    }
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final params = {
      'address': trimmed,
      'key': AiConstants.googleMapsApiKey,
      if (regionHint != null && regionHint.isNotEmpty) 'region': regionHint,
    };
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', params);
    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        developer.log('Geocoding HTTP ${response.statusCode} : ${response.body}', name: 'geocoding');
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      if (status != 'OK') {
        developer.log('Geocoding status=$status pour "$trimmed"', name: 'geocoding');
        return null;
      }
      final results = data['results'] as List;
      if (results.isEmpty) return null;
      final first = results.first as Map<String, dynamic>;
      final location = first['geometry']['location'] as Map<String, dynamic>;
      final lat = (location['lat'] as num).toDouble();
      final lng = (location['lng'] as num).toDouble();
      // Extraction du code pays ISO 2 + ville depuis address_components — déjà
      // inclus dans la réponse Geocoding API par défaut, pas d'appel supp.
      String? countryCode;
      final components = (first['address_components'] as List?) ?? const [];
      String? locality;
      String? postalTown;
      String? adminLevel1;
      String? sublocalityLevel1;
      String? adminLevel2;
      for (final comp in components.whereType<Map<String, dynamic>>()) {
        final types = ((comp['types'] as List?) ?? const []).whereType<String>().toSet();
        if (types.contains('country')) {
          final shortName = comp['short_name'] as String?;
          if (shortName != null && shortName.isNotEmpty) {
            countryCode = shortName.toLowerCase();
          }
        }
        final long = comp['long_name'] as String?;
        if (long == null || long.isEmpty) continue;
        if (types.contains('locality')) locality = long;
        if (types.contains('postal_town')) postalTown = long;
        if (types.contains('administrative_area_level_1')) adminLevel1 = long;
        if (types.contains('sublocality_level_1') || types.contains('sublocality')) {
          sublocalityLevel1 = long;
        }
        if (types.contains('administrative_area_level_2')) adminLevel2 = long;
      }
      // Override aéroport (BKK→Bangkok, CDG→Paris, NRT→Tokyo, etc.) si match
      // par coords. Sinon cascade address_components via
      // pickCityFromComponents. Cf. `airport_city_overrides.dart` et
      // `place_components.dart`.
      final city = overrideCityForAirportLatLng(lat, lng) ??
          pickCityFromComponents(
            locality: locality,
            postalTown: postalTown,
            adminLevel1: adminLevel1,
            sublocalityLevel1: sublocalityLevel1,
            adminLevel2: adminLevel2,
          );
      developer.log(
        'Geocoding OK "$trimmed" → ${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)} (country=$countryCode, city=$city)',
        name: 'geocoding',
      );
      return GeocodingResult(
        latitude: lat,
        longitude: lng,
        formattedAddress: first['formatted_address'] as String? ?? trimmed,
        countryCode: countryCode,
        city: city,
      );
    } catch (e) {
      developer.log('Erreur geocoding : $e', name: 'geocoding');
      return null;
    }
  }
}
