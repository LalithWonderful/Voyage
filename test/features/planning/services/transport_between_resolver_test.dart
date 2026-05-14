// TRANSPORT-0.1 — Offline tests for TransportBetweenResolver.
//
// Validates that "Ajouter un trajet" is deterministic-first and non-blocking:
// - coordinates close together → walking suggestion without Gemini
// - coordinates far apart → public transport/taxi suggestion without Gemini
// - missing coordinates → manual fallback row
// - Gemini blocked → non-fatal fallback (resolver returns manual, UI catches)
// - traveler type influences default mode selection

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/services/transport_between_resolver.dart';

void main() {
  group('TransportBetweenResolver', () {
    test('close coordinates (<= 1 km) → walk default with walk option', () {
      final resolver = TransportBetweenResolver();
      final from = _activity(
        id: 'a1',
        title: 'Musée du Louvre',
        lat: 48.8606,
        lng: 2.3376,
      );
      final to = _activity(
        id: 'a2',
        title: 'Café de Flore',
        lat: 48.8543,
        lng: 2.3330,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      expect(suggestion.defaultMode, 'walk');
      expect(suggestion.options, hasLength(1));
      expect(suggestion.options.first.mode, 'walk');
      expect(suggestion.options.first.priceEstimate, 'Gratuit');
      expect(suggestion.options.first.detail, isNotNull);
    });

    test('medium coordinates (1–4 km) → transit default, transit + taxi options', () {
      final resolver = TransportBetweenResolver();
      final from = _activity(
        id: 'a1',
        title: 'Musée du Louvre',
        lat: 48.8606,
        lng: 2.3376,
      );
      final to = _activity(
        id: 'a2',
        title: 'Tour Eiffel',
        lat: 48.8584,
        lng: 2.2945,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      // Distance Louvre → Tour Eiffel ≈ 3.5 km
      expect(suggestion.defaultMode, 'transit');
      final modes = suggestion.options.map((o) => o.mode).toList();
      expect(modes, contains('transit'));
      expect(modes, contains('taxi'));
      expect(modes, isNot(contains('walk')));
    });

    test('far coordinates (> 4 km) → transit default, transit + taxi options', () {
      final resolver = TransportBetweenResolver();
      final from = _activity(
        id: 'a1',
        title: 'Gare du Nord',
        lat: 48.8809,
        lng: 2.3553,
      );
      final to = _activity(
        id: 'a2',
        title: 'Aéroport CDG',
        lat: 49.0097,
        lng: 2.5479,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      // Distance ≈ 22 km
      expect(suggestion.defaultMode, 'transit');
      final modes = suggestion.options.map((o) => o.mode).toList();
      expect(modes, contains('transit'));
      expect(modes, contains('taxi'));
      expect(modes, isNot(contains('walk')));
    });

    test('missing coordinates → manual fallback row', () {
      final resolver = TransportBetweenResolver();
      final from = _activity(id: 'a1', title: 'Hôtel XYZ');
      final to = _activity(id: 'a2', title: 'Musée du Louvre');

      final suggestion = resolver.resolve(from: from, to: to);

      expect(suggestion.defaultMode, 'manual');
      expect(suggestion.options, hasLength(1));
      expect(suggestion.options.first.mode, 'manual');
      expect(suggestion.options.first.detail, 'Trajet à compléter');
      expect(suggestion.options.first.priceEstimate, '—');
    });

    test('Grand luxe traveler → taxi default for medium distance', () {
      final resolver = TransportBetweenResolver(travelerType: 'Grand luxe');
      final from = _activity(
        id: 'a1',
        title: 'Musée du Louvre',
        lat: 48.8606,
        lng: 2.3376,
      );
      final to = _activity(
        id: 'a2',
        title: 'Tour Eiffel',
        lat: 48.8584,
        lng: 2.2945,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      expect(suggestion.defaultMode, 'taxi');
    });

    test('Backpack traveler → transit default for medium distance', () {
      final resolver = TransportBetweenResolver(travelerType: 'Backpack');
      final from = _activity(
        id: 'a1',
        title: 'Musée du Louvre',
        lat: 48.8606,
        lng: 2.3376,
      );
      final to = _activity(
        id: 'a2',
        title: 'Tour Eiffel',
        lat: 48.8584,
        lng: 2.2945,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      expect(suggestion.defaultMode, 'transit');
    });

    test('Voyage pro traveler → taxi default for medium distance', () {
      final resolver = TransportBetweenResolver(travelerType: 'Voyage pro');
      final from = _activity(
        id: 'a1',
        title: 'Musée du Louvre',
        lat: 48.8606,
        lng: 2.3376,
      );
      final to = _activity(
        id: 'a2',
        title: 'Tour Eiffel',
        lat: 48.8584,
        lng: 2.2945,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      expect(suggestion.defaultMode, 'taxi');
    });

    test('En famille traveler → transit default for medium distance', () {
      final resolver = TransportBetweenResolver(travelerType: 'En famille');
      final from = _activity(
        id: 'a1',
        title: 'Musée du Louvre',
        lat: 48.8606,
        lng: 2.3376,
      );
      final to = _activity(
        id: 'a2',
        title: 'Tour Eiffel',
        lat: 48.8584,
        lng: 2.2945,
      );

      final suggestion = resolver.resolve(from: from, to: to);

      expect(suggestion.defaultMode, 'transit');
    });
  });
}

TripActivity _activity({
  required String id,
  required String title,
  double? lat,
  double? lng,
}) {
  return TripActivity(
    id: id,
    tripId: 'trip-1',
    dayDate: DateTime(2026, 6, 1),
    startTime: '10:00',
    title: title,
    tag: 'Visite',
    latitude: lat,
    longitude: lng,
  );
}
