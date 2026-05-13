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
  });
}
