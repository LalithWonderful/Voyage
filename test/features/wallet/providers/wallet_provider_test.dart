/// Tests unitaires des helpers `wallet_provider.dart` exposés en
/// top-level (pas les providers Riverpod eux-mêmes).
///
/// Couverture :
/// - `hotelForDay` : Options A (1 seul), C (user choice), D (itinerary
///   match V2 2026-05-08), B (shortest stay fallback).
/// - `isNightResolved` : variantes single / Option C / Option D /
///   ambiguïté.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

TripDocument _hotel({
  required String id,
  required String city,
  required String checkIn,
  required String checkOut,
  List<String>? sleepNights,
  String? addressCity,
}) =>
    TripDocument(
      id: id,
      userId: 'u',
      tripId: 't',
      category: DocumentCategory.hotel,
      name: 'Hôtel $city',
      metadata: {
        'address_city': addressCity ?? city,
        'address': '$city, Country',
        'check_in': checkIn,
        'check_out': checkOut,
        'sleep_nights': ?sleepNights,
      },
      createdAt: DateTime(2026, 1, 1),
    );

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

void main() {
  group('hotelForDay — Option D (itinerary inference)', () {
    test('long-stay Bangkok overlap hôtel local Phú Quốc, itinéraire = '
        'Phú Quốc → pick Phú Quốc', () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      final result = hotelForDay(
        hotels,
        _d(2026, 7, 4),
        itineraryCity: 'Phú Quốc',
      );
      expect(result?.id, 'pqc');
    });

    test('itineraryCity = Bangkok → pick Bangkok (même quand un hôtel court '
        'overlap)', () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      // Le 24/06 le voyageur est à Bangkok (avant Phú Quốc), pas
      // d'overlap effectif → un seul candidat couvre. Test sanity.
      final result = hotelForDay(
        hotels,
        _d(2026, 6, 24),
        itineraryCity: 'Bangkok',
      );
      expect(result?.id, 'bkk');
    });

    test('Option C user choice prime sur Option D itinéraire', () {
      // Si l'utilisateur a déjà choisi Bangkok pour la nuit, on respecte
      // même si l'itinéraire dit autre chose (cas edge où l'user override).
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
          sleepNights: const ['2026-07-04'],
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      final result = hotelForDay(
        hotels,
        _d(2026, 7, 4),
        itineraryCity: 'Phú Quốc',
      );
      expect(result?.id, 'bkk');
    });

    test('itineraryCity match aucun candidat → fallback Option B '
        '(shortest stay)', () {
      // Cas dégénéré : la ville de l'itinéraire ne correspond à aucun
      // hôtel candidat. Fallback heuristique.
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      // Le 04/07 le voyageur serait théoriquement à "Hanoï" (mismatch).
      // Aucun hôtel match Hanoï → tomber sur shortest = Phú Quốc 5 nuits.
      final result = hotelForDay(
        hotels,
        _d(2026, 7, 4),
        itineraryCity: 'Hanoï',
      );
      expect(result?.id, 'pqc');
    });

    test('itineraryCity match plusieurs candidats → ambiguïté → '
        'fallback Option B', () {
      // 2 hôtels à la même ville (rare). Pas de désambiguation possible
      // par itinéraire seul → shortest gagne.
      final hotels = [
        _hotel(
          id: 'bkk-long',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'bkk-short',
          city: 'Bangkok',
          checkIn: '2026-07-04',
          checkOut: '2026-07-06',
        ),
      ];
      final result = hotelForDay(
        hotels,
        _d(2026, 7, 5),
        itineraryCity: 'Bangkok',
      );
      expect(result?.id, 'bkk-short'); // shortest
    });

    test('itineraryCity null → comportement legacy (Option B uniquement)',
        () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      // Sans itineraryCity, fallback shortest = Phú Quốc.
      final result = hotelForDay(hotels, _d(2026, 7, 4));
      expect(result?.id, 'pqc');
    });
  });

  group('isNightResolved', () {
    test('1 seul candidat → résolu (pas un overlap)', () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-06-25',
        ),
      ];
      expect(isNightResolved(hotels, _d(2026, 6, 23)), isTrue);
    });

    test('overlap + Option C user choice → résolu', () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
          sleepNights: const ['2026-07-04'],
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      expect(isNightResolved(hotels, _d(2026, 7, 4)), isTrue);
    });

    test('overlap + Option D itinerary disambiguates → résolu', () {
      // Cas E2E : apparts Bangkok longue durée + hôtel local Phú Quốc,
      // itinéraire dit Phú Quốc → un seul candidat match → résolu sans
      // demander.
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      expect(
        isNightResolved(hotels, _d(2026, 7, 4), itineraryCity: 'Phú Quốc'),
        isTrue,
      );
    });

    test('overlap sans Option C ni itinéraire → ambigu', () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      expect(isNightResolved(hotels, _d(2026, 7, 4)), isFalse);
    });

    test('overlap + itinéraire match plusieurs candidats → ambigu', () {
      // 2 hôtels à Bangkok la même nuit + itinéraire = Bangkok →
      // toujours ambigu (Option D ne peut pas trancher entre 2 matches).
      final hotels = [
        _hotel(
          id: 'bkk-1',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'bkk-2',
          city: 'Bangkok',
          checkIn: '2026-07-04',
          checkOut: '2026-07-06',
        ),
      ];
      expect(
        isNightResolved(hotels, _d(2026, 7, 5), itineraryCity: 'Bangkok'),
        isFalse,
      );
    });

    test('matching ville insensible à la casse / accents simples', () {
      final hotels = [
        _hotel(
          id: 'bkk',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _hotel(
          id: 'hanoi',
          city: 'Hanoï',
          checkIn: '2026-07-07',
          checkOut: '2026-07-10',
          addressCity: 'Hanoï',
        ),
      ];
      // Pas vraiment d'overlap ici (Hanoï 07-10, Bangkok 22/06-06/08
      // mais Hanoï 07/07 n'est pas dans Bangkok... wait yes it is).
      // 09/07 → Bangkok et Hanoï tous les deux. itinéraire 'hanoi'
      // (sans tréma) doit matcher 'Hanoï'.
      expect(
        isNightResolved(hotels, _d(2026, 7, 9), itineraryCity: 'hanoi'),
        isTrue,
      );
    });
  });
}
