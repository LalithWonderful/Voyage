# POI-0.2 — Validation offline / Dry-run d'import

> **Phase :** POI-0.2  
> **Objectif :** Valider le fixture `sample_pois_singapore.json` contre le schéma POI sans aucun write base ni appel réseau.  
> **Livrables :** validateur Dart offline + suite de tests + documentation.

---

## 1. Résumé

POI-0.2 fournit un **validateur offline** qui lit le fixture JSON et simule un import en mémoire. Il vérifie :

- la conformité au schéma SQL (`poi_knowledge_base.sql`) ;
- la cohérence des données (normalisation, plages, références croisées) ;
- l'absence de doublons (noms, aliases, `google_place_id`) ;
- la traçabilité des sources.

Aucune donnée n'est écrite dans Supabase. Aucun appel API n'est effectué.

---

## 2. Architecture du validateur

### Fichiers

| Fichier | Rôle |
|---|---|
| `test/poi/poi_fixture_validator.dart` | Bibliothèque de validation pure Dart. Réutilisable par les tests et les scripts futurs. |
| `test/poi/poi_fixture_dry_run_test.dart` | Suite de tests `flutter_test` qui exécute le validateur sur le fixture Singapour et assert chaque règle. |
| `test/fixtures/poi/sample_pois_singapore.json` | Fixture de référence (livré en POI-0.1). |

### Classes principales

```
PoiFixtureValidator
  ├── validate(Map<String, dynamic> json) → PoiDryRunReport
  ├── normalizeName(String) → String
  └── constantes : allowedCategories, allowedSourceTypes, allowedTagCategories

PoiDryRunReport
  ├── isValid : bool
  ├── errors : List<String>
  ├── warnings : List<String>
  ├── stats : PoiDryRunStats
  └── toJson() → Map<String, dynamic>

PoiDryRunStats
  └── agrégats : sourceCount, poiCount, aliasCount, tagCount,
      mustSeeCount, categoriesUsed, destinationKeysUsed, …
```

---

## 3. Règles validées

### 3.1 Structure top-level

| Règle | Sévérité |
|---|---|
| Présence des clés `sources` et `pois` | Erreur |
| `sources` et `pois` sont des listes | Erreur |

### 3.2 Sources

| Règle | Sévérité |
|---|---|
| `source_id` présent, non vide, format UUID valide | Erreur |
| `name` non vide | Erreur |
| `source_type` dans `allowedSourceTypes` | Erreur |
| `trust_level` entier 1..5 | Erreur |
| `is_active` est un booléen | Erreur |
| Pas de `source_id` dupliqué | Erreur |

### 3.3 POIs — schéma

| Règle | Sévérité |
|---|---|
| `poi_id` présent, non vide, UUID valide | Erreur |
| `destination_key` non vide | Erreur |
| `name` non vide | Erreur |
| `normalized_name` correspond à `normalizeName(name)` | Erreur |
| `category` dans `allowedCategories` | Erreur |
| `lat` ∈ [-90, 90] si présent | Erreur |
| `lng` ∈ [-180, 180] si présent | Erreur |
| `source_primary_id` référence une source existante | Erreur |
| `editorial_score` ∈ [0, 100] si présent | Erreur |
| `touristic_importance` ∈ [1, 5] si présent | Erreur |
| `typical_duration_minutes` > 0 si présent | Erreur |
| `price_level` ∈ [1, 4] si présent | Erreur |
| `is_must_see` est un booléen | Erreur |
| `is_family_friendly`, `is_rain_friendly`, `is_free` sont booléens ou null | Erreur |
| `google_place_id` est `null` ou `String` (jamais requis) | Erreur |
| `same_complex_group_key` est `null` ou `String` non vide | Erreur |

### 3.4 Aliases

| Règle | Sévérité |
|---|---|
| Tableau `aliases` présent et de type `List` | Erreur |
| `alias` non vide | Erreur |
| `alias_normalized` correspond à `normalizeName(alias)` | Erreur |
| `is_canonical` est un booléen | Erreur |
| Pas de `alias_normalized` dupliqué **au sein du même POI** | Erreur |
| Plus d'un alias `is_canonical=true` dans le même POI | Warning |
| Alias déjà utilisé par un **autre POI** de la même destination | Warning |

### 3.5 Tags

| Règle | Sévérité |
|---|---|
| Tableau `tags` présent et de type `List` | Erreur |
| `tag` non vide | Erreur |
| `tag_category` dans `allowedTagCategories` ou `null` | Erreur |
| `confidence` ∈ [0, 100] ou `null` | Erreur |

### 3.6 Cross-POI (déduplication)

| Règle | Sévérité |
|---|---|
| `normalized_name` unique par `destination_key` | Erreur |
| `google_place_id` non-null unique dans tout le fixture | Erreur |
| `poi_id` unique dans tout le fixture | Erreur |

---

## 4. Comment exécuter le dry-run

### 4.1 Via `flutter test` (recommandé pour CI)

```bash
flutter test test/poi/poi_fixture_dry_run_test.dart
```

Sortie attendue (succès) :
```
00:00 +0: POI Fixture Dry-Run fixture parses successfully
00:00 +1: POI Fixture Dry-Run dry-run produces zero errors
PoiDryRunStats(sources=2, pois=8, aliases=16, tags=21, ...)
00:00 +2: POI Fixture Dry-Run fixture contains expected sources
...
00:00 +22: All tests passed!
```

### 4.2 Via `flutter test` sur tout le dossier POI

```bash
flutter test test/poi/
```

---

## 5. Interprétation du rapport

### `isValid == true`
Le fixture est conforme au schéma. Aucune erreur bloquante. Des warnings peuvent exister (ex: alias partagé entre deux POI, ce qui peut être légitime ou signaler un doublon).

### `isValid == false`
Le fixture contient des erreurs de schéma. Chaque entrée de `errors` indique :
- le chemin JSON (`pois[3].aliases[1]`) ;
- la règle violée ;
- la valeur reçue.

**Exemples d'erreurs détectables :**
- `pois[2]: normalized_name mismatch: expected "national museum" got "national museum of singapore"`
- `pois[5]: duplicate alias_normalized "sentosa" within POI`
- `pois[7]: source_primary_id "xxx" not found in sources`

---

## 6. Stratégie de normalisation

La normalisation des noms est **identique** côté validateur et côté schéma SQL :

```dart
name.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ')
```

Cela garantit que le fixture peut être importé tel quel sans transformation supplémentaire. Le validateur vérifie cette équivalence strictement.

---

## 7. Extensibilité

Le validateur est conçu pour être réutilisable pour d'autres fixtures :

```dart
import 'test/poi/poi_fixture_validator.dart';

final json = jsonDecode(await File('test/fixtures/poi/sample_pois_tokyo.json').readAsString());
final report = PoiFixtureValidator().validate(json);
print(report.toJson());
```

Les constantes `allowedCategories`, `allowedSourceTypes` et `allowedTagCategories` sont publiques et peuvent être réutilisées côté modèle Dart futur (POI-0.3).

---

## 8. Conformité aux contraintes du projet

| Contrainte | Respect |
|---|---|
| Ne pas brancher Flutter | ✅ Le validateur est pure Dart ; seuls les tests importent `flutter_test`. |
| Ne pas créer de providers Riverpod | ✅ Aucun provider créé. |
| Ne pas importer en base réelle | ✅ Aucun `supabase_flutter`, aucun INSERT. |
| Ne pas appeler Google Places | ✅ Aucun appel réseau. |
| Ne pas scraper | ✅ Lecture fichier local uniquement. |
| Ne pas toucher au moteur planning | ✅ Aucun fichier sous `lib/` modifié. |

---

## 9. Prochaines étapes (hors scope POI-0.2)

- **POI-0.3** : Création des modèles Dart (`Poi`, `PoiSource`, etc.) dans `lib/` + providers Riverpod.
- **POI-1.0** : Import manuel piloté (edge function ou script admin) d'une première destination pilote.
- **POI-1.x** : Branchement conditionnel au pipeline de planning derrière un feature flag.
