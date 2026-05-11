// Phase 3 / Tâche 3.1 — Tests unitaires scope_validator.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/models/destination_intelligence.dart';
import 'package:voyage/services/scope_validator.dart';

// ─── Helpers — DI fixtures ────────────────────────────────────────────

DestinationIntelligence _singaporeDi({
  BorderSensitivity sensitivity = BorderSensitivity.high,
}) {
  return DestinationIntelligence(
    destinationKey: 'singapore',
    canonicalCenter: const GeoPoint(lat: 1.3521, lng: 103.8198),
    countryCode: 'SG',
    allowedCountryCodes: const ['SG'],
    blockedCountryCodes: const ['MY', 'ID'],
    borderSensitivity: sensitivity,
    tripMode: TripMode.megaCity,
    zones: [
      const TouristZone(
        name: 'Marina Bay',
        center: GeoPoint(lat: 1.283, lng: 103.860),
        radiusKm: 2,
        theme: 'waterfront',
      ),
    ],
    anchors: [
      const DestinationAnchor(
        name: 'Gardens by the Bay',
        placeQueries: ['Gardens by the Bay'],
        importance: 5,
        recommendedDuration: Duration(minutes: 180),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 5,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: true,
    ),
  );
}

DestinationIntelligence _hongKongDi() {
  return DestinationIntelligence(
    destinationKey: 'hong_kong',
    canonicalCenter: const GeoPoint(lat: 22.302, lng: 114.177),
    countryCode: 'HK',
    allowedCountryCodes: const ['HK'],
    blockedCountryCodes: const ['CN'],
    borderSensitivity: BorderSensitivity.high,
    tripMode: TripMode.megaCity,
    zones: [
      const TouristZone(
        name: 'Central',
        center: GeoPoint(lat: 22.281, lng: 114.158),
        radiusKm: 2,
        theme: 'urban_core',
      ),
    ],
    anchors: [
      const DestinationAnchor(
        name: 'Victoria Peak',
        placeQueries: ['Victoria Peak'],
        importance: 5,
        recommendedDuration: Duration(minutes: 120),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 5,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: true,
    ),
  );
}

DestinationIntelligence _romeDi() {
  return DestinationIntelligence(
    destinationKey: 'rome',
    canonicalCenter: const GeoPoint(lat: 41.9028, lng: 12.4964),
    countryCode: 'IT',
    allowedCountryCodes: const ['IT', 'VA'],
    blockedCountryCodes: const [],
    borderSensitivity: BorderSensitivity.low,
    tripMode: TripMode.cityBreak,
    zones: [
      const TouristZone(
        name: 'Centro Storico',
        center: GeoPoint(lat: 41.901, lng: 12.481),
        radiusKm: 2,
        theme: 'historic',
      ),
    ],
    anchors: [
      const DestinationAnchor(
        name: 'Colosseum',
        placeQueries: ['Colosseum'],
        importance: 5,
        recommendedDuration: Duration(minutes: 90),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 10,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: false,
    ),
  );
}

DestinationIntelligence _dubaiDi() {
  return DestinationIntelligence(
    destinationKey: 'dubai',
    canonicalCenter: const GeoPoint(lat: 25.276, lng: 55.296),
    countryCode: 'AE',
    allowedCountryCodes: const ['AE'],
    blockedCountryCodes: const [],
    borderSensitivity: BorderSensitivity.medium,
    tripMode: TripMode.megaCity,
    zones: [
      const TouristZone(
        name: 'Downtown',
        center: GeoPoint(lat: 25.197, lng: 55.274),
        radiusKm: 2,
        theme: 'urban_core',
      ),
    ],
    anchors: [
      const DestinationAnchor(
        name: 'Burj Khalifa',
        placeQueries: ['Burj Khalifa'],
        importance: 5,
        recommendedDuration: Duration(minutes: 120),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 10,
      dominantMode: 'taxi',
      hasMetro: true,
      hasMetroAnchorLogic: false,
    ),
  );
}

void main() {
  // ─── 1. CountryCode explicite ────────────────────────────────────────

  group('CountryCode explicite', () {
    final di = _singaporeDi();

    test('SG accepté avec confidence HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'SG'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
      expect(r.matchedEvidence, equals('SG'));
      expect(r.rejectionReason, isNull);
    });

    test('MY rejeté blockedCountry HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'MY'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.blockedCountry));
      expect(r.confidence, equals(ScopeConfidence.high));
      expect(r.matchedEvidence, equals('MY'));
    });

    test('ID rejeté blockedCountry HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'ID'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.blockedCountry));
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('FR (tiers non listé) rejeté outOfCountry HIGH', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'FR'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.outOfCountry));
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Normalisation lowercase → uppercase', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'sg'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.matchedEvidence, equals('SG'));
    });

    test('Whitespace trim', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: '  SG  '),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.matchedEvidence, equals('SG'));
    });

    test('CountryCode défensif : si dans blocked ET allowed, blocked '
        'gagne', () {
      final ambiguous = DestinationIntelligence(
        destinationKey: 'test',
        canonicalCenter: const GeoPoint(lat: 0, lng: 0),
        countryCode: 'XX',
        allowedCountryCodes: const ['XX', 'YY'],
        blockedCountryCodes: const ['YY'], // YY est listé dans les deux
        borderSensitivity: BorderSensitivity.medium,
        tripMode: TripMode.cityBreak,
        zones: [
          const TouristZone(
            name: 'Zone',
            center: GeoPoint(lat: 0, lng: 0),
            radiusKm: 1,
            theme: 'generic',
          ),
        ],
        anchors: [
          const DestinationAnchor(
            name: 'Anchor',
            placeQueries: ['Anchor'],
            importance: 3,
            recommendedDuration: Duration(minutes: 60),
          ),
        ],
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'YY'),
        ambiguous,
      );
      // Stratégie défensive : blocked gagne.
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.blockedCountry));
    });
  });

  // ─── 2. Fallback adresse ─────────────────────────────────────────────

  group('Fallback adresse — Singapour', () {
    final di = _singaporeDi();

    test('Address mentioning "Singapore" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: '10 Bayfront Avenue, Singapore 018956'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
      expect(r.matchedEvidence, equals('singapore'));
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

    test('Address "Batam Center, Indonesia" rejeté '
        'blockedNeighborRegion', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Batam Center, Indonesia'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Bintan Resorts, Lagoi, Indonesia" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Bintan Resorts, Lagoi, Indonesia'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address ambigüe (uniquement nom de rue) accepté LOW', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: '123 Random Street, Apt 5B'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
      expect(r.matchedEvidence, isNull);
    });

    test('Blocked priorité sur allowed même quand les deux matchent', () {
      // L'adresse mentionne Singapore ET Malaysia
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Border between Singapore and Malaysia, Johor'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });
  });

  // ─── 3. Hong Kong ────────────────────────────────────────────────────

  group('Hong Kong DI', () {
    final di = _hongKongDi();

    test('HK explicite accepté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'HK'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('CN explicite rejeté blockedCountry', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'CN'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason, equals(ScopeRejectionReason.blockedCountry));
    });

    test('Address "Shenzhen, Guangdong, China" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'OCT-LOFT, Shenzhen, Guangdong, China'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Guangdong Province" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Hotel, Guangdong Province'),
        di,
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address Hong Kong accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: '1 Stubbs Road, Hong Kong'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });
  });

  // ─── 4. Rome ─────────────────────────────────────────────────────────

  group('Rome DI', () {
    final di = _romeDi();

    test('IT explicite accepté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'IT'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('VA explicite accepté (autorisé même si non countryCode '
        'principal)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'VA'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Address Vatican accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            name: "St. Peter's Basilica",
            address: 'Piazza San Pietro, Vatican City'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address Rome accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Piazza del Colosseo, Roma'),
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

  // ─── 5. Dubai — point ouvert régions internes AE ─────────────────────

  group('Dubai DI — point ouvert régions internes AE', () {
    final di = _dubaiDi();

    test('AE explicite accepté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(countryCode: 'AE'),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });

    test('Address "Abu Dhabi" : pas rejet en 3.1 car AE allowed et '
        'régions internes pas modélisées', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Sheikh Zayed Grand Mosque, Abu Dhabi'),
        di,
      );
      // Sans `blockedNeighborRegions` champ DI : "abu dhabi" match
      // l'allowed hint AE → accepté MEDIUM. Documenté limitation.
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
    });
  });

  // ─── 6. Pas de countryCode et pas d'adresse claire ───────────────────

  group('Aucune preuve', () {
    final diHigh = _singaporeDi();
    final diLow = _romeDi();

    test('No countryCode, no address → accepté LOW', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(name: 'Mystery Place'),
        diHigh,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
      expect(r.matchedEvidence, isNull);
    });

    test('Empty fields, borderSensitivity HIGH → toujours accepté '
        'LOW (pas de rejet agressif)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(),
        diHigh,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
      expect(r.rejectionReason, isNull);
    });

    test('borderSensitivity LOW + no evidence → également accepté LOW',
        () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(name: 'X', address: '   '),
        diLow,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
    });

    test('Whitespace-only countryCode traité comme absent', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            countryCode: '   ', address: 'Marina Bay Sands, Singapore'),
        diHigh,
      );
      expect(r.isInScope, isTrue);
      // Fallback à l'adresse → MEDIUM
      expect(r.confidence, equals(ScopeConfidence.medium));
    });
  });

  // ─── 7. blockedNeighborRegions (Phase 3 / Tâche 3.2) ─────────────────

  group('blockedNeighborRegions — DI driven', () {
    // Singapour avec blockedNeighborRegions explicitement renseigné.
    DestinationIntelligence sgWithRegions() => DestinationIntelligence(
          destinationKey: 'singapore',
          canonicalCenter: const GeoPoint(lat: 1.3521, lng: 103.8198),
          countryCode: 'SG',
          allowedCountryCodes: const ['SG'],
          blockedCountryCodes: const ['MY', 'ID'],
          blockedNeighborRegions: const [
            'johor bahru',
            'johor',
            'ksl city',
            'komtar',
            'jbcc',
            'batam',
            'bintan',
            'lagoi',
            'tanjung pinang',
            'kepri',
          ],
          borderSensitivity: BorderSensitivity.high,
          tripMode: TripMode.megaCity,
          zones: [
            const TouristZone(
              name: 'Marina Bay',
              center: GeoPoint(lat: 1.283, lng: 103.860),
              radiusKm: 2,
              theme: 'waterfront',
            ),
          ],
          anchors: [
            const DestinationAnchor(
              name: 'Gardens',
              placeQueries: ['Gardens'],
              importance: 5,
              recommendedDuration: Duration(minutes: 180),
            ),
          ],
          transportRules: const TransportRules(
            maxTransitionKm: 5,
            dominantMode: 'public_transport',
            hasMetro: true,
            hasMetroAnchorLogic: true,
          ),
        );

    test('Address "KSL City Mall, Johor Bahru" → rejet '
        'blockedNeighborRegion (matche ksl city OU johor bahru)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'KSL City Mall, Johor Bahru, Malaysia'),
        sgWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address "Batam, Indonesia" rejeté via blockedNeighborRegions',
        () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Mega Mall, Batam, Indonesia'),
        sgWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('batam'));
    });

    test('Address "Tanjung Pinang, Kepri" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Hotel, Tanjung Pinang, Kepri Province'),
        sgWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Lagoi, Bintan" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Bintan Resort, Lagoi Bay'),
        sgWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Name contient "Komtar" sans address → rejet via name', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(name: 'Komtar JBCC Shopping'),
        sgWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Marina Bay Sands, Singapore" reste accepté MEDIUM '
        '(pas de match dans blockedNeighborRegions)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: '10 Bayfront Avenue, Singapore'),
        sgWithRegions(),
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.medium));
      // matched via country hints (allowed), pas via region
      expect(r.matchedEvidence, equals('singapore'));
    });

    test('CountryCode SG explicite prime sur blockedNeighborRegions '
        '(Étape 1 court-circuite Étape 2)', () {
      // Cas pathologique : Place explicitement en SG mais avec
      // une adresse mentionnant "Johor". Le countryCode étant
      // une preuve forte, on accepte HIGH sans vérifier les
      // régions bloquées.
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            countryCode: 'SG',
            address: 'Strange Place near Johor border, Singapore'),
        sgWithRegions(),
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
      expect(r.matchedEvidence, equals('SG'));
    });

    test('Singapour DI sans blockedNeighborRegions → fallback aux '
        'country hints (Étape 3)', () {
      final sgNoRegions = DestinationIntelligence(
        destinationKey: 'singapore',
        canonicalCenter: const GeoPoint(lat: 1.3521, lng: 103.8198),
        countryCode: 'SG',
        allowedCountryCodes: const ['SG'],
        blockedCountryCodes: const ['MY', 'ID'],
        // blockedNeighborRegions intentionnellement vide
        borderSensitivity: BorderSensitivity.high,
        tripMode: TripMode.megaCity,
        zones: [
          const TouristZone(
            name: 'Z',
            center: GeoPoint(lat: 0, lng: 0),
            radiusKm: 1,
            theme: 'generic',
          ),
        ],
        anchors: [
          const DestinationAnchor(
            name: 'A',
            placeQueries: ['A'],
            importance: 3,
            recommendedDuration: Duration(minutes: 60),
          ),
        ],
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      // Adresse contient "ksl city" qui n'est PAS dans
      // _kCountryHints → fallback aux hints génériques MY → match
      // sur "malaysia" si présent dans l'adresse.
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'KSL City Mall, Johor Bahru, Malaysia'),
        sgNoRegions,
      );
      // Match sur 'malaysia' OU 'johor bahru' via _kCountryHints
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });
  });

  // ─── 8. Dubai avec blockedNeighborRegions — résolution point ouvert 3.1

  group('Dubai DI avec blockedNeighborRegions (résolution 3.1)', () {
    // Phase 3 / Tâche 3.2 — l'abstraction `blockedNeighborRegions`
    // permet enfin de bloquer Abu Dhabi / Sharjah / Ajman tout en
    // gardant `AE` allowed. Aucune logique custom dans le service.
    DestinationIntelligence dubaiWithRegions() =>
        DestinationIntelligence(
          destinationKey: 'dubai',
          canonicalCenter: const GeoPoint(lat: 25.276, lng: 55.296),
          countryCode: 'AE',
          allowedCountryCodes: const ['AE'],
          blockedCountryCodes: const [],
          blockedNeighborRegions: const [
            'abu dhabi',
            'sharjah',
            'ajman',
          ],
          borderSensitivity: BorderSensitivity.medium,
          tripMode: TripMode.megaCity,
          zones: [
            const TouristZone(
              name: 'Downtown',
              center: GeoPoint(lat: 25.197, lng: 55.274),
              radiusKm: 2,
              theme: 'urban_core',
            ),
          ],
          anchors: [
            const DestinationAnchor(
              name: 'Burj Khalifa',
              placeQueries: ['Burj Khalifa'],
              importance: 5,
              recommendedDuration: Duration(minutes: 120),
            ),
          ],
          transportRules: const TransportRules(
            maxTransitionKm: 10,
            dominantMode: 'taxi',
            hasMetro: true,
            hasMetroAnchorLogic: false,
          ),
        );

    test('Address "Burj Khalifa, Dubai" accepté MEDIUM', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Sheikh Mohammed bin Rashid Blvd, Dubai'),
        dubaiWithRegions(),
      );
      expect(r.isInScope, isTrue);
      // Match via country hint allowed
      expect(r.confidence, equals(ScopeConfidence.medium));
    });

    test('Address "Sheikh Zayed Grand Mosque, Abu Dhabi" rejeté '
        'blockedNeighborRegion (résolution point ouvert 3.1)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Sheikh Zayed Grand Mosque, Abu Dhabi'),
        dubaiWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(r.matchedEvidence, equals('abu dhabi'));
    });

    test('Address "Mall of Sharjah, Sharjah" rejeté '
        'blockedNeighborRegion', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            address: 'Mall of Sharjah, Sharjah, UAE'),
        dubaiWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Ajman City Centre" rejeté', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(address: 'Ajman City Centre, UAE'),
        dubaiWithRegions(),
      );
      expect(r.isInScope, isFalse);
      expect(r.rejectionReason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('CountryCode AE explicite → accept HIGH même si address '
        'mentionne Abu Dhabi (countryCode prime)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            countryCode: 'AE',
            address: 'Touristic spot near Abu Dhabi border'),
        dubaiWithRegions(),
      );
      // CountryCode explicite (Étape 1) court-circuite tout.
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });
  });

  // ─── 9. Robustesse null / vide ───────────────────────────────────────

  group('Robustesse null / vide', () {
    final di = _singaporeDi();

    test('Tous les champs null ne crashent pas', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
    });

    test('Strings vides traitées comme absentes', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            name: '', address: '', countryCode: ''),
        di,
      );
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.low));
    });

    test('Lat/lng fournis mais inutilisés en 3.1 (réservés)', () {
      final r = validatePlaceInScope(
        const ScopeValidationPlace(
            lat: 1.3521, lng: 103.8198, countryCode: 'SG'),
        di,
      );
      // lat/lng ne changent rien à la décision en 3.1.
      expect(r.isInScope, isTrue);
      expect(r.confidence, equals(ScopeConfidence.high));
    });
  });
}
