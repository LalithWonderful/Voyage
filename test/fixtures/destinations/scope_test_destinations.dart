// Phase 3 / Tâche 3.3 — Fixtures `DestinationIntelligence`
// **test-only** pour valider la généricité de `ScopeValidator`
// sur plusieurs destinations.
//
// **Important** : ces fixtures NE doivent PAS migrer vers
// `lib/data/destinations/` en Tâche 3.3. La création des
// fichiers complets Hong Kong / Dubai / Rome est explicitement
// reportée à Phase 6 (cf. plan refonte). Ici, on prouve seulement
// que le validator gère correctement ces destinations dès que les
// données existent — pas qu'elles soient packagées.
//
// **Critère de présence test-only** :
//   - le fichier vit sous `test/fixtures/`
//   - aucun import depuis `lib/`
//   - les fixtures sont **minimalistes** (1 zone + 1 anchor +
//     transportRules suffisants pour passer `validate()`)
//   - le seul vrai contenu pertinent au test est
//     `allowedCountryCodes` / `blockedCountryCodes` /
//     `blockedNeighborRegions`

import 'package:voyage/models/destination_intelligence.dart';

/// Hong Kong — frontière critique avec la Chine continentale.
/// blockedCountryCodes : `CN` (preuve forte sur countryCode).
/// blockedNeighborRegions : `shenzhen`, `guangdong` (preuve
/// heuristique sur address/name).
DestinationIntelligence hongKongScopeFixture() {
  return const DestinationIntelligence(
    destinationKey: 'hong_kong',
    canonicalCenter: GeoPoint(lat: 22.302, lng: 114.177),
    countryCode: 'HK',
    allowedCountryCodes: ['HK'],
    blockedCountryCodes: ['CN'],
    blockedNeighborRegions: [
      'shenzhen',
      'guangdong',
    ],
    borderSensitivity: BorderSensitivity.high,
    tripMode: TripMode.megaCity,
    zones: [
      TouristZone(
        name: 'Central',
        center: GeoPoint(lat: 22.281, lng: 114.158),
        radiusKm: 2,
        theme: 'urban_core',
      ),
    ],
    anchors: [
      DestinationAnchor(
        name: 'Victoria Peak',
        placeQueries: ['Victoria Peak'],
        importance: 5,
        recommendedDuration: Duration(minutes: 120),
      ),
    ],
    transportRules: TransportRules(
      maxTransitionKm: 5,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: true,
    ),
  );
}

/// Dubai — émirat parmi les 7 UAE. `AE` allowed mais les autres
/// émirats (Abu Dhabi, Sharjah, Ajman) sont **hors scope**.
/// blockedCountryCodes vide (même pays).
/// blockedNeighborRegions résout le point ouvert Tâche 3.1.
DestinationIntelligence dubaiScopeFixture() {
  return const DestinationIntelligence(
    destinationKey: 'dubai',
    canonicalCenter: GeoPoint(lat: 25.276, lng: 55.296),
    countryCode: 'AE',
    allowedCountryCodes: ['AE'],
    blockedCountryCodes: [],
    blockedNeighborRegions: [
      'abu dhabi',
      'sharjah',
      'ajman',
    ],
    borderSensitivity: BorderSensitivity.medium,
    tripMode: TripMode.megaCity,
    zones: [
      TouristZone(
        name: 'Downtown',
        center: GeoPoint(lat: 25.197, lng: 55.274),
        radiusKm: 2,
        theme: 'urban_core',
      ),
    ],
    anchors: [
      DestinationAnchor(
        name: 'Burj Khalifa',
        placeQueries: ['Burj Khalifa'],
        importance: 5,
        recommendedDuration: Duration(minutes: 120),
      ),
    ],
    transportRules: TransportRules(
      maxTransitionKm: 10,
      dominantMode: 'taxi',
      hasMetro: true,
      hasMetroAnchorLogic: false,
    ),
  );
}

/// Rome — pas de frontière sensible. blockedCountryCodes vide,
/// blockedNeighborRegions vide. `VA` explicitement allowed
/// (enclave catholique, considérée intra-scope pour un voyage
/// Rome). Exemple destination "low-risk".
DestinationIntelligence romeScopeFixture() {
  return const DestinationIntelligence(
    destinationKey: 'rome',
    canonicalCenter: GeoPoint(lat: 41.9028, lng: 12.4964),
    countryCode: 'IT',
    allowedCountryCodes: ['IT', 'VA'],
    blockedCountryCodes: [],
    blockedNeighborRegions: [],
    borderSensitivity: BorderSensitivity.low,
    tripMode: TripMode.historicCity,
    zones: [
      TouristZone(
        name: 'Centro Storico',
        center: GeoPoint(lat: 41.901, lng: 12.481),
        radiusKm: 2,
        theme: 'historic',
      ),
    ],
    anchors: [
      DestinationAnchor(
        name: 'Colosseum',
        placeQueries: ['Colosseum'],
        importance: 5,
        recommendedDuration: Duration(minutes: 90),
      ),
    ],
    transportRules: TransportRules(
      maxTransitionKm: 10,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: false,
    ),
  );
}
