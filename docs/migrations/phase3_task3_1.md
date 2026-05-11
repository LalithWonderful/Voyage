# Phase 3 / Tâche 3.1 — Service de validation de scope `ScopeValidator`

## Objectif

Poser le **service pur** qui valide si un lieu candidat appartient
au périmètre géographique d'une `DestinationIntelligence`.
Première brique de la refonte des `blockedAddressPatterns`
hardcodés du pipeline (V8.28b1.x) vers une logique générique
exploitant les champs déjà présents en Phase 1
(`allowedCountryCodes`, `blockedCountryCodes`, `borderSensitivity`).

**Tâche purement service + tests + doc.** 0 fichier de
production planning modifié. Le flag `useDestinationScope`
reste OFF et n'est consommé nulle part. Les
`blockedAddressPatterns` actuels du pipeline restent intacts.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : aucun nouveau champ ajouté à
  `DestinationIntelligence`. Le service consomme uniquement les
  champs Phase 1 existants. Adapter local `ScopeValidationPlace`
  cohérent avec le pattern Tâche 2.3 (`complex_matcher.dart`).

## Fichiers créés

- **`lib/services/scope_validator.dart`** *(~245 lignes)* —
  modèle `ScopeValidationPlace` + `ScopeValidationResult` +
  enums `ScopeRejectionReason` / `ScopeConfidence` + fonction
  `validatePlaceInScope` + table heuristique `_kCountryHints`.
- **`test/services/scope_validator_test.dart`** *(~395 lignes)*
  — **32 tests** en 7 groupes. Aucune dépendance réseau /
  Supabase / framework de mock.
- **`docs/migrations/phase3_task3_1.md`** *(ce document)*.

## Fichiers de production non modifiés

- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/data/metro_profile.dart` intact
  (`blockedAddressPatterns` Singapour / Hong Kong / Dubai
  toujours en place)
- `lib/models/destination_intelligence.dart` intact (aucune
  abstraction manquante identifiée en 3.1, cf. point ouvert
  Dubai ci-dessous)
- `lib/config/feature_flags.dart` intact (`useDestinationScope`
  reste OFF, non consommé)

## Signature retenue

```dart
ScopeValidationResult validatePlaceInScope(
  ScopeValidationPlace place,
  DestinationIntelligence di,
);
```

### `ScopeValidationPlace` (adapter local)

```dart
class ScopeValidationPlace {
  final String? name;
  final String? address;
  final String? countryCode;
  final double? lat;
  final double? lng;
  const ScopeValidationPlace({...});
}
```

Adapter local minimal — pas de couplage à `PlaceInfo` riche ou
`NearbyCandidate` (cohérent règle d'or 7). `lat`/`lng` réservés
pour extensions futures (Tâche 3.2/3.3 : check vs
`canonicalCenter` + radius, ou matching par zone).

### `ScopeValidationResult`

```dart
class ScopeValidationResult {
  final bool isInScope;
  final ScopeRejectionReason? rejectionReason;
  final ScopeConfidence confidence;
  final String? matchedEvidence;
}
```

`matchedEvidence` = string debug-friendly : code pays (`"SG"`)
ou hint adresse (`"johor bahru"`), `null` si default safe.

### Enums

```dart
enum ScopeRejectionReason {
  outOfCountry,           // countryCode tiers (ni allowed ni blocked)
  blockedCountry,         // countryCode explicite dans blockedCountryCodes
  blockedNeighborRegion,  // hint adresse → pays bloqué
  unknownCountry,         // réservé (non utilisé en 3.1)
}

enum ScopeConfidence {
  low,     // aucune preuve concrète
  medium,  // match heuristique (adresse hint)
  high,    // countryCode explicite
}
```

## Logique countryCode

Ordre des vérifications (priorité défensive : blocked > allowed > tiers) :

1. Normalisation `uppercase + trim`
2. Si dans `blockedCountryCodes` → **reject `blockedCountry`,
   HIGH, evidence = code**
3. Si dans `allowedCountryCodes` → **accept HIGH, evidence = code**
4. Sinon → **reject `outOfCountry`, HIGH, evidence = code**

Note : si un code apparaît dans **les deux** listes
(configuration anormale), `blocked` gagne — défensif. Testé
explicitement.

Exemples vérifiés par tests :
| DI | countryCode | Verdict |
|----|-------------|---------|
| Singapore (allowed=SG, blocked=MY/ID) | SG | accept HIGH |
| Singapore | MY | reject `blockedCountry` HIGH |
| Singapore | ID | reject `blockedCountry` HIGH |
| Singapore | FR | reject `outOfCountry` HIGH |
| Singapore | sg | accept HIGH (normalisation) |
| Rome (allowed=IT/VA) | IT | accept HIGH |
| Rome | VA | accept HIGH |
| Rome | FR | reject `outOfCountry` HIGH |
| Hong Kong (allowed=HK, blocked=CN) | CN | reject `blockedCountry` HIGH |
| Dubai (allowed=AE) | AE | accept HIGH |

## Logique fallback adresse

Quand `countryCode` est null / vide / whitespace :

1. Normalisation `lowercase + collapse whitespace`
2. Pour chaque code dans `blockedCountryCodes`, parcourir
   `_kCountryHints[code]` (substrings lowercase). Si match →
   **reject `blockedNeighborRegion`, MEDIUM, evidence = hint**.
3. Pour chaque code dans `allowedCountryCodes`, idem. Si match →
   **accept MEDIUM, evidence = hint**.
4. Sinon → fall-through au cas "aucune preuve" (voir ci-dessous).

Blocked priorité avant allowed (cohérent avec la stratégie
countryCode). Testé : adresse "Border between Singapore and
Malaysia, Johor" → rejet `blockedNeighborRegion`.

### Distinction `blockedCountry` vs `blockedNeighborRegion`

| Cas | Reason |
|-----|--------|
| `countryCode` explicite + dans blocked | `blockedCountry` |
| `address` contient hint pointant vers pays blocked | `blockedNeighborRegion` |

Permet aux futurs metrics / logs de discriminer entre "Google
nous a dit que c'est en MY" (cas dur) et "l'adresse mentionne
Johor mais nous n'avons pas de countryCode" (cas heuristique).

## Limites connues

### Table heuristique `_kCountryHints`

**Heuristique provisoire** (Tâche 3.1). Map statique en mémoire :

```dart
const Map<String, List<String>> _kCountryHints = {
  'SG': ['singapore'],
  'MY': ['malaysia', 'johor bahru', 'johor', 'kuala lumpur'],
  'ID': ['indonesia', 'bintan', 'batam'],
  'CN': ['china', 'shenzhen', 'guangdong'],
  'AE': ['united arab emirates', 'dubai', 'abu dhabi',
         'sharjah', 'ajman'],
  'IT': ['italy', 'rome', 'roma'],
  'VA': ['vatican', 'vatican city'],
  'TH': ['thailand', 'bangkok'],
  'JP': ['japan', 'tokyo'],
  'FR': ['france', 'paris'],
  'HK': ['hong kong', 'hongkong'],
};
```

**Limites** :
- **False positives** : `"Johor Park, Singapore"` matche
  `"johor"` → classifié à tort `MY`. Comportement déjà observé
  avec `blockedAddressPatterns` legacy (cf. doc V8.28b1) — pas
  une régression mais piste d'amélioration future.
- **Vocabulaire fini** : ne couvre pas toutes les destinations.
  Une destination dont le code n'est pas dans la table → aucun
  match heuristique → tombe en LOW.
- **Pas de désambiguïsation linguistique** : `"china"` matche
  aussi `"chinatown"` si présent dans l'adresse. Cas peu
  fréquent en pratique (chinatown rarement présent dans une
  adresse formattée Google).

**Évolution prévue** : remplacer la table statique par une
extraction dynamique depuis `DestinationIntelligence`. Cf.
section "Point ouvert Dubai" ci-dessous.

## Traitement de `borderSensitivity`

**Volontairement passif en Tâche 3.1.** `borderSensitivity` :
- ne change pas le verdict ;
- ne déclenche pas de rejet sans preuve concrète ;
- pas utilisé dans `validatePlaceInScope`.

**Justification** : spec explicite :
> *Ne pas rejeter arbitrairement un lieu uniquement parce que la
> destination est high sensitivity et que le countryCode manque.
> Sinon beaucoup de vrais lieux sans countryCode seraient
> exclus.*

Beaucoup de candidats Google Places ont `countryCode` null /
adresse approximative. Rejeter chacun de ces candidats sur une
destination high-sensitivity exclurait des dizaines de vrais
lieux Singapour. L'approche défensive est : **laisser passer en
LOW**, et laisser le caller (pipeline futur Tâche 3.2) appliquer
un *downscoring soft* plutôt qu'un *hard reject*.

`borderSensitivity` pourra reprendre un rôle actif en Tâche 3.2
si une politique différente est validée par run réel (ex:
high-sensitivity + LOW = downscore -20% en scoring).

## Point ouvert : Dubai et régions internes AE

**Problème identifié, non résolu en 3.1** : pour Dubai, le scope
souhaité est `émirat de Dubai uniquement` — Abu Dhabi / Sharjah
/ Ajman / Ras al Khaimah / Fujairah / Umm al Quwain devraient
être considérés *hors scope* malgré le countryCode commun AE.

**Modèle DI actuel ne le permet pas** : la granularité est
`country_code` (ISO 3166-1), pas "region within country". Si on
ajoute Abu Dhabi à `blockedCountryCodes` de Dubai DI, le code
serait `AE` (même que Dubai) → contradiction logique.

**Options possibles pour Tâche 3.2/3.3** :
1. **Nouveau champ générique `blockedRegions: List<String>`**
   sur `DestinationIntelligence` (extension non-breaking : champ
   optionnel défaut `[]`). Le validator consommerait ce champ en
   plus de `blockedCountryCodes`.
2. **`countryCode` "synthétique"** type `AE-AZ` (Abu Dhabi),
   `AE-DU` (Dubai) — non standard ISO 3166-2 directement, mais
   exploitable.
3. **Continuer à utiliser `blockedAddressPatterns` du
   `MetroProfile`** (legacy V8.28b1) en parallèle de
   `DestinationScope` pour ce cas particulier.

**Décision Tâche 3.1** : ne **pas** modifier `DestinationIntelligence`.
Documenter la limitation. Test Dubai actuel : `Abu Dhabi` est
*accepté MEDIUM* (car `abu dhabi` ∈ hints AE = allowed) — c'est
la limitation connue, à corriger en 3.2/3.3 selon l'option
retenue.

Conforme règle d'or 7 (*"Si une tâche révèle qu'une abstraction
générique manque, STOP et signale-le"*) — signalé ici, à
trancher en Tâche 3.2.

## Cas testés — 32 tests / 7 groupes

### 1. CountryCode explicite (7 tests)
- SG accepté HIGH
- MY / ID rejetés `blockedCountry` HIGH
- FR rejeté `outOfCountry` HIGH
- Normalisation `sg` / `SG` / `  SG  `
- Défensif : présent dans blocked ET allowed → blocked gagne

### 2. Fallback adresse Singapour (6 tests)
- Adresse contenant `Singapore` → accepté MEDIUM
- Adresse `Johor Bahru, Malaysia` → rejeté `blockedNeighborRegion`
- Adresse `Batam Center, Indonesia` / `Bintan Resorts, Lagoi` →
  rejetés
- Adresse ambiguë (rue seule) → accepté LOW
- Blocked priorité sur allowed quand les deux matchent

### 3. Hong Kong (5 tests)
- HK / CN explicites
- Adresse `Shenzhen, Guangdong` / `Guangdong Province` rejetés
- Adresse `Hong Kong` accepté MEDIUM

### 4. Rome (5 tests)
- IT / VA explicites acceptés
- Adresse `Vatican City` / `Roma` accepté MEDIUM
- Pays tiers (FR) rejeté `outOfCountry`

### 5. Dubai — point ouvert régions internes AE (2 tests)
- AE explicite accepté HIGH
- Adresse `Abu Dhabi` accepté MEDIUM (limitation documentée)

### 6. Aucune preuve (4 tests)
- No countryCode / no address → accepté LOW
- borderSensitivity HIGH + no evidence → toujours accepté LOW
- borderSensitivity LOW + no evidence → accepté LOW
- Whitespace-only countryCode traité comme absent (fallback
  adresse)

### 7. Robustesse null / vide (3 tests)
- Tous champs null → ne crash pas
- Strings vides traitées comme absentes
- `lat`/`lng` fournis mais inutilisés en 3.1

## Ce qui n'est volontairement PAS fait

- ❌ Branchement validator → `places_first_pipeline.dart` —
  Tâche 3.2
- ❌ Consommation du flag `useDestinationScope`
- ❌ Suppression / modification des `blockedAddressPatterns`
  legacy
- ❌ Modification de `DestinationIntelligence` (cf. point
  ouvert Dubai)
- ❌ Tests cross-destinations runtime — Tâche 3.3
- ❌ Couplage à `PlaceInfo` / `NearbyCandidate`
- ❌ Création de `DayTemplate` (Phase 4)
- ❌ Appel réseau / Supabase
- ❌ Suppression d'ancien code

## Confirmation aucun branchement runtime

- ✅ `grep -rn "scope_validator\|validatePlaceInScope" lib/features/`
  → **aucune référence** dans les fichiers de production.
- ✅ `grep -rn "useDestinationScope" lib/` → seule occurrence
  dans `lib/config/feature_flags.dart` (déclaration, pas de
  consommation).
- ✅ Le test 3.1 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/models/destination_intelligence.dart`
  - `package:voyage/services/scope_validator.dart`

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/services/scope_validator.dart       : No issues found
  → test/services/scope_validator_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  778 tests verts (746 Tâche 2.5 + 32 nouveaux Tâche 3.1)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 81.46 / 18 visites / coverage 100%
  Variation Google Places attendue (cf. Tâche 0.1) — aucun
  rapport avec cette tâche, qui ne branche rien au pipeline.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

## Commande

```bash
# Tests service uniquement
flutter test test/services/scope_validator_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 3.2

Intégration du validator au pipeline derrière le flag
`useDestinationScope`. Pattern attendu cohérent avec Tâche 2.4 :
- paramètres optionnels sur le filtre approprié
  (`gatherCandidatesForTrip` ou `_isAllowedFinalVisitCandidate`)
- court-circuit total quand flag OFF
- journal de rejets optionnel pour tests
- mirror diagnostic dans la breakdown
- caller production : `FeatureFlags.fromEnvironment()` + lookup
  DI (loader Tâche 1.3)

Décision attendue avant 3.2 : option retenue pour les régions
internes AE (cf. point ouvert ci-dessus). 3 candidats :
`blockedRegions` field, `countryCode` synthétique, ou
co-existence `blockedAddressPatterns` legacy.
