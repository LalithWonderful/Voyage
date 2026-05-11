# Phase 3 / Tâche 3.3 — Tests cross-destinations `DestinationScope`

## Objectif

Valider que la logique `DestinationScope` (livrée en Tâche 3.2)
est **véritablement générique** et fonctionne sans logique
custom sur 4 destinations sensibles couvrant les cas types :

| Destination | Cas type | Mécanisme prépondérant |
|-------------|----------|------------------------|
| Singapour | Frontière 2 pays (MY + ID) | `blockedCountryCodes` + `blockedNeighborRegions` |
| Hong Kong | Frontière intra-pays politique (CN) | `blockedCountryCodes` + `blockedNeighborRegions` |
| Dubai | Émirat parmi 7 dans même pays (AE) | `blockedNeighborRegions` seul |
| Rome | Enclave étrangère intra-zone (VA) | `allowedCountryCodes` multi |

**Tâche purement tests + doc.** 0 fichier de production modifié.
Le flag `useDestinationScope` reste OFF par défaut.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production** : tâche
  test-only, pas de production.
- **7 — Étendre l'existant** : aucune nouvelle logique. Les
  fixtures HK/Dubai/Rome restent **test-only** (pas de fichier
  dans `lib/data/destinations/` — création future Phase 6).

## Fichiers créés

- **`test/fixtures/destinations/scope_test_destinations.dart`**
  *(~135 lignes)* — fixtures minimalistes Hong Kong / Dubai /
  Rome (1 zone + 1 anchor + transportRules + champs scope
  pertinents). Validées par `validate()`. Aucun import depuis
  `lib/data/destinations/`.
- **`test/services/scope_validator_cross_destinations_test.dart`**
  *(~445 lignes)* — **41 tests** en 7 groupes.
- **`docs/migrations/phase3_task3_3.md`** *(ce document)*.

## Fichiers de production NON modifiés

- `lib/services/scope_validator.dart` intact (Tâche 3.2)
- `lib/models/destination_intelligence.dart` intact
- `lib/data/destinations/singapore.dart` intact
- `lib/data/destinations/destination_intelligence_registry.dart` intact
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/config/feature_flags.dart` intact
- **Aucun fichier `lib/data/destinations/<dest>.dart` créé**
  pour HK / Dubai / Rome (création reportée Phase 6).

## Fixtures test-only

Les 3 fixtures HK/Dubai/Rome vivent uniquement sous
`test/fixtures/`. Critères respectés :
- Aucun import depuis `lib/` (autre que `models/`)
- Minimalistes : 1 zone + 1 anchor + transportRules valides
- Seul contenu test-pertinent : `allowedCountryCodes`,
  `blockedCountryCodes`, `blockedNeighborRegions`,
  `borderSensitivity`, `tripMode`
- Passent toutes `validate()` (vérifié par test)

```dart
// test/fixtures/destinations/scope_test_destinations.dart
DestinationIntelligence hongKongScopeFixture();
DestinationIntelligence dubaiScopeFixture();
DestinationIntelligence romeScopeFixture();
```

Singapour utilise la **vraie** DI via
`buildSingaporeDestinationIntelligence()` (Tâche 1.2 + 3.2).

## Cas Singapour (vraie DI, 9 tests)

`buildSingaporeDestinationIntelligence()` :
- `allowedCountryCodes: ['SG']`
- `blockedCountryCodes: ['MY', 'ID']`
- `blockedNeighborRegions: ['johor bahru', 'johor', 'ksl city',
  'komtar', 'jbcc', 'batam', 'bintan', 'lagoi', 'tanjung pinang',
  'kepri']`

| Test | Résultat |
|------|----------|
| DI passe `validate()` | ✅ |
| countryCode `SG` | accept HIGH |
| countryCode `MY` | reject `blockedCountry` HIGH |
| address `Johor Bahru, Malaysia` | reject `blockedNeighborRegion` MEDIUM |
| address `KSL City Mall` | reject |
| address `Batam, Indonesia` | reject |
| address `Bintan Resorts, Lagoi` | reject |
| address `Marina Bay, Singapore` | accept MEDIUM |
| address générique `Singapore` | accept MEDIUM |

## Cas Hong Kong (fixture test-only, 7 tests)

`hongKongScopeFixture()` :
- `allowedCountryCodes: ['HK']`
- `blockedCountryCodes: ['CN']`
- `blockedNeighborRegions: ['shenzhen', 'guangdong']`
- `borderSensitivity: high`

| Test | Résultat |
|------|----------|
| Fixture passe `validate()` | ✅ |
| countryCode `HK` | accept HIGH |
| countryCode `CN` | reject `blockedCountry` HIGH |
| address `Shenzhen, China` | reject `blockedNeighborRegion` (evidence: shenzhen) |
| address `Guangdong Province` | reject (evidence: guangdong) |
| address `Hong Kong Island` | accept MEDIUM |
| Lieu sans countryCode/address | accept LOW |

## Cas Dubai (fixture test-only, 7 tests)

`dubaiScopeFixture()` :
- `allowedCountryCodes: ['AE']`
- `blockedCountryCodes: []` (même pays)
- `blockedNeighborRegions: ['abu dhabi', 'sharjah', 'ajman']`
- `borderSensitivity: medium`

| Test | Résultat |
|------|----------|
| Fixture passe `validate()` | ✅ |
| countryCode `AE` | accept HIGH |
| address `Downtown Dubai` | accept MEDIUM (hint `dubai`) |
| address `Sheikh Zayed Grand Mosque, Abu Dhabi` | reject (evidence: abu dhabi) |
| address `Al Wahda Street, Sharjah` | reject (evidence: sharjah) |
| address `Ajman City Centre` | reject (evidence: ajman) |
| **AUCUN countryCode synthétique** (`AE-DU`/`AE-AZ`) | ✅ vérifié structurellement |

**Résolution du point ouvert Tâche 3.1** : Dubai est géré par
`blockedNeighborRegions` standard, sans logique custom ni
countryCode non-standard.

## Cas Rome / Vatican (fixture test-only, 6 tests)

`romeScopeFixture()` :
- `allowedCountryCodes: ['IT', 'VA']`
- `blockedCountryCodes: []`
- `blockedNeighborRegions: []`
- `borderSensitivity: low`

| Test | Résultat |
|------|----------|
| Fixture passe `validate()` | ✅ |
| countryCode `IT` | accept HIGH |
| countryCode `VA` | accept HIGH (Vatican enclavé, allowed) |
| address `Piazza San Pietro, Vatican City` | accept MEDIUM |
| address `Rome, Italy` | accept MEDIUM |
| countryCode `FR` (tiers) | reject `outOfCountry` HIGH |

**No regression Rome/Vatican** : le Vatican (`VA`, pays ISO
distinct) est accepté grâce au `allowedCountryCodes` multi-pays.

## Invariants transverses (4 tests)

Preuve de **généricité** du mécanisme :

| Invariant | Vérification |
|-----------|--------------|
| Toutes les fixtures DI passent `validate()` | Iter sur les 4 destinations |
| Aucun countryCode synthétique (ISO 3166-1 alpha-2 strict) | `length == 2`, pas de `-` dans aucun code |
| SG, HK, Dubai utilisent **le même** champ `blockedNeighborRegions` | Présence simultanée du champ avec entrées |
| Rome reste sans régions bloquées (pas de frontière sensible) | `isEmpty` vérifié |
| Tous les `blockedNeighborRegions` sont en lowercase + sans whitespace trailing | Iter sur toutes les entrées |

## Normalisation cross-destinations (4 tests)

| Test | Résultat |
|------|----------|
| Casse différente `SHENZHEN` → `shenzhen` HK | ✅ |
| Casse mixte `Johor Bahru` → `johor bahru` SG | ✅ |
| `abu dhabi` (1 espace) match `abu dhabi` Dubai | ✅ |
| Address combinée `KSL City Mall, Jalan Seladang, Johor Bahru` matche le premier hint | ✅ |

**Limite documentée** : `String.contains` n'effectue pas de
normalisation des espaces multiples (`abu   dhabi` ≠ `abu dhabi`).
Cohérent avec `isCandidateAddressBlocked` legacy.

## Confidence cohérente cross-destinations (4 tests)

| Cas | Confidence attendu | Vérifié sur destinations |
|-----|-------------------|--------------------------|
| countryCode explicite allowed | HIGH | SG, HK, Dubai, Rome |
| Address hint `blockedNeighborRegion` | MEDIUM | SG, HK, Dubai |
| Aucune preuve (border high/medium/low) | LOW partout | SG, HK, Dubai, Rome |
| countryCode tiers vs allowed | reject HIGH `outOfCountry` | Rome |

**Confirmation Tâche 3.1** : `borderSensitivity.high` ne
provoque PAS de rejet sans preuve. Vérifié sur Singapour (high)
ET Hong Kong (high) : accept LOW si aucune evidence.

## Preuve de généricité

Le test suivant prouve **structurellement** que les 3
destinations à régions bloquées utilisent le même mécanisme :

```dart
test('Singapour ET Hong Kong ET Dubai utilisent le MÊME mécanisme '
    '`blockedNeighborRegions`', () {
  final sg = buildSingaporeDestinationIntelligence();
  final hk = hongKongScopeFixture();
  final dx = dubaiScopeFixture();
  expect(sg.blockedNeighborRegions, isNotEmpty);
  expect(hk.blockedNeighborRegions, isNotEmpty);
  expect(dx.blockedNeighborRegions, isNotEmpty);
});
```

Et que **aucun countryCode synthétique** n'est utilisé :

```dart
test('Aucune DI n\'utilise un countryCode synthétique '
    '(ISO 3166-1 alpha-2 strict)', () {
  for (final entry in destinations.entries) {
    final di = entry.value;
    expect(di.countryCode.contains('-'), isFalse);
    expect(di.countryCode.length, equals(2));
  }
});
```

## Ce qui n'est volontairement PAS fait

- ❌ Création de `lib/data/destinations/hong_kong.dart`
- ❌ Création de `lib/data/destinations/dubai.dart`
- ❌ Création de `lib/data/destinations/rome.dart`
- ❌ Extension de `destination_intelligence_registry.dart` à
  HK/Dubai/Rome
- ❌ Activation du flag `useDestinationScope` par défaut
- ❌ Suppression des `blockedAddressPatterns` legacy
- ❌ Modification du pipeline / sélecteur / validator / modèle
- ❌ Création de `DayTemplate` (Phase 4)
- ❌ Test d'intégration runtime cross-destinations (le pipeline
  pour HK/Dubai/Rome nécessiterait MetroProfile + blueprint +
  données complètes — Phase 6)

## Confirmation invariants

- ✅ `FeatureFlags.useDestinationScope` reste OFF par défaut
- ✅ Aucun fichier production modifié
- ✅ Toutes les fixtures DI passent `validate()`
- ✅ Aucun countryCode synthétique introduit
- ✅ Mécanisme strictement générique (preuve par structure)
- ✅ Pipeline production intact

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  0 nouveau warning/error.

flutter test
  859 tests verts (818 Tâche 3.2 + 41 nouveaux Tâche 3.3 :
    9 Singapour vraie DI
    7 Hong Kong fixture
    7 Dubai fixture
    6 Rome/Vatican fixture
    4 invariants transverses
    4 normalisation cross
    4 confidence cohérente
  )

flutter test test/snapshots/generate_baseline.dart   (OFF)
  → overall 82.00 / 18 visites / coverage 100%
  → 0 log [places_destination_scope_reject]
  → comparator self-check : PASS

flutter test --dart-define=USE_DESTINATION_SCOPE=true \
  test/snapshots/generate_baseline.dart   (ON)
  → overall 79.47 / 18 visites / coverage 100%
  → 0 log [places_destination_scope_reject] (legacy intercept)
  → comparator self-check : PASS
```

Variation overall OFF → ON (82.00 → 79.47) dans la marge Google
Places attendue. Aucun changement fonctionnel induit par cette
tâche (test-only).

## Commande

```bash
# Tests cross-destinations uniquement
flutter test test/services/scope_validator_cross_destinations_test.dart

# Suite complète
flutter test

# Snapshot baseline (flag OFF par défaut)
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart

# Snapshot baseline avec flag ON
flutter test --dart-define=USE_DESTINATION_SCOPE=true \
  test/snapshots/generate_baseline.dart
```

## Conclusion Phase 3

Avec la Tâche 3.3, la **Phase 3** est complète :

| Tâche | Commit | Apport |
|-------|--------|--------|
| 3.1 | `a443755` | `scope_validator.dart` service pur (32 tests) |
| 3.2 | `9465725` | `blockedNeighborRegions` + intégration pipeline flag-gated (40 tests) |
| 3.3 | (this) | Tests cross-destinations SG/HK/Dubai/Rome (41 tests) |

**Total Phase 3 : 113 tests** dédiés au scope, dont 41
cross-destinations prouvant la généricité du mécanisme.

`DestinationScope` est :
- **disponible** comme service pur
- **branché** au pipeline derrière flag (OFF par défaut)
- **validé** sur 4 destinations différentes
- **strictement générique** : aucune logique custom destination
  ni dans le validator, ni dans le pipeline
- **non actif en pratique** sur Singapour (legacy
  `blockedAddressPatterns` intercept déjà) — couche défensive
  pour destinations futures sans MetroProfile curé

## Prochaine étape : Phase 4

`DayTemplate` — gabarits de journées thématiques par
destination. C'est le gros morceau de la refonte selon le plan,
qui remplacera progressivement le Day Builder greedy actuel
(V8.20+).
