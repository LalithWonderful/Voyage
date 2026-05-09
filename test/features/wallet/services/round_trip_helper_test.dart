/// Tests unitaires `analyseRoundTripExtraction` (round-trip helper).
///
/// V5 (Lalith 2026-05-10) — couvre la traduction d'un blob de metadata
/// Gemini en deux entités séparées (aller + retour) prêtes à être
/// insérées dans `trip_documents`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/wallet/services/round_trip_helper.dart';

void main() {
  group('analyseRoundTripExtraction — flight round-trip', () {
    test('billet AR Turkish complet (booking VU6L3L) → 2 entités '
        'séparées, retour hérite reservation_number + airline', () {
      final raw = <String, dynamic>{
        'airline': 'Turkish Airlines',
        'flight_number': 'TK1354 + TK0058',
        'from': 'LUX',
        'to': 'BKK',
        'date': '2026-06-21',
        'departure_time': '10:20',
        'arrival_date': '2026-06-22',
        'arrival_time': '05:10',
        'reservation_number': 'VU6L3L',
        'is_round_trip': true,
        'return_leg': {
          'flight_number': 'TK0069 + TK1353',
          'from': 'BKK',
          'to': 'LUX',
          'date': '2026-08-06',
          'departure_time': '22:45',
          'arrival_date': '2026-08-07',
          'arrival_time': '09:25',
        },
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      // Aller : pas de pollution round-trip dans la metadata
      // persistée. Le reste reste inchangé.
      expect(result.outboundMetadata.containsKey('is_round_trip'), isFalse);
      expect(result.outboundMetadata.containsKey('return_leg'), isFalse);
      expect(result.outboundMetadata['airline'], 'Turkish Airlines');
      expect(result.outboundMetadata['from'], 'LUX');
      expect(result.outboundMetadata['to'], 'BKK');
      expect(result.outboundMetadata['date'], '2026-06-21');
      expect(result.outboundMetadata['arrival_date'], '2026-06-22');

      // Retour : hérite reservation_number + airline depuis l'aller
      // (Gemini ne les répète pas dans return_leg). Dates et numéros
      // restent ceux du retour.
      expect(result.returnMetadata, isNotNull);
      expect(result.returnMetadata!['reservation_number'], 'VU6L3L');
      expect(result.returnMetadata!['airline'], 'Turkish Airlines');
      expect(result.returnMetadata!['flight_number'], 'TK0069 + TK1353');
      expect(result.returnMetadata!['from'], 'BKK');
      expect(result.returnMetadata!['to'], 'LUX');
      expect(result.returnMetadata!['date'], '2026-08-06');
      expect(result.returnMetadata!['departure_time'], '22:45');
      expect(result.returnMetadata!['arrival_date'], '2026-08-07');
      expect(result.returnMetadata!['arrival_time'], '09:25');

      // Nom prévisualisé : « Vol retour Turkish Airlines TK0069 + TK1353 »
      expect(result.returnName,
          'Vol retour Turkish Airlines TK0069 + TK1353');

      expect(result.suspectedRoundTripWithoutReturn, isFalse);
    });

    test('le retour ne ré-écrase PAS un champ déjà rempli côté retour', () {
      // Si Gemini fournit déjà l'airline pour le retour (compagnie
      // différente, codeshare…), on ne l'écrase pas par celle de
      // l'aller.
      final raw = <String, dynamic>{
        'airline': 'Turkish Airlines',
        'reservation_number': 'VU6L3L',
        'is_round_trip': true,
        'return_leg': {
          'airline': 'Lufthansa',
          'reservation_number': 'OTHER123',
          'flight_number': 'LH456',
          'from': 'BKK',
          'to': 'LUX',
          'date': '2026-08-06',
        },
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      expect(result.returnMetadata!['airline'], 'Lufthansa');
      expect(result.returnMetadata!['reservation_number'], 'OTHER123');
    });
  });

  group('analyseRoundTripExtraction — train round-trip', () {
    test('billet AR train hérite company + class', () {
      final raw = <String, dynamic>{
        'company': 'SNCF',
        'class': '1re',
        'train_number': '9580',
        'from': 'Paris Gare de Lyon',
        'to': 'Marseille Saint-Charles',
        'date': '2026-07-15',
        'reservation_number': 'XYZ789',
        'is_round_trip': true,
        'return_leg': {
          'train_number': '9583',
          'from': 'Marseille Saint-Charles',
          'to': 'Paris Gare de Lyon',
          'date': '2026-07-22',
        },
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'train',
      );

      expect(result.returnMetadata!['company'], 'SNCF');
      expect(result.returnMetadata!['class'], '1re');
      expect(result.returnMetadata!['reservation_number'], 'XYZ789');
      expect(result.returnMetadata!['train_number'], '9583');
      expect(result.returnName, 'Train retour SNCF 9583');
    });
  });

  group('analyseRoundTripExtraction — one-way et edge cases', () {
    test('one-way (is_round_trip absent) → returnMetadata null', () {
      final raw = <String, dynamic>{
        'airline': 'Air France',
        'flight_number': 'AF1234',
        'from': 'CDG',
        'to': 'JFK',
        'date': '2026-09-01',
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      expect(result.returnMetadata, isNull);
      expect(result.returnName, isNull);
      expect(result.suspectedRoundTripWithoutReturn, isFalse);
      expect(result.outboundMetadata, raw);
    });

    test('one-way explicite (is_round_trip=false) → returnMetadata null', () {
      final raw = <String, dynamic>{
        'airline': 'Air France',
        'flight_number': 'AF1234',
        'is_round_trip': false,
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      expect(result.returnMetadata, isNull);
      // is_round_trip retiré de la metadata aller
      expect(result.outboundMetadata.containsKey('is_round_trip'), isFalse);
    });

    test('is_round_trip=true SANS return_leg → suspect, warning levé '
        '(acceptance #6)', () {
      final raw = <String, dynamic>{
        'airline': 'Turkish Airlines',
        'flight_number': 'TK1354',
        'is_round_trip': true,
        // pas de return_leg : Gemini a vu un AR mais pas réussi à
        // extraire le retour (photo coupée, mail incomplet…)
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      expect(result.returnMetadata, isNull);
      expect(result.returnName, isNull);
      expect(result.suspectedRoundTripWithoutReturn, isTrue);
    });

    test('return_leg sans flight_number ni airline → nom fallback '
        '"Vol retour"', () {
      final raw = <String, dynamic>{
        'is_round_trip': true,
        'return_leg': {
          'from': 'BKK',
          'to': 'LUX',
          'date': '2026-08-06',
        },
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      expect(result.returnName, 'Vol retour');
    });

    test('V5.1 canonicalisation : IATA → from_city/to_city via '
        'lookupAirport (acceptance Issue 3)', () {
      // Sans canonicalisation, le doc retour aurait juste from="BKK"
      // et to="LUX" — `findDocsLinkedToSegment` matche sur from_city /
      // to_city → orphelin. Le helper doit poser ces clés depuis l'IATA.
      final raw = <String, dynamic>{
        'airline': 'Turkish Airlines',
        'flight_number': 'TK1354',
        'from': 'LUX',
        'to': 'BKK',
        'date': '2026-06-21',
        'reservation_number': 'VU6L3L',
        'is_round_trip': true,
        'return_leg': {
          'flight_number': 'TK0069 + TK1353',
          'from': 'BKK',
          'to': 'LUX',
          'date': '2026-08-06',
          'arrival_date': '2026-08-07',
        },
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );

      // BKK → "Bangkok" et LUX → "Luxembourg" via lookupAirport.
      expect(result.returnMetadata!['from_city'], 'Bangkok');
      expect(result.returnMetadata!['to_city'], 'Luxembourg');
      // Les IATA d'origine sont préservés.
      expect(result.returnMetadata!['from'], 'BKK');
      expect(result.returnMetadata!['to'], 'LUX');
    });

    test('V5.1 canonicalisation : from_city déjà présent → on ne touche '
        'pas', () {
      final raw = <String, dynamic>{
        'is_round_trip': true,
        'return_leg': {
          'from': 'BKK',
          'from_city': 'Bangkok (déjà rempli)',
          'to': 'LUX',
          'date': '2026-08-06',
        },
      };
      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'flight',
      );
      expect(result.returnMetadata!['from_city'], 'Bangkok (déjà rempli)');
    });

    test('V5.1 canonicalisation : nom de ville non-IATA (train) recopié '
        'tel quel comme _city', () {
      final raw = <String, dynamic>{
        'is_round_trip': true,
        'return_leg': {
          'from': 'Marseille Saint-Charles',
          'to': 'Paris Gare de Lyon',
          'date': '2026-07-22',
        },
      };
      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'train',
      );
      expect(result.returnMetadata!['from_city'], 'Marseille Saint-Charles');
      expect(result.returnMetadata!['to_city'], 'Paris Gare de Lyon');
    });

    test('catégorie non transport (hotel) → no-op', () {
      final raw = <String, dynamic>{
        'address': '123 rue X',
        'check_in': '2026-06-21',
        'check_out': '2026-06-25',
        'is_round_trip': true, // ignoré pour hotel
      };

      final result = analyseRoundTripExtraction(
        rawMetadata: raw,
        category: 'hotel',
      );

      expect(result.returnMetadata, isNull);
      // Pour les non-transport, on laisse la metadata brute (ne touche
      // pas même `is_round_trip` qui n'a pas de raison d'y être).
      expect(result.outboundMetadata['is_round_trip'], isTrue);
    });
  });
}
