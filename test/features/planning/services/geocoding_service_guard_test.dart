// API-0.4a — Offline guard tests for GeocodingService.
//
// These tests do not call Google. Blocked calls throw before http.get.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';

void main() {
  group('GeocodingService live API guards', () {
    test(
      'empty query returns null without requiring live permission',
      () async {
        final service = GeocodingService(guards: LiveApiGuards.defaults());

        final result = await service.geocode('   ');

        expect(result, isNull);
      },
    );

    test(
      'non-empty query throws when live Google Geocoding is blocked',
      () async {
        final service = GeocodingService(guards: LiveApiGuards.defaults());

        expect(
          () => service.geocode('Singapore'),
          throwsA(
            isA<LiveApiBlockedException>()
                .having(
                  (e) => e.family,
                  'family',
                  LiveApiFamily.googleGeocoding,
                )
                .having(
                  (e) => e.operation,
                  'operation',
                  'GeocodingService.geocode',
                ),
          ),
        );
      },
    );
  });
}
