import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/trips/services/flight_timeline_builder.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Helper pour fabriquer un doc Vol minimal avec le strict métadata utilisé
/// par le builder. Évite de répéter 15 lignes par fixture.
TripDocument _flight({
  required String name,
  required String date,
  required String fromCity,
  required String fromCountryCode,
  required String toCity,
  required String toCountryCode,
  double? toLat,
  double? toLng,
  String? departureTime,
  String? arrivalTime,
}) {
  return TripDocument(
    id: name,
    userId: 'u1',
    tripId: 't1',
    category: DocumentCategory.flight,
    name: name,
    metadata: {
      'date': date,
      'from_city': fromCity,
      'from_country_code': fromCountryCode,
      'to_city': toCity,
      'to_country_code': toCountryCode,
      'to_latitude': ?toLat,
      'to_longitude': ?toLng,
      'departure_time': ?departureTime,
      'arrival_time': ?arrivalTime,
    },
    createdAt: DateTime.parse(date),
  );
}

void main() {
  group('buildTripStayTimelineFromFlightDocuments — voyage Thaïlande', () {
    // Brief Lalith 2026-05-08 : voyage Thaïlande 21/06 → 06/08, 6 vols
    // dont Luxembourg en départ ET retour. Le builder doit produire
    // exactement 5 séjours avec Bangkok x2 et SANS Luxembourg.
    final docs = [
      _flight(
        name: 'Turkish LUX→BKK',
        date: '2026-06-21',
        fromCity: 'Luxembourg',
        fromCountryCode: 'lu',
        toCity: 'Bangkok',
        toCountryCode: 'th',
        // Vol overnight : départ 21/06 10:20, arrivée 22/06 05:10
        departureTime: '10:20',
        arrivalTime: '05:10',
      ),
      _flight(
        name: 'VietJet BKK→Phú Quốc',
        date: '2026-07-03',
        fromCity: 'Bangkok',
        fromCountryCode: 'th',
        toCity: 'Phú Quốc',
        toCountryCode: 'vn',
      ),
      _flight(
        name: 'VN Phú Quốc→Hanoï',
        date: '2026-07-08',
        fromCity: 'Phú Quốc',
        fromCountryCode: 'vn',
        toCity: 'Hanoï',
        toCountryCode: 'vn',
      ),
      _flight(
        name: 'VN Hanoï→Da Nang',
        date: '2026-07-12',
        fromCity: 'Hanoï',
        fromCountryCode: 'vn',
        toCity: 'Da Nang',
        toCountryCode: 'vn',
      ),
      _flight(
        name: 'VN Da Nang→BKK',
        date: '2026-07-15',
        fromCity: 'Da Nang',
        fromCountryCode: 'vn',
        toCity: 'Bangkok',
        toCountryCode: 'th',
      ),
      _flight(
        name: 'Turkish BKK→LUX',
        date: '2026-08-06',
        fromCity: 'Bangkok',
        fromCountryCode: 'th',
        toCity: 'Luxembourg',
        toCountryCode: 'lu',
      ),
    ];
    final tripEnd = DateTime(2026, 8, 6);

    test("Luxembourg n'est jamais une étape", () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: tripEnd,
        homeAirportCity: 'Luxembourg',
        homeCountryCode: 'lu',
      );
      for (final s in stays) {
        expect(s.city.toLowerCase(), isNot('luxembourg'),
            reason: 'Luxembourg = home base, ne doit pas être étape');
      }
    });

    test('Produit exactement 5 séjours dans le bon ordre', () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: tripEnd,
        homeAirportCity: 'Luxembourg',
        homeCountryCode: 'lu',
      );
      expect(stays.length, 5);
      expect(stays[0].city, 'Bangkok');
      expect(stays[1].city, 'Phú Quốc');
      expect(stays[2].city, 'Hanoï');
      expect(stays[3].city, 'Da Nang');
      expect(stays[4].city, 'Bangkok');
    });

    test('Bangkok apparaît bien deux fois comme séjours distincts', () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: tripEnd,
        homeAirportCity: 'Luxembourg',
        homeCountryCode: 'lu',
      );
      final bangkok = stays.where((s) => s.city == 'Bangkok').toList();
      expect(bangkok.length, 2);
      // Premier séjour 22/06 (J+1 vol overnight Lux→BKK) → 03/07,
      // deuxième 15/07 → 06/08
      expect(bangkok[0].startDate, DateTime(2026, 6, 22));
      expect(bangkok[0].endDate, DateTime(2026, 7, 3));
      expect(bangkok[1].startDate, DateTime(2026, 7, 15));
      expect(bangkok[1].endDate, DateTime(2026, 8, 6));
    });

    test('Dates exactes selon les vols (avec J+1 sur les overnight)', () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: tripEnd,
        homeAirportCity: 'Luxembourg',
        homeCountryCode: 'lu',
      );
      // Bangkok séjour 1 : arrivée 22/06 (vol overnight) → 03/07
      expect(stays[0].startDate, DateTime(2026, 6, 22));
      expect(stays[0].endDate, DateTime(2026, 7, 3));

      expect(stays[1].startDate, DateTime(2026, 7, 3));
      expect(stays[1].endDate, DateTime(2026, 7, 8));

      expect(stays[2].startDate, DateTime(2026, 7, 8));
      expect(stays[2].endDate, DateTime(2026, 7, 12));

      expect(stays[3].startDate, DateTime(2026, 7, 12));
      expect(stays[3].endDate, DateTime(2026, 7, 15));

      expect(stays[4].startDate, DateTime(2026, 7, 15));
      expect(stays[4].endDate, DateTime(2026, 8, 6));
    });

    test('Vol overnight : startDate = J+1 (arrival_time < departure_time)',
        () {
      final overnightDocs = [
        _flight(
          name: 'Vol nuit',
          date: '2026-06-21',
          fromCity: 'Luxembourg',
          fromCountryCode: 'lu',
          toCity: 'Bangkok',
          toCountryCode: 'th',
          departureTime: '22:00',
          arrivalTime: '06:00',
        ),
      ];
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: overnightDocs,
        tripEndDate: DateTime(2026, 7, 1),
        homeAirportCity: 'Luxembourg',
      );
      expect(stays.length, 1);
      expect(stays[0].startDate, DateTime(2026, 6, 22));
    });

    test('Vol jour : startDate = même jour que la date de départ', () {
      final dayDocs = [
        _flight(
          name: 'Vol jour',
          date: '2026-06-21',
          fromCity: 'Paris',
          fromCountryCode: 'fr',
          toCity: 'Rome',
          toCountryCode: 'it',
          departureTime: '08:00',
          arrivalTime: '10:30',
        ),
      ];
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: dayDocs,
        tripEndDate: DateTime(2026, 6, 30),
        homeAirportCity: 'Paris',
      );
      expect(stays.length, 1);
      expect(stays[0].startDate, DateTime(2026, 6, 21));
    });

    test('Total de jours placés ne dépasse pas la durée du voyage', () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: tripEnd,
        homeAirportCity: 'Luxembourg',
        homeCountryCode: 'lu',
      );
      final total = stays.fold<int>(0, (acc, s) => acc + s.days);
      // Voyage = 21/06 → 06/08 = 46 jours (inclusif)
      // Les séjours se suivent sans gap, le total doit ≈ 46
      expect(total, lessThanOrEqualTo(47));
      expect(total, greaterThanOrEqualTo(45));
    });

    test('Pays correctement attribué à chaque séjour', () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: tripEnd,
        homeAirportCity: 'Luxembourg',
        homeCountryCode: 'lu',
      );
      expect(stays[0].countryCode, 'th');
      expect(stays[0].country, 'Thaïlande');
      expect(stays[1].countryCode, 'vn');
      expect(stays[1].country, 'Vietnam');
      expect(stays[4].countryCode, 'th');
      expect(stays[4].country, 'Thaïlande');
    });
  });

  group('Cas dégénérés', () {
    test('Aucun vol → liste vide', () {
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: const [],
        tripEndDate: DateTime(2026, 8, 6),
      );
      expect(stays, isEmpty);
    });

    test('Vol sans to_city → ignoré', () {
      final docs = [
        TripDocument(
          id: 'd1',
          userId: 'u1',
          tripId: 't1',
          category: DocumentCategory.flight,
          name: 'Vol incomplet',
          metadata: {'date': '2026-06-21', 'from_city': 'Paris'},
          createdAt: DateTime(2026, 6, 21),
        ),
      ];
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: DateTime(2026, 8, 6),
      );
      expect(stays, isEmpty);
    });

    test('Vol sans home info → tous les to_city deviennent séjours', () {
      // Sans homeAirportCity ni homeCountryCode, on n'a pas de moyen de filtrer
      // le retour. C'est OK pour les voyages sans aller-retour explicite
      // (ex: voyage one-way ou train-only).
      final docs = [
        _flight(
          name: 'A',
          date: '2026-06-21',
          fromCity: 'Paris',
          fromCountryCode: 'fr',
          toCity: 'Bangkok',
          toCountryCode: 'th',
        ),
        _flight(
          name: 'B',
          date: '2026-07-01',
          fromCity: 'Bangkok',
          fromCountryCode: 'th',
          toCity: 'Phuket',
          toCountryCode: 'th',
        ),
      ];
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: DateTime(2026, 7, 15),
      );
      expect(stays.length, 2);
      expect(stays[0].city, 'Bangkok');
      expect(stays[1].city, 'Phuket');
    });

    test('Filtre home country_code seul ne suffit pas (sécurité)', () {
      // Sans homeAirportCity, on ne doit PAS exclure une ville juste parce
      // que son country_code matche le home. Risque sinon : voyage en France
      // → toutes les étapes FR seraient skippées car home=FR.
      final docs = [
        _flight(
          name: 'A',
          date: '2026-06-21',
          fromCity: 'Paris',
          fromCountryCode: 'fr',
          toCity: 'Lyon',
          toCountryCode: 'fr',
        ),
      ];
      final stays = buildTripStayTimelineFromFlightDocuments(
        docs: docs,
        tripEndDate: DateTime(2026, 6, 25),
        homeCountryCode: 'fr',
      );
      // Lyon ne doit PAS être skippé juste parce que fr=fr.
      expect(stays.length, 1);
      expect(stays[0].city, 'Lyon');
    });
  });
}
