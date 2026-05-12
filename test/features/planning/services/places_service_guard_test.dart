// API-0.4d — Offline guard tests for legacy PlacesService.
//
// These tests use a fake http client. They do not call Google or Supabase.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/services/places_service.dart';

void main() {
  group('PlacesService legacy live API guards', () {
    test('blocked methods throw before HTTP', () async {
      final httpClient = _FakePlacesHttpClient();
      final service = _service(
        guards: LiveApiGuards.defaults(),
        httpClient: httpClient,
      );

      await _expectBlocked(
        () => service.findInfo(query: 'Place Stanislas'),
        'PlacesService.findInfo',
      );
      await _expectBlocked(
        () => service.autocompleteCities('Nan'),
        'PlacesService.autocompleteCities',
      );
      await _expectBlocked(
        () => service.autocompleteDestinations('Nan'),
        'PlacesService.autocompleteDestinations',
      );
      await _expectBlocked(
        () => service.autocompleteTransport('CDG', type: 'airport'),
        'PlacesService.autocompleteTransport',
      );
      await _expectBlocked(
        () => service.resolvePlaceCoords('place-1'),
        'PlacesService.resolvePlaceCoords',
      );
      await _expectBlocked(
        () => service.getCountryCodeFromPlaceId('place-1'),
        'PlacesService.getCountryCodeFromPlaceId',
      );
      await _expectBlocked(
        () => service.findCityCoords('Nancy'),
        'PlacesService.findCityCoords',
      );
      await _expectBlocked(
        () => service.getDetails('place-1'),
        'PlacesService.getDetails',
      );

      expect(httpClient.requests, isEmpty);
    });

    test('findInfo with allowGooglePlaces reaches fake HTTP', () async {
      final httpClient = _FakePlacesHttpClient();
      final service = _service(
        guards: const LiveApiGuards(allowGooglePlaces: true),
        httpClient: httpClient,
      );

      final info = await service.findInfo(query: 'Place Stanislas');

      expect(info.placeId, 'place-1');
      expect(info.name, 'Place Stanislas');
      expect(info.rating, 4.7);
      expect(info.photos, hasLength(1));
      expect(info.photos.single.url, contains('/maps/api/place/photo'));
      expect(httpClient.requests, hasLength(1));
      expect(
        httpClient.requests.single.url.path,
        '/maps/api/place/findplacefromtext/json',
      );
    });

    test(
      'autocompleteCities with allowGooglePlaces launches three fake calls',
      () async {
        final httpClient = _FakePlacesHttpClient();
        final service = _service(
          guards: const LiveApiGuards(allowGooglePlaces: true),
          httpClient: httpClient,
        );

        final results = await service.autocompleteCities('Nan');

        expect(results, hasLength(1));
        expect(results.single.placeId, 'autocomplete-place');
        expect(httpClient.requests, hasLength(3));
        expect(
          httpClient.requests
              .map((r) => r.url.queryParameters['types'])
              .toSet(),
          {'(cities)', 'geocode', 'establishment'},
        );
      },
    );

    test('ALLOW_LIVE_APIS=true allows autocompleteDestinations', () async {
      final httpClient = _FakePlacesHttpClient();
      final service = _service(
        guards: LiveApiGuards.fromEnvironmentMap(const {
          'ALLOW_LIVE_APIS': 'true',
        }),
        httpClient: httpClient,
      );

      final results = await service.autocompleteDestinations('France');

      expect(results, hasLength(1));
      expect(results.single.kind, 'country');
      expect(httpClient.requests, hasLength(1));
      expect(
        httpClient.requests.single.url.path,
        '/maps/api/place/autocomplete/json',
      );
    });

    test(
      'details and coordinate methods parse fake HTTP when allowed',
      () async {
        final httpClient = _FakePlacesHttpClient();
        final service = _service(
          guards: const LiveApiGuards(allowGooglePlaces: true),
          httpClient: httpClient,
        );

        final coords = await service.resolvePlaceCoords('place-1');
        final country = await service.getCountryCodeFromPlaceId('place-1');
        final city = await service.findCityCoords('Nancy');
        final details = await service.getDetails('place-1');

        expect(coords?.lat, 48.8566);
        expect(coords?.countryCode, 'fr');
        expect(country, 'fr');
        expect(city?.formattedAddress, 'Nancy, France');
        expect(details.reviews, hasLength(1));
        expect(details.openingHours, isNotNull);
        expect(httpClient.requests, hasLength(4));
      },
    );

    test(
      'invalid inputs keep existing fallbacks without requiring live flag',
      () async {
        final httpClient = _FakePlacesHttpClient();
        final service = _service(
          guards: LiveApiGuards.defaults(),
          httpClient: httpClient,
        );

        expect(await service.findInfo(query: '   '), PlaceInfo.empty);
        expect(await service.autocompleteCities('n'), isEmpty);
        expect(await service.autocompleteDestinations('n'), isEmpty);
        expect(
          await service.autocompleteTransport('CDG', type: 'bus_station'),
          isEmpty,
        );
        expect(await service.resolvePlaceCoords(''), isNull);
        expect(await service.getCountryCodeFromPlaceId(''), isNull);
        expect(await service.findCityCoords('   '), isNull);
        final details = await service.getDetails('');
        expect(details.reviews, isEmpty);
        expect(details.openingHours, isNull);
        expect(httpClient.requests, isEmpty);
      },
    );
  });
}

PlacesService _service({
  required LiveApiGuards guards,
  required _FakePlacesHttpClient httpClient,
}) {
  return PlacesService(
    guards: guards,
    httpClient: httpClient,
    apiKey: 'test-google-places-key',
  );
}

Future<void> _expectBlocked(
  Future<Object?> Function() call,
  String operation,
) async {
  await expectLater(
    call,
    throwsA(
      isA<LiveApiBlockedException>()
          .having((e) => e.family, 'family', LiveApiFamily.googlePlaces)
          .having((e) => e.operation, 'operation', operation),
    ),
  );
}

class _FakePlacesHttpClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final uri = request.url;
    final body = switch (uri.path) {
      '/maps/api/place/findplacefromtext/json' => _findPlaceResponse(uri),
      '/maps/api/place/autocomplete/json' => _autocompleteResponse(),
      '/maps/api/place/details/json' => _detailsResponse(uri),
      _ => {'status': 'ZERO_RESULTS'},
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  Map<String, Object?> _findPlaceResponse(Uri uri) {
    final fields = uri.queryParameters['fields'] ?? '';
    if (fields.contains('geometry')) {
      return {
        'status': 'OK',
        'candidates': [
          {
            'formatted_address': 'Nancy, France',
            'geometry': {
              'location': {'lat': 48.6921, 'lng': 6.1844},
            },
          },
        ],
      };
    }
    return {
      'status': 'OK',
      'candidates': [
        {
          'place_id': 'place-1',
          'name': 'Place Stanislas',
          'rating': 4.7,
          'user_ratings_total': 1234,
          'price_level': 2,
          'formatted_address': 'Place Stanislas, Nancy',
          'photos': [
            {
              'photo_reference': 'photo-ref',
              'html_attributions': ['Attribution'],
            },
          ],
        },
      ],
    };
  }

  Map<String, Object?> _autocompleteResponse() {
    return {
      'status': 'OK',
      'predictions': [
        {
          'description': 'France',
          'place_id': 'autocomplete-place',
          'structured_formatting': {'main_text': 'France'},
          'types': ['country', 'locality'],
        },
      ],
    };
  }

  Map<String, Object?> _detailsResponse(Uri uri) {
    final fields = uri.queryParameters['fields'] ?? '';
    if (fields.contains('geometry')) {
      return {
        'status': 'OK',
        'result': {
          'name': 'Paris',
          'geometry': {
            'location': {'lat': 48.8566, 'lng': 2.3522},
          },
          'address_components': [
            {
              'long_name': 'Paris',
              'short_name': 'Paris',
              'types': ['locality'],
            },
            {
              'long_name': 'France',
              'short_name': 'FR',
              'types': ['country'],
            },
          ],
        },
      };
    }
    if (fields.contains('address_component')) {
      return {
        'status': 'OK',
        'result': {
          'address_components': [
            {
              'long_name': 'France',
              'short_name': 'FR',
              'types': ['country'],
            },
          ],
        },
      };
    }
    return {
      'status': 'OK',
      'result': {
        'reviews': [
          {
            'author_name': 'Lalith',
            'rating': 5,
            'text': 'Super.',
            'relative_time_description': 'il y a 1 jour',
          },
        ],
        'opening_hours': {
          'weekday_text': ['lundi: 09:00 – 18:00'],
          'periods': [
            {
              'open': {'day': 1, 'time': '0900'},
              'close': {'day': 1, 'time': '1800'},
            },
          ],
        },
      },
    };
  }
}
