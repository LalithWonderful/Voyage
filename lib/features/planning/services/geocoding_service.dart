import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';

class GeocodingResult {
  final double latitude;
  final double longitude;
  final String formattedAddress;

  const GeocodingResult({required this.latitude, required this.longitude, required this.formattedAddress});
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
      developer.log(
        'Geocoding OK "$trimmed" → ${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}',
        name: 'geocoding',
      );
      return GeocodingResult(
        latitude: lat,
        longitude: lng,
        formattedAddress: first['formatted_address'] as String? ?? trimmed,
      );
    } catch (e) {
      developer.log('Erreur geocoding : $e', name: 'geocoding');
      return null;
    }
  }
}
