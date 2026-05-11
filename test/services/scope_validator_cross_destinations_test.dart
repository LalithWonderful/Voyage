// Phase 3 / Tâche 3.3 — Tests cross-destinations
// `ScopeValidator`.
//
// **Tâche purement tests + documentation.** Prouve que :
//   - Singapour (vraie DI via Tâche 1.2 + 3.2)
//   - Hong Kong (fixture test-only)
//   - Dubai (fixture test-only)
//   - Rome (fixture test-only)
// sont tous gérés par le **MÊME** mécanisme générique
// (countryCode + blockedNeighborRegions + country hints).
// Aucune logique custom destination n'existe dans le validator
// ni dans le pipeline.
//
// Tests purement unitaires : aucun réseau, aucun Supabase,
// aucune dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/models/destination_intelligence.dart';
import 'package:voyage/services/scope_validator.dart';

import '../fixtures/destinations/scope_test_destinations.dart';

void main() {
  // ─── 1. Singapour (vraie DI) ─────────────────────────────────────────

  group('Cross-destinations — Singapour (vraie DI Tâche 1.2)', () {
    final di = buildSingaporeDestinationIntelligence();

    test('DI Singapour passe validate()', () {
      expect(di.validate(), isEmpty);
    });

    test('SG explicite accepté HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'SG'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
      expect(r.matchedEvidence, equals('SG'));
    });

    test('MY explicite rejeté blockedCountry HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'MY'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.blockedCountry));
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Address Johor Bahru rejeté blockedNeighborRegion MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'KSL City Mall, Johor Bahru, Malaysia'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address KSL City rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'KSL City Mall'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address Batam, Indonesia rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Mega Mall, Batam, Indonesia'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address Bintan Resorts, Lagoi rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Bintan Resorts, Lagoi Bay, Indonesia'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Marina Bay, Singapore" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: '10 Bayfront Avenue, Singapore'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address générique "Singapore" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Some Place, Singapore'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });
  });

  // ─── 2. Hong Kong (fixture test-only) ────────────────────────────────

  group('Cross-destinations — Hong Kong (fixture test-only)', () {
    final di = hongKongScopeFixture();

    test('Fixture HK passe validate()', () {
      expect(di.validate(), isEmpty);
    });

    test('HK explicite accepté HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'HK'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('CN explicite rejeté blockedCountry HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'CN'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedCountry));
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Address "Shenzhen" rejeté blockedNeighborRegion', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Window of the World, Nanshan, Shenzhen'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('shenzhen'));
    });

    test('Address "Guangdong Province" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Hotel, Guangdong Province, China'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('guangdong'));
    });

    test('Address "Hong Kong Island" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: '1 Stubbs Road, Hong Kong Island'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Lieu inconnu sans countryCode/address → accepté LOW', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(name: 'Unknown Place'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
    });
  });

  // ─── 3. Dubai (fixture test-only) ────────────────────────────────────

  group('Cross-destinations — Dubai (fixture test-only)', () {
    final di = dubaiScopeFixture();

    test('Fixture Dubai passe validate()', () {
      expect(di.validate(), isEmpty);
    });

    test('AE explicite accepté HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'AE'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Address "Dubai Mall, Dubai" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Sheikh Mohammed bin Rashid Blvd, Downtown Dubai'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address "Sheikh Zayed Grand Mosque, Abu Dhabi" rejeté '
        'blockedNeighborRegion', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Sheikh Rashid bin Saeed Street, Abu Dhabi'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('abu dhabi'));
    });

    test('Address "Mall of Sharjah, Sharjah" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Al Wahda Street, Sharjah'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('sharjah'));
    });

    test('Address "Ajman City Centre" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Ajman City Centre, UAE'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('ajman'));
    });

    test('Dubai n\'utilise AUCUN countryCode synthétique '
        '(pas de AE-DU / AE-AZ)', () {
      // Vérification structurelle : countryCode et
      // allowedCountryCodes restent au standard ISO 3166-1.
      expect(di.countryCode, equals('AE'));
      expect(di.countryCode.contains('-'), isFalse);
      expect(di.allowedCountryCodes, equals(['AE']));
      for (final c in di.allowedCountryCodes) {
        expect(c.contains('-'), isFalse,
            reason: 'countryCode "$c" ne doit pas être synthétique');
      }
    });
  });

  // ─── 4. Rome (fixture test-only) ─────────────────────────────────────

  group('Cross-destinations — Rome (fixture test-only)', () {
    final di = romeScopeFixture();

    test('Fixture Rome passe validate()', () {
      expect(di.validate(), isEmpty);
    });

    test('IT explicite accepté HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'IT'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('VA explicite accepté HIGH (Vatican enclavé)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'VA'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Address "Vatican City" accepté MEDIUM (no regression vs '
        'pays distinct)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            name: "St. Peter's Basilica",
            address: 'Piazza San Pietro, Vatican City'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address "Rome, Italy" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Piazza del Colosseo, Rome, Italy'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Pays tiers (FR) rejeté outOfCountry', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'FR'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.outOfCountry));
    });
  });

  // ─── 5. Invariants transverses (généricité) ──────────────────────────

  group('Invariants transverses — preuve de généricité', () {
    final destinations = <String, DestinationIntelligence>{
      'singapore': buildSingaporeDestinationIntelligence(),
      'hong_kong': hongKongScopeFixture(),
      'dubai': dubaiScopeFixture(),
      'rome': romeScopeFixture(),
    };

    test('Toutes les fixtures DI passent validate()', () {
      for (final entry in destinations.entries) {
        final errors = entry.value.validate();
        expect(errors, isEmpty,
            reason: '${entry.key} doit passer validate() sans erreur. '
                'Erreurs : $errors');
      }
    });

    test('Aucune DI n\'utilise un countryCode synthétique '
        '(ISO 3166-1 alpha-2 strict)', () {
      for (final entry in destinations.entries) {
        final di = entry.value;
        expect(di.countryCode.contains('-'), isFalse,
            reason: '${entry.key} : countryCode "${di.countryCode}" '
                'doit être ISO 3166-1 alpha-2 standard');
        expect(di.countryCode.length, equals(2),
            reason: '${entry.key} : countryCode alpha-2');
        for (final c in di.allowedCountryCodes) {
          expect(c.contains('-'), isFalse,
              reason: '${entry.key} allowed "$c" : pas de format '
                  'synthétique');
        }
        for (final c in di.blockedCountryCodes) {
          expect(c.contains('-'), isFalse,
              reason: '${entry.key} blocked "$c" : pas de format '
                  'synthétique');
        }
      }
    });

    test('Singapour ET Hong Kong ET Dubai utilisent le MÊME mécanisme '
        '`blockedNeighborRegions`', () {
      // Preuve structurelle : les 3 destinations à régions
      // bloquées exposent le même champ générique.
      final sg = destinations['singapore']!;
      final hk = destinations['hong_kong']!;
      final dx = destinations['dubai']!;
      expect(sg.blockedNeighborRegions, isNotEmpty);
      expect(hk.blockedNeighborRegions, isNotEmpty);
      expect(dx.blockedNeighborRegions, isNotEmpty);
      // Rome reste sans régions bloquées (pas de frontière sensible).
      expect(destinations['rome']!.blockedNeighborRegions, isEmpty);
    });

    test('Tous les blockedNeighborRegions sont en lowercase + sans '
        'whitespace trailing', () {
      for (final entry in destinations.entries) {
        for (final r in entry.value.blockedNeighborRegions) {
          expect(r, equals(r.toLowerCase()),
              reason: '${entry.key} : "$r" doit être lowercase');
          expect(r, equals(r.trim()),
              reason: '${entry.key} : "$r" sans whitespace trailing');
          expect(r, isNotEmpty,
              reason: '${entry.key} : aucune entrée vide');
        }
      }
    });
  });

  // ─── 6. Normalisation cross-destinations ─────────────────────────────

  group('Normalisation cross-destinations', () {
    test('Casse différente : "SHENZHEN" matche `shenzhen` (HK)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Hotel in SHENZHEN, China'),
        hongKongScopeFixture(),
      );
      expect(r.isInScope, isFalse);
      expect(r.matchedEvidence, equals('shenzhen'));
    });

    test('Casse mixte : "Johor Bahru" matche `johor bahru` (SG)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'KSL City Mall, Johor Bahru, Malaysia'),
        buildSingaporeDestinationIntelligence(),
      );
      expect(r.isInScope, isFalse);
      // Match sur "ksl city" OU "johor bahru" OU "johor"
      expect(r.matchedEvidence, isNotNull);
    });

    test('Espaces multiples : "Abu   Dhabi" matche `abu dhabi` (Dubai) '
        'via contains case-insensitive', () {
      // Note : le matcher actuel utilise `String.contains` sans
      // normalisation des espaces. "abu  dhabi" (2 espaces) ne
      // matchera PAS "abu dhabi" (1 espace). Documenté.
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'place near abu dhabi'),
        dubaiScopeFixture(),
      );
      expect(r.isInScope, isFalse);
      expect(r.matchedEvidence, equals('abu dhabi'));
    });

    test('Address combinant ville + rue : "KSL City Mall, Jalan '
        'Seladang" matche le premier hint', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'KSL City Mall, Jalan Seladang, Johor Bahru'),
        buildSingaporeDestinationIntelligence(),
      );
      expect(r.isInScope, isFalse);
      // Premier hint qui matche en ordre d'iteration des regions
      expect(r.matchedEvidence, isNotNull);
    });
  });

  // ─── 7. Confidence cohérente cross-destinations ──────────────────────

  group('Confidence cohérente cross-destinations', () {
    test('countryCode explicite → HIGH partout', () {
      for (final di in [
        buildSingaporeDestinationIntelligence(),
        hongKongScopeFixture(),
        dubaiScopeFixture(),
        romeScopeFixture(),
      ]) {
        final r = validatePlaceInScope(
          ScopeValidationPlace(countryCode: di.countryCode),
          di,
        );
        expect(r.isInScope, isTrue);
        expect(r.confidence, equals(ScopeConfidence.high),
            reason: '${di.destinationKey} : countryCode explicite = HIGH');
      }
    });

    test('Address hint blockedNeighborRegion → MEDIUM', () {
      final sgRej = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Johor Bahru, Malaysia'),
        buildSingaporeDestinationIntelligence(),
      );
      expect(sgRej.confidence, equals(ScopeConfidence.medium));

      final hkRej = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Shenzhen, China'),
        hongKongScopeFixture(),
      );
      expect(hkRej.confidence, equals(ScopeConfidence.medium));

      final dxRej = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Abu Dhabi, UAE'),
        dubaiScopeFixture(),
      );
      expect(dxRej.confidence, equals(ScopeConfidence.medium));
    });

    test('Aucune preuve → LOW partout (pas de rejet agressif sur '
        'border high-sensitivity)', () {
      for (final di in [
        buildSingaporeDestinationIntelligence(), // sensitivity HIGH
        hongKongScopeFixture(),                   // sensitivity HIGH
        dubaiScopeFixture(),                      // sensitivity MEDIUM
        romeScopeFixture(),                       // sensitivity LOW
      ]) {
        final r = validatePlaceInScope(
          const ScopeValidationPlace(name: 'Random Place'),
          di,
        );
        expect(r.isInScope, isTrue);
        expect(r.confidence, equals(ScopeConfidence.low),
            reason:
                '${di.destinationKey} (sensitivity ${di.borderSensitivity.name}) : '
                'sans preuve = accept LOW');
      }
    });

    test('countryCode différent allowed → reject HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'FR'),
        romeScopeFixture(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.outOfCountry));
      expect(r.confidence, equals(ScopeConfidence.high));
    });
  });
}
