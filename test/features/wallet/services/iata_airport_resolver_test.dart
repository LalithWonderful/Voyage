/// Tests unitaires `iata_airport_resolver.dart` (Lot A 2026-05-13).
///
/// Couvre :
/// - [resolveAirportByIata] : codes connus (BKK, CDG, LUX, LHR…),
///   normalisation casse, trim, codes invalides, codes inconnus.
/// - [isAirportConsistentWithName] : matching contextuel sur code,
///   ville, nom long de l'aéroport.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/wallet/services/iata_airport_resolver.dart';

void main() {
  group('resolveAirportByIata', () {
    test('BKK → Bangkok Suvarnabhumi avec coords + countryCode TH', () {
      final r = resolveAirportByIata('BKK');
      expect(r, isNotNull);
      expect(r!.iata, 'BKK');
      expect(r.city, 'Bangkok');
      expect(r.name, 'Suvarnabhumi');
      expect(r.countryCode, 'TH');
      // Suvarnabhumi : ~13.69N, 100.75E (source Wikipedia/OpenFlights).
      expect(r.lat, closeTo(13.69, 0.1));
      expect(r.lng, closeTo(100.75, 0.1));
    });

    test('CDG → Paris Charles de Gaulle + countryCode FR', () {
      final r = resolveAirportByIata('CDG');
      expect(r, isNotNull);
      expect(r!.iata, 'CDG');
      expect(r.city, 'Paris');
      expect(r.name, 'Charles de Gaulle');
      expect(r.countryCode, 'FR');
      expect(r.lat, closeTo(49.0, 0.1));
      expect(r.lng, closeTo(2.55, 0.1));
    });

    test('LUX → Luxembourg + countryCode LU', () {
      final r = resolveAirportByIata('LUX');
      expect(r, isNotNull);
      expect(r!.iata, 'LUX');
      expect(r.city, 'Luxembourg');
      expect(r.countryCode, 'LU');
    });

    test('countryCode pour chaque continent (smoke test)', () {
      // Vérifie qu'au moins un aéroport par grande région porte un
      // countryCode valide. Évite qu'un futur ajout fasse régresser
      // silencieusement le champ.
      expect(resolveAirportByIata('LHR')?.countryCode, 'GB');
      expect(resolveAirportByIata('DUB')?.countryCode, 'IE');
      expect(resolveAirportByIata('AMS')?.countryCode, 'NL');
      expect(resolveAirportByIata('FRA')?.countryCode, 'DE');
      expect(resolveAirportByIata('FCO')?.countryCode, 'IT');
      expect(resolveAirportByIata('MAD')?.countryCode, 'ES');
      expect(resolveAirportByIata('JFK')?.countryCode, 'US');
      expect(resolveAirportByIata('YUL')?.countryCode, 'CA');
      expect(resolveAirportByIata('HND')?.countryCode, 'JP');
      expect(resolveAirportByIata('SIN')?.countryCode, 'SG');
      expect(resolveAirportByIata('PQC')?.countryCode, 'VN');
      expect(resolveAirportByIata('DXB')?.countryCode, 'AE');
      expect(resolveAirportByIata('RAK')?.countryCode, 'MA');
      expect(resolveAirportByIata('JNB')?.countryCode, 'ZA');
      expect(resolveAirportByIata('SYD')?.countryCode, 'AU');
      expect(resolveAirportByIata('AKL')?.countryCode, 'NZ');
      expect(resolveAirportByIata('NAN')?.countryCode, 'FJ');
      // DOM-TOM : codes pays spécifiques (pas FR).
      expect(resolveAirportByIata('PTP')?.countryCode, 'GP');
      expect(resolveAirportByIata('RUN')?.countryCode, 'RE');
      expect(resolveAirportByIata('PPT')?.countryCode, 'PF');
    });

    test('lowercase est normalisé en MAJUSCULES', () {
      final r = resolveAirportByIata('bkk');
      expect(r, isNotNull);
      expect(r!.iata, 'BKK');
      expect(r.city, 'Bangkok');
    });

    test('mixed case + espaces sont nettoyés', () {
      final r = resolveAirportByIata('  Cdg  ');
      expect(r, isNotNull);
      expect(r!.iata, 'CDG');
    });

    test('null → null', () {
      expect(resolveAirportByIata(null), isNull);
    });

    test('chaîne vide → null', () {
      expect(resolveAirportByIata(''), isNull);
      expect(resolveAirportByIata('   '), isNull);
    });

    test('longueur != 3 → null (pas de match partiel)', () {
      expect(resolveAirportByIata('BK'), isNull);
      expect(resolveAirportByIata('BKKK'), isNull);
      expect(resolveAirportByIata('B'), isNull);
    });

    test('code inconnu → null (pas de fallback heuristique)', () {
      expect(resolveAirportByIata('ZZZ'), isNull);
      expect(resolveAirportByIata('XYZ'), isNull);
    });
  });

  group('isAirportConsistentWithName', () {
    test('texte contenant le code IATA → true', () {
      final r = resolveAirportByIata('BKK')!;
      expect(isAirportConsistentWithName(r, 'BKK'), isTrue);
      expect(isAirportConsistentWithName(r, 'Aéroport BKK Bangkok'), isTrue);
    });

    test('texte contenant la ville (case-insensible) → true', () {
      final r = resolveAirportByIata('BKK')!;
      expect(isAirportConsistentWithName(r, 'Bangkok'), isTrue);
      expect(
          isAirportConsistentWithName(r, 'aéroport suvarnabhumi de bangkok'),
          isTrue);
    });

    test('texte contenant le nom long de l\'aéroport → true', () {
      final r = resolveAirportByIata('CDG')!;
      expect(
          isAirportConsistentWithName(r, 'Aéroport Charles de Gaulle'),
          isTrue);
      expect(isAirportConsistentWithName(r, 'paris charles de gaulle'),
          isTrue);
    });

    test('texte sans relation avec l\'aéroport → false', () {
      final r = resolveAirportByIata('BKK')!;
      expect(isAirportConsistentWithName(r, 'Aéroport Charles de Gaulle'),
          isFalse);
      expect(isAirportConsistentWithName(r, 'Paris CDG'), isFalse);
    });

    test('texte vide → false', () {
      final r = resolveAirportByIata('BKK')!;
      expect(isAirportConsistentWithName(r, ''), isFalse);
    });
  });
}
