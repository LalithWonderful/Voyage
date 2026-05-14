import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/transport/data/transport_hubs_seed.dart';
import 'package:voyage/features/transport/services/offline_transport_hub_resolver.dart';

void main() {
  group('OfflineTransportHubResolver', () {
    const resolver = OfflineTransportHubResolver();

    test('seed covers the 7 pilot cities with major hubs only', () {
      final cities = transportHubsSeed.map((hub) => hub.city).toSet();

      expect(
        cities,
        containsAll([
          'london',
          'amsterdam',
          'paris',
          'rome',
          'barcelona',
          'lisbon',
          'marrakech',
        ]),
      );
      expect(resolver.listForCity('paris'), hasLength(7));
      expect(resolver.listForCity('lisbon'), hasLength(6));
      expect(resolver.listForCity('marrakech'), hasLength(4));
    });

    test('exact search resolves a known train station', () {
      final hub = resolver.resolve(
        city: 'london',
        query: 'London St Pancras International',
      );

      expect(hub, isNotNull);
      expect(hub!.id, equals('london_st_pancras_international'));
      expect(hub.hubType, equals(TransportHubType.intermodalStation));
    });

    test('alias search resolves accented and common names', () {
      expect(
        resolver.resolve(city: 'lisbon', query: 'Santa Apolonia')?.id,
        equals('lisbon_santa_apolonia'),
      );
      expect(
        resolver.resolve(city: 'barcelona', query: 'Estacio del Nord')?.id,
        equals('barcelona_estacio_del_nord_bus_station'),
      );
      expect(
        resolver.resolve(city: 'marrakech', query: 'gare de marrakech')?.id,
        equals('marrakech_railway_station'),
      );
    });

    test('unknown city returns unresolved null', () {
      expect(resolver.resolve(city: 'tokyo', query: 'Tokyo Station'), isNull);
      expect(resolver.listForCity('tokyo'), isEmpty);
    });

    test('unknown hub returns unresolved null without fallback', () {
      expect(
        resolver.resolve(city: 'paris', query: 'Imaginary Central'),
        isNull,
      );
    });

    test('priority chooses the highest-priority hub among broad matches', () {
      final hub = resolver.resolve(city: 'paris', query: 'gare');

      expect(hub, isNotNull);
      expect(hub!.id, equals('paris_gare_du_nord'));
      expect(hub.priority, equals(100));
    });

    test('hub type filter avoids wrong transport family', () {
      expect(
        resolver.resolve(
          city: 'paris',
          query: 'Bercy',
          hubTypes: {TransportHubType.railwayStation},
        ),
        isNull,
      );
      expect(
        resolver
            .resolve(
              city: 'paris',
              query: 'Bercy',
              hubTypes: {TransportHubType.busStation},
            )
            ?.id,
        equals('paris_bercy_seine_bus_station'),
      );
    });

    test('airport link codes resolve where explicitly curated', () {
      expect(
        resolver.resolve(city: 'rome', query: 'FCO')?.id,
        equals('rome_fiumicino_aeroporto_railway_station'),
      );
      expect(
        resolver.resolve(city: 'marrakech', query: 'RAK')?.id,
        equals('marrakech_menara_airport_bus_taxi_hub'),
      );
    });

    test('seed contains no Google or live API identifiers', () {
      for (final hub in transportHubsSeed) {
        expect(hub.id.startsWith('ChIJ'), isFalse);
        expect(hub.sourceNote.toLowerCase(), contains('no live api call'));
        expect(
          hub.latitude,
          allOf(greaterThanOrEqualTo(-90), lessThanOrEqualTo(90)),
        );
        expect(
          hub.longitude,
          allOf(greaterThanOrEqualTo(-180), lessThanOrEqualTo(180)),
        );
      }
    });
  });
}
