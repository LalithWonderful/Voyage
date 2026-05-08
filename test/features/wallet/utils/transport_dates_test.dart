/// Tests unitaires `transport_dates.dart` (V2.3).
///
/// Couvre :
/// - `inferArrivalDate` : same-day, overnight, explicite prioritaire,
///   formats invalides.
/// - `arrivalDateFromMetadata` : lecture depuis metadata + fallback.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

void main() {
  group('inferArrivalDate', () {
    test('same-day : arrival_time > departure_time → même jour', () {
      // Vol 10:10 → 12:25 : pas de J+1.
      final out = inferArrivalDate(
        departureDate: _d(2026, 6, 22),
        departureTime: '10:10',
        arrivalTime: '12:25',
      );
      expect(out, _d(2026, 6, 22));
    });

    test('overnight : arrival_time < departure_time → J+1', () {
      // Vol 23:30 → 12:15 : départ 21/06, arrivée 22/06.
      final out = inferArrivalDate(
        departureDate: _d(2026, 6, 21),
        departureTime: '23:30',
        arrivalTime: '12:15',
      );
      expect(out, _d(2026, 6, 22));
    });

    test('arrival_time == departure_time → même jour (heuristique '
        'conservative, pas de J+1)', () {
      final out = inferArrivalDate(
        departureDate: _d(2026, 6, 22),
        departureTime: '10:00',
        arrivalTime: '10:00',
      );
      expect(out, _d(2026, 6, 22));
    });

    test('explicitArrivalDate fournie → priorité absolue, pas d\'inférence',
        () {
      // Même si arrival_time < departure_time, si l'arrival_date est
      // explicitement le 25/06, on respecte (vol >24h ou cas spécial).
      final out = inferArrivalDate(
        departureDate: _d(2026, 6, 21),
        departureTime: '23:30',
        arrivalTime: '12:15',
        explicitArrivalDate: _d(2026, 6, 25),
      );
      expect(out, _d(2026, 6, 25));
    });

    test('temps manquant → même jour (pas de J+1 sans signal fiable)', () {
      final out = inferArrivalDate(
        departureDate: _d(2026, 6, 21),
        departureTime: null,
        arrivalTime: '12:15',
      );
      expect(out, _d(2026, 6, 21));
    });

    test('format de temps invalide → même jour', () {
      final out = inferArrivalDate(
        departureDate: _d(2026, 6, 21),
        departureTime: 'pas un horaire',
        arrivalTime: '12:15',
      );
      expect(out, _d(2026, 6, 21));
    });

    test('departureDate null + pas d\'explicit → null', () {
      final out = inferArrivalDate(
        departureDate: null,
        departureTime: '10:10',
        arrivalTime: '12:25',
      );
      expect(out, isNull);
    });

    test('departureDate null + explicit fournie → utilise explicit', () {
      final out = inferArrivalDate(
        departureDate: null,
        explicitArrivalDate: _d(2026, 6, 22),
      );
      expect(out, _d(2026, 6, 22));
    });
  });

  group('arrivalDateFromMetadata', () {
    test('arrival_date explicite → priorité', () {
      final out = arrivalDateFromMetadata(const {
        'date': '2026-06-21',
        'arrival_date': '2026-06-22',
        'departure_time': '10:00',
        'arrival_time': '08:00',
      });
      expect(out, _d(2026, 6, 22));
    });

    test('pas d\'arrival_date, vol overnight → infère J+1', () {
      // Cas Lux→BKK : départ 23:30 le 21/06, arrivée 12:15 le 22/06.
      final out = arrivalDateFromMetadata(const {
        'date': '2026-06-21',
        'departure_time': '23:30',
        'arrival_time': '12:15',
      });
      expect(out, _d(2026, 6, 22));
    });

    test('pas d\'arrival_date, vol same-day → date du document', () {
      final out = arrivalDateFromMetadata(const {
        'date': '2026-07-08',
        'departure_time': '10:10',
        'arrival_time': '12:25',
      });
      expect(out, _d(2026, 7, 8));
    });

    test('pas de date du tout → null', () {
      final out = arrivalDateFromMetadata(const {});
      expect(out, isNull);
    });

    test('date présente, pas de times → utilise date (pas de J+1)', () {
      // Doc minimal saisi à la main : pas d'horaires → on assume same-day.
      final out = arrivalDateFromMetadata(const {
        'date': '2026-06-21',
      });
      expect(out, _d(2026, 6, 21));
    });
  });
}
