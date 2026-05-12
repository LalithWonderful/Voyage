// API-0.2 — Unit tests for live API guards.
//
// Pure unit tests: no network, no Supabase, no Google/Gemini dependency.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';

void main() {
  const expectedMapKeys = {
    'googlePlaces',
    'googleRoutes',
    'googleGeocoding',
    'gemini',
    'supabase',
    'networkImages',
    'deviceLocation',
    'currencyApi',
  };

  group('LiveApiGuards — defaults', () {
    test('const constructor defaults every family to false', () {
      const guards = LiveApiGuards();

      expect(guards.allowGooglePlaces, isFalse);
      expect(guards.allowGoogleRoutes, isFalse);
      expect(guards.allowGoogleGeocoding, isFalse);
      expect(guards.allowGemini, isFalse);
      expect(guards.allowSupabase, isFalse);
      expect(guards.allowNetworkImages, isFalse);
      expect(guards.allowDeviceLocation, isFalse);
      expect(guards.allowCurrencyApi, isFalse);
      expect(guards.allowsAnyLiveApi, isFalse);
    });

    test('defaults() is equivalent to const constructor', () {
      expect(LiveApiGuards.defaults(), equals(const LiveApiGuards()));
    });

    test('fromEnvironmentMap({}) returns every family false', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {});

      expect(guards, equals(const LiveApiGuards()));
      expect(guards.toMap().values.every((v) => v == false), isTrue);
    });
  });

  group('LiveApiGuards — specific flags', () {
    test('each specific flag can enable its own family', () {
      const cases = <String, LiveApiFamily>{
        'ALLOW_LIVE_GOOGLE_PLACES': LiveApiFamily.googlePlaces,
        'ALLOW_LIVE_GOOGLE_ROUTES': LiveApiFamily.googleRoutes,
        'ALLOW_LIVE_GOOGLE_GEOCODING': LiveApiFamily.googleGeocoding,
        'ALLOW_LIVE_GEMINI': LiveApiFamily.gemini,
        'ALLOW_LIVE_SUPABASE': LiveApiFamily.supabase,
        'ALLOW_LIVE_NETWORK_IMAGES': LiveApiFamily.networkImages,
        'ALLOW_LIVE_DEVICE_LOCATION': LiveApiFamily.deviceLocation,
        'ALLOW_LIVE_CURRENCY_API': LiveApiFamily.currencyApi,
      };

      for (final entry in cases.entries) {
        final guards = LiveApiGuards.fromEnvironmentMap({entry.key: 'true'});

        for (final family in LiveApiFamily.values) {
          expect(
            guards.allows(family),
            family == entry.value,
            reason: '${entry.key} should only enable ${entry.value.name}',
          );
        }
        expect(guards.allowsAnyLiveApi, isTrue);
      }
    });
  });

  group('LiveApiGuards — bool parsing', () {
    test('truthy values are recognized', () {
      const variants = ['true', 'TRUE', 'True', '1', 'yes', 'YES', 'Yes'];

      for (final value in variants) {
        final guards = LiveApiGuards.fromEnvironmentMap({
          'ALLOW_LIVE_GEMINI': value,
        });

        expect(
          guards.allowGemini,
          isTrue,
          reason: '"$value" should parse as true',
        );
      }
    });

    test('falsy values are recognized', () {
      const variants = ['false', 'FALSE', 'False', '0', 'no', 'NO', 'No'];

      for (final value in variants) {
        final guards = LiveApiGuards.fromEnvironmentMap({
          'ALLOW_LIVE_GEMINI': value,
        });

        expect(
          guards.allowGemini,
          isFalse,
          reason: '"$value" should parse as false',
        );
      }
    });

    test('unknown, empty, and absent values default to false', () {
      const variants = ['maybe', 'oui', '42', 'truthy', ''];

      for (final value in variants) {
        final guards = LiveApiGuards.fromEnvironmentMap({
          'ALLOW_LIVE_GEMINI': value,
        });

        expect(
          guards.allowGemini,
          isFalse,
          reason: '"$value" should default to false',
        );
      }

      expect(LiveApiGuards.fromEnvironmentMap(const {}).allowGemini, isFalse);
    });

    test('whitespace is trimmed', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_GEMINI': '  yes  ',
      });

      expect(guards.allowGemini, isTrue);
    });
  });

  group('LiveApiGuards — global flag', () {
    test('ALLOW_LIVE_APIS=true enables every family', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_APIS': 'true',
      });

      expect(guards.toMap().values.every((v) => v), isTrue);
      for (final family in LiveApiFamily.values) {
        expect(guards.allows(family), isTrue);
      }
      expect(guards.allowsAnyLiveApi, isTrue);
    });

    test('ALLOW_LIVE_APIS=false does not enable families by itself', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_APIS': 'false',
      });

      expect(guards, equals(const LiveApiGuards()));
    });

    test('specific true still works when ALLOW_LIVE_APIS=false', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_APIS': 'false',
        'ALLOW_LIVE_GOOGLE_ROUTES': 'true',
      });

      expect(guards.allowGoogleRoutes, isTrue);
      expect(guards.allowGooglePlaces, isFalse);
    });
  });

  group('LiveApiGuards — map and family coverage', () {
    test('toMap returns exactly the expected families', () {
      const guards = LiveApiGuards();
      final map = guards.toMap();

      expect(map, hasLength(8));
      expect(map.keys.toSet(), equals(expectedMapKeys));
    });

    test('toMap reflects current values', () {
      const guards = LiveApiGuards(
        allowGooglePlaces: true,
        allowGemini: true,
        allowCurrencyApi: true,
      );

      expect(guards.toMap(), {
        'googlePlaces': true,
        'googleRoutes': false,
        'googleGeocoding': false,
        'gemini': true,
        'supabase': false,
        'networkImages': false,
        'deviceLocation': false,
        'currencyApi': true,
      });
    });

    test('allows(family) returns the matching bool', () {
      const guards = LiveApiGuards(
        allowGooglePlaces: true,
        allowGoogleRoutes: false,
        allowGoogleGeocoding: true,
        allowGemini: false,
        allowSupabase: true,
        allowNetworkImages: false,
        allowDeviceLocation: true,
        allowCurrencyApi: false,
      );

      expect(guards.allows(LiveApiFamily.googlePlaces), isTrue);
      expect(guards.allows(LiveApiFamily.googleRoutes), isFalse);
      expect(guards.allows(LiveApiFamily.googleGeocoding), isTrue);
      expect(guards.allows(LiveApiFamily.gemini), isFalse);
      expect(guards.allows(LiveApiFamily.supabase), isTrue);
      expect(guards.allows(LiveApiFamily.networkImages), isFalse);
      expect(guards.allows(LiveApiFamily.deviceLocation), isTrue);
      expect(guards.allows(LiveApiFamily.currencyApi), isFalse);
    });

    test('every enum family is represented in toMap', () {
      expect(LiveApiFamily.values, hasLength(8));
      expect(LiveApiFamily.values.map((f) => f.name).toSet(), {
        'googlePlaces',
        'googleRoutes',
        'googleGeocoding',
        'gemini',
        'supabase',
        'networkImages',
        'deviceLocation',
        'currencyApi',
      });
      expect(
        LiveApiGuards.fromEnvironmentMap(const {
          'ALLOW_LIVE_APIS': 'true',
        }).toMap().keys.toSet(),
        equals(LiveApiFamily.values.map((f) => f.name).toSet()),
      );
    });
  });

  group('LiveApiGuards — assertAllowed', () {
    test('does not throw when the family is allowed', () {
      const guards = LiveApiGuards(allowGooglePlaces: true);

      expect(
        () => guards.assertAllowed(
          LiveApiFamily.googlePlaces,
          operation: 'unit test allowed call',
        ),
        returnsNormally,
      );
    });

    test('throws LiveApiBlockedException when blocked', () {
      const guards = LiveApiGuards();

      expect(
        () => guards.assertAllowed(
          LiveApiFamily.googlePlaces,
          operation: 'unit test blocked call',
        ),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.googlePlaces)
              .having((e) => e.operation, 'operation', 'unit test blocked call')
              .having(
                (e) => e.message,
                'message',
                contains('Live API call blocked'),
              ),
        ),
      );
    });
  });
}
