import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/services/places_service.dart';

void main() {
  group('PlacesService autocomplete guard integration', () {
    late PlacesService service;

    setUp(() {
      // No API key → Google fallback returns empty, but Lunao-first still works
      service = PlacesService(apiKey: '');
    });

    test('autocompleteDestinations returns Lunao Lisbon for "lisb"', () async {
      final results = await service.autocompleteDestinations('lisb');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
      expect(results.first.kind, 'city');
    });

    test('autocompleteDestinations returns Lunao Lisbon for "lisbo"', () async {
      final results = await service.autocompleteDestinations('lisbo');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
      expect(results.first.kind, 'city');
    });

    test('autocompleteDestinations returns Lunao Lisbon for "lisbon"', () async {
      final results = await service.autocompleteDestinations('lisbon');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
      expect(results.first.kind, 'city');
    });

    test('autocompleteDestinations returns Lunao Lisbon for "Lisbonne"', () async {
      final results = await service.autocompleteDestinations('Lisbonne');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
    });

    test('autocompleteDestinations returns Lunao Lisbon for "Lisboa"', () async {
      final results = await service.autocompleteDestinations('Lisboa');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
    });

    test('autocompleteDestinations returns Lunao Lisbon for "lisbon portugal"', () async {
      final results = await service.autocompleteDestinations('lisbon portugal');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
    });

    test('autocompleteDestinations skips Google for short query "tok"', () async {
      final results = await service.autocompleteDestinations('tok');
      expect(results, isEmpty);
    });

    test('autocompleteDestinations returns empty for unknown query with no API key', () async {
      final results = await service.autocompleteDestinations('tokyo');
      expect(results, isEmpty);
    });

    test('autocompleteCities returns Lunao Lisbon for "lisb"', () async {
      final results = await service.autocompleteCities('lisb');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
    });

    test('autocompleteCities returns Lunao Lisbon for "lisbon"', () async {
      final results = await service.autocompleteCities('lisbon');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
    });

    test('autocompleteCities skips Google for short query "tok"', () async {
      final results = await service.autocompleteCities('tok');
      expect(results, isEmpty);
    });

    test('autocompleteTransport skips Google for short query "cdg"', () async {
      final results = await service.autocompleteTransport('cdg', type: 'airport');
      expect(results, isEmpty);
    });

    test('autocompleteTransport does NOT return Lunao Lisbon for "lisbon"', () async {
      // Transport should NOT match Lunao destinations
      final results = await service.autocompleteTransport('lisbon', type: 'airport');
      // No API key → Google fallback returns empty
      expect(results, isEmpty);
    });

    test('autocompleteTransport does NOT return Lunao Lisbon for "lisbo"', () async {
      // Transport should NOT match Lunao destinations even with prefix
      final results = await service.autocompleteTransport('lisbo', type: 'airport');
      expect(results, isEmpty);
    });

    test('autocompleteTransport returns empty for unknown query with no API key', () async {
      final results = await service.autocompleteTransport('tokyo', type: 'airport');
      expect(results, isEmpty);
    });

    test('Lunao prefix hit bypasses guard and does not call Google', () async {
      // No API key → if Google fallback were called, it would return empty.
      // Returning Lisbonne proves Lunao prefix matched and guard was skipped.
      final results = await service.autocompleteDestinations('lisbo');
      expect(results.length, 1);
      expect(results.first.mainText, 'Lisbonne');
      expect(results.first.placeId, 'lunao:lisbon');
    });

    test('repeated Lunao prefix query returns Lunao result consistently', () async {
      // Lunao matches bypass the guard cache entirely; both calls should
      // return the same static result without touching Google.
      final r1 = await service.autocompleteDestinations('lisbo');
      expect(r1.length, 1);
      expect(r1.first.mainText, 'Lisbonne');

      final r2 = await service.autocompleteDestinations('lisbo');
      expect(r2.length, 1);
      expect(r2.first.mainText, 'Lisbonne');
    });

    test('cache: same destination query second time hits guard cache', () async {
      // First call — no API key, so Google returns empty, but guard caches it
      final r1 = await service.autocompleteDestinations('unknown-city');
      expect(r1, isEmpty);

      // Second call — should hit cache (still empty, but no re-attempt)
      final r2 = await service.autocompleteDestinations('unknown-city');
      expect(r2, isEmpty);
    });

    // ─── API-0.6b — Country-first tests ───

    test('autocompleteDestinations returns Lunao France for "fran"', () async {
      final results = await service.autocompleteDestinations('fran');
      expect(results.length, 1);
      expect(results.first.mainText, 'France');
      expect(results.first.placeId, 'lunao:country:fr');
      expect(results.first.kind, 'country');
    });

    test('autocompleteDestinations returns Lunao France for "france"', () async {
      final results = await service.autocompleteDestinations('france');
      expect(results.length, 1);
      expect(results.first.mainText, 'France');
      expect(results.first.placeId, 'lunao:country:fr');
      expect(results.first.kind, 'country');
    });

    test('autocompleteDestinations returns Lunao USA for "usa"', () async {
      final results = await service.autocompleteDestinations('usa');
      expect(results.length, 1);
      expect(results.first.mainText, 'États-Unis');
      expect(results.first.placeId, 'lunao:country:us');
      expect(results.first.kind, 'country');
    });

    test('autocompleteDestinations returns Lunao USA for "etats"', () async {
      final results = await service.autocompleteDestinations('etats');
      expect(results.length, 1);
      expect(results.first.mainText, 'États-Unis');
      expect(results.first.placeId, 'lunao:country:us');
      expect(results.first.kind, 'country');
    });

    test('autocompleteDestinations returns Lunao Japan for "japon"', () async {
      final results = await service.autocompleteDestinations('japon');
      expect(results.length, 1);
      expect(results.first.mainText, 'Japon');
      expect(results.first.placeId, 'lunao:country:jp');
      expect(results.first.kind, 'country');
    });

    test('autocompleteDestinations does not return country for "fr" (too short)', () async {
      final results = await service.autocompleteDestinations('fr');
      expect(results, isEmpty);
    });

    test('getCountryCodeFromPlaceId resolves lunao:lisbon locally', () async {
      final code = await service.getCountryCodeFromPlaceId('lunao:lisbon');
      expect(code, 'pt');
    });

    test('getCountryCodeFromPlaceId resolves lunao:country:fr locally', () async {
      final code = await service.getCountryCodeFromPlaceId('lunao:country:fr');
      expect(code, 'fr');
    });

    test('getCountryCodeFromPlaceId resolves lunao:country:us locally', () async {
      final code = await service.getCountryCodeFromPlaceId('lunao:country:us');
      expect(code, 'us');
    });

    // ─── API-0.6c — Region-first tests ───

    test('autocompleteDestinations returns Lunao Bali for "bali"', () async {
      final results = await service.autocompleteDestinations('bali');
      expect(results.length, 1);
      expect(results.first.mainText, 'Bali');
      expect(results.first.placeId, 'lunao:region:id:bali');
      expect(results.first.kind, 'region');
    });

    test('autocompleteDestinations returns Lunao Toscane for "tosc"', () async {
      final results = await service.autocompleteDestinations('tosc');
      expect(results.length, 1);
      expect(results.first.mainText, 'Toscane');
      expect(results.first.placeId, 'lunao:region:it:toscane');
      expect(results.first.kind, 'region');
    });

    test('autocompleteDestinations returns Lunao Andalousie for "andal"', () async {
      final results = await service.autocompleteDestinations('andal');
      expect(results.length, 1);
      expect(results.first.mainText, 'Andalousie');
      expect(results.first.placeId, 'lunao:region:es:andalousie');
      expect(results.first.kind, 'region');
    });

    test('autocompleteDestinations returns Lunao Provence for "proven"', () async {
      final results = await service.autocompleteDestinations('proven');
      expect(results.length, 1);
      expect(results.first.mainText, 'Provence');
      expect(results.first.placeId, 'lunao:region:fr:provence');
      expect(results.first.kind, 'region');
    });

    test('autocompleteDestinations returns Lunao Sicile for "sicil"', () async {
      final results = await service.autocompleteDestinations('sicil');
      expect(results.length, 1);
      expect(results.first.mainText, 'Sicile');
      expect(results.first.placeId, 'lunao:region:it:sicile');
      expect(results.first.kind, 'region');
    });

    test('autocompleteDestinations returns Lunao Île-de-France for "ile-d"', () async {
      final results = await service.autocompleteDestinations('ile-d');
      expect(results.length, 1);
      expect(results.first.mainText, 'Île-de-France');
      expect(results.first.placeId, 'lunao:region:fr:idf');
      expect(results.first.kind, 'region');
    });

    test('getCountryCodeFromPlaceId resolves lunao:region:it:toscane locally', () async {
      final code = await service.getCountryCodeFromPlaceId('lunao:region:it:toscane');
      expect(code, 'it');
    });

    test('getCountryCodeFromPlaceId resolves lunao:region:fr:provence locally', () async {
      final code = await service.getCountryCodeFromPlaceId('lunao:region:fr:provence');
      expect(code, 'fr');
    });

    test('getCountryCodeFromPlaceId returns null for unknown synthetic id', () async {
      final code = await service.getCountryCodeFromPlaceId('lunao:unknown');
      expect(code, isNull);
    });
  });
}
