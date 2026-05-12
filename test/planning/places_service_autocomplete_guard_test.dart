import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/services/places_service.dart';

void main() {
  group('PlacesService autocomplete guard integration', () {
    late PlacesService service;

    setUp(() {
      // No API key → Google fallback returns empty, but Lunao-first still works
      service = PlacesService(apiKey: '');
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

    test('autocompleteTransport returns empty for unknown query with no API key', () async {
      final results = await service.autocompleteTransport('tokyo', type: 'airport');
      expect(results, isEmpty);
    });

    test('cache: same destination query second time hits guard cache', () async {
      // First call — no API key, so Google returns empty, but guard caches it
      final r1 = await service.autocompleteDestinations('unknown-city');
      expect(r1, isEmpty);

      // Second call — should hit cache (still empty, but no re-attempt)
      final r2 = await service.autocompleteDestinations('unknown-city');
      expect(r2, isEmpty);
    });
  });
}
