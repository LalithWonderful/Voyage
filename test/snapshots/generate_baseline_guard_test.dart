// API-0.3 — Offline tests for dangerous script live API guards.
//
// These tests do not import or execute generate_baseline.dart or
// places_first_harness.dart. They only exercise the pure helper that those
// scripts call before any live service is created.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';

import '../helpers/live_api_script_guards.dart';

void main() {
  group('generate_baseline live API guard', () {
    test('no flags means Google Places and Geocoding are missing', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {});

      expect(
        missingLiveApiFamiliesForGenerateBaseline(guards),
        equals([LiveApiFamily.googlePlaces, LiveApiFamily.googleGeocoding]),
      );
    });

    test('only Places still leaves Geocoding missing', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_GOOGLE_PLACES': 'true',
      });

      expect(
        missingLiveApiFamiliesForGenerateBaseline(guards),
        equals([LiveApiFamily.googleGeocoding]),
      );
    });

    test('Places plus Geocoding is allowed', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_GOOGLE_PLACES': 'true',
        'ALLOW_LIVE_GOOGLE_GEOCODING': 'true',
      });

      expect(missingLiveApiFamiliesForGenerateBaseline(guards), isEmpty);
      expect(
        () => assertLiveApisAllowedForGenerateBaseline(guards: guards),
        returnsNormally,
      );
    });

    test('ALLOW_LIVE_APIS=true is allowed', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_APIS': 'true',
      });

      expect(missingLiveApiFamiliesForGenerateBaseline(guards), isEmpty);
    });

    test('blocked error message contains required dart-defines', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {});

      expect(
        () => assertLiveApisAllowedForGenerateBaseline(guards: guards),
        throwsA(
          isA<LiveApiScriptGuardException>()
              .having(
                (e) => e.message,
                'message',
                contains('Live API calls are disabled for this script'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_GOOGLE_PLACES=true'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true'),
              ),
        ),
      );
    });
  });

  group('places_first_harness live API guard', () {
    test('no flags means Google Places and Geocoding are missing', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {});

      expect(
        missingLiveApiFamiliesForPlacesFirstHarness(guards),
        equals([LiveApiFamily.googlePlaces, LiveApiFamily.googleGeocoding]),
      );
    });

    test('only Places still leaves Geocoding missing', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_GOOGLE_PLACES': 'true',
      });

      expect(
        missingLiveApiFamiliesForPlacesFirstHarness(guards),
        equals([LiveApiFamily.googleGeocoding]),
      );
    });

    test('Places plus Geocoding is allowed', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_GOOGLE_PLACES': 'true',
        'ALLOW_LIVE_GOOGLE_GEOCODING': 'true',
      });

      expect(missingLiveApiFamiliesForPlacesFirstHarness(guards), isEmpty);
      expect(
        () => assertLiveApisAllowedForPlacesFirstHarness(guards: guards),
        returnsNormally,
      );
    });

    test('ALLOW_LIVE_APIS=true is allowed', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_APIS': 'true',
      });

      expect(missingLiveApiFamiliesForPlacesFirstHarness(guards), isEmpty);
    });

    test('blocked error message contains required dart-defines', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {});

      expect(
        () => assertLiveApisAllowedForPlacesFirstHarness(guards: guards),
        throwsA(
          isA<LiveApiScriptGuardException>()
              .having(
                (e) => e.message,
                'message',
                contains('Live API calls are disabled for this script'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_GOOGLE_PLACES=true'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true'),
              ),
        ),
      );
    });
  });
}
