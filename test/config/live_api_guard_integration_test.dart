// API-0.5 — Offline consolidation test for the no-live-by-default regime.
//
// This test does not instantiate any real live service. It only exercises
// the pure `LiveApiGuards` policy and the test-only script helpers, to prove
// that:
//   1. Defaults block every known live API family.
//   2. The dangerous scripts require the right --dart-define flags.
//   3. `LiveApiFamily` keeps covering every family declared in the
//      consolidation document.
//   4. Blocked errors keep producing clear messages (family + operation
//      + dart-define).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';

import '../helpers/live_api_script_guards.dart';

void main() {
  const criticalFamilies = <LiveApiFamily>{
    LiveApiFamily.googlePlaces,
    LiveApiFamily.googleRoutes,
    LiveApiFamily.googleGeocoding,
    LiveApiFamily.gemini,
    LiveApiFamily.supabase,
    LiveApiFamily.networkImages,
    LiveApiFamily.deviceLocation,
    LiveApiFamily.currencyApi,
    LiveApiFamily.overpass,
  };

  group('API-0.5 — no live API by default', () {
    test('LiveApiGuards.defaults() blocks every family', () {
      final guards = LiveApiGuards.defaults();

      for (final family in LiveApiFamily.values) {
        expect(
          guards.allows(family),
          isFalse,
          reason: 'defaults() should block ${family.name}',
        );
      }
      expect(guards.allowsAnyLiveApi, isFalse);
    });

    test('LiveApiGuards.fromEnvironmentMap({}) blocks every family', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {});

      for (final family in LiveApiFamily.values) {
        expect(
          guards.allows(family),
          isFalse,
          reason: 'empty env should block ${family.name}',
        );
      }
      expect(guards.allowsAnyLiveApi, isFalse);
    });

    test('ALLOW_LIVE_APIS=true allows every family', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_APIS': 'true',
      });

      for (final family in LiveApiFamily.values) {
        expect(
          guards.allows(family),
          isTrue,
          reason: 'ALLOW_LIVE_APIS=true should allow ${family.name}',
        );
      }
      expect(guards.allowsAnyLiveApi, isTrue);
    });
  });

  group('API-0.5 — critical families covered by LiveApiFamily', () {
    test('LiveApiFamily exposes exactly the 9 critical families', () {
      expect(LiveApiFamily.values.toSet(), equals(criticalFamilies));
    });

    test('every critical family is enumerated by name', () {
      const expectedNames = {
        'googlePlaces',
        'googleRoutes',
        'googleGeocoding',
        'gemini',
        'supabase',
        'networkImages',
        'deviceLocation',
        'currencyApi',
        'overpass',
      };

      expect(
        LiveApiFamily.values.map((f) => f.name).toSet(),
        equals(expectedNames),
      );
    });
  });

  group('API-0.5 — generate_baseline.dart guard requirements', () {
    test('defaults leave Places and Geocoding missing', () {
      final guards = LiveApiGuards.defaults();

      expect(
        missingLiveApiFamiliesForGenerateBaseline(guards),
        equals([LiveApiFamily.googlePlaces, LiveApiFamily.googleGeocoding]),
      );
    });

    test('Places + Geocoding flags satisfy the script guard', () {
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
  });

  group('API-0.5 — places_first_harness.dart guard requirements', () {
    test('defaults leave Places and Geocoding missing', () {
      final guards = LiveApiGuards.defaults();

      expect(
        missingLiveApiFamiliesForPlacesFirstHarness(guards),
        equals([LiveApiFamily.googlePlaces, LiveApiFamily.googleGeocoding]),
      );
    });

    test('Places + Geocoding flags satisfy the script guard', () {
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
  });

  group('API-0.5 — blocked error messages stay explicit', () {
    test(
      'LiveApiBlockedException carries family, operation, and dart-define hint',
      () {
        const guards = LiveApiGuards();

        expect(
          () => guards.assertAllowed(
            LiveApiFamily.gemini,
            operation: 'API-0.5 consolidation check',
          ),
          throwsA(
            isA<LiveApiBlockedException>()
                .having((e) => e.family, 'family', LiveApiFamily.gemini)
                .having(
                  (e) => e.operation,
                  'operation',
                  'API-0.5 consolidation check',
                )
                .having(
                  (e) => e.message,
                  'mentions family name',
                  contains('gemini'),
                )
                .having(
                  (e) => e.message,
                  'mentions operation',
                  contains('API-0.5 consolidation check'),
                )
                .having(
                  (e) => e.message,
                  'points to ALLOW_LIVE_* flag',
                  contains('ALLOW_LIVE_'),
                ),
          ),
        );
      },
    );

    test(
      'generate_baseline script guard message lists missing family and define',
      () {
        final guards = LiveApiGuards.defaults();

        expect(
          () => assertLiveApisAllowedForGenerateBaseline(guards: guards),
          throwsA(
            isA<LiveApiScriptGuardException>()
                .having(
                  (e) => e.message,
                  'names the script',
                  contains('test/snapshots/generate_baseline.dart'),
                )
                .having(
                  (e) => e.message,
                  'lists missing Places',
                  contains('googlePlaces'),
                )
                .having(
                  (e) => e.message,
                  'lists missing Geocoding',
                  contains('googleGeocoding'),
                )
                .having(
                  (e) => e.message,
                  'spells out Places dart-define',
                  contains('--dart-define=ALLOW_LIVE_GOOGLE_PLACES=true'),
                )
                .having(
                  (e) => e.message,
                  'spells out Geocoding dart-define',
                  contains('--dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true'),
                ),
          ),
        );
      },
    );

    test(
      'places_first_harness script guard message lists missing family and define',
      () {
        final guards = LiveApiGuards.defaults();

        expect(
          () => assertLiveApisAllowedForPlacesFirstHarness(guards: guards),
          throwsA(
            isA<LiveApiScriptGuardException>()
                .having(
                  (e) => e.message,
                  'names the script',
                  contains('test/dev/places_first_harness.dart'),
                )
                .having(
                  (e) => e.message,
                  'lists missing Places',
                  contains('googlePlaces'),
                )
                .having(
                  (e) => e.message,
                  'lists missing Geocoding',
                  contains('googleGeocoding'),
                )
                .having(
                  (e) => e.message,
                  'spells out Places dart-define',
                  contains('--dart-define=ALLOW_LIVE_GOOGLE_PLACES=true'),
                )
                .having(
                  (e) => e.message,
                  'spells out Geocoding dart-define',
                  contains('--dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true'),
                ),
          ),
        );
      },
    );
  });
}
