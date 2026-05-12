# POI-0.3 — Staging Import Dry-Run

> **Phase :** POI-0.3  
> **Objectif :** Transformer le fixture JSON validé en plan d'insertion SQL et simuler l'import sans écrire en base par défaut.  
> **Livrables :** Importer Dart offline + tests + documentation.

---

## 1. Résumé

POI-0.3 prend le fixture `sample_pois_singapore.json` (validé en POI-0.2) et le transforme en un **plan d'insertion** structuré qui correspond exactement au schéma Supabase `poi_knowledge_base.sql` (POI-0.1).

Le plan contient :
- `poi_sources` — sources à insérer
- `pois` — lieux à insérer
- `poi_aliases` — aliases dénormalisés
- `poi_source_links` — liens de traçabilité
- `poi_tags` — tags dénormalisés
- `poi_quality_flags` — flags générés automatiquement depuis les warnings du validateur

Par défaut, l'importer fonctionne en **dry-run** : il génère le rapport mais n'écrit rien. L'écriture réelle nécessite `dryRun: false` et l'injection d'un `writeExecutor`.

---

## 2. Architecture

### Fichiers

| Fichier | Rôle |
|---|---|
| `test/poi/poi_staging_importer.dart` | Logique d'import : validation → transformation → simulation contraintes → rapport. |
| `test/poi/poi_staging_import_test.dart` | Tests offline couvrant dry-run, write mocké, fixture invalide, et intégrité référentielle. |
| `test/poi/poi_fixture_validator.dart` | Réutilisé de POI-0.2 (validation préalable). |
| `test/fixtures/poi/sample_pois_singapore.json` | Fixture source (inchangé depuis POI-0.1). |

### Flux de données

```
Fixture JSON
    ↓
[PoiFixtureValidator] — validation POI-0.2
    ↓ (si valide)
[PoiStagingImporter._buildPlan]
    ↓
PoiStagingPlan (6 tables dénormalisées)
    ↓
[PoiStagingImporter._simulateDbConstraints]
    ↓
PoiStagingReport
    ↓
Si dryRun=true  → rapport uniquement
Si dryRun=false + writeExecutor → écriture réelle
```

---

## 3. API de l'importer

```dart
final importer = PoiStagingImporter();
final report = await importer.run(fixtureJson, dryRun: true);

print(report.plan?.counts);
// {poi_sources: 2, pois: 8, poi_aliases: 16,
//  poi_source_links: 8, poi_tags: 24, poi_quality_flags: 0}

print(report.blockingErrors); // [] si tout est vert
print(report.warnings);       // [] ou liste de warnings
print(report.canProceed);     // true si aucune erreur bloquante
```

### Paramètres

| Paramètre | Type | Défaut | Description |
|---|---|---|---|
| `fixtureJson` | `Map<String, dynamic>` | requis | Fixture JSON parsé. |
| `dryRun` | `bool` | `true` | Si `true`, aucun write n'est effectué. |
| `writeExecutor` | `PoiStagingWriteExecutor?` | `null` | Callback exécuté si `dryRun=false` et `canProceed=true`. |

---

## 4. Simulations de contraintes DB (offline)

L'importer simule les contraintes suivantes **sans se connecter à Supabase** :

| Contrainte | Comportement |
|---|---|
| `PRIMARY KEY (source_id)` sur `poi_sources` | Détection de `source_id` dupliqué. |
| `PRIMARY KEY (poi_id)` sur `pois` | Détection de `poi_id` dupliqué. |
| `UNIQUE (destination_key, normalized_name)` sur `pois` | Détection de noms dupliqués par destination. |
| `UNIQUE google_place_id WHERE NOT NULL` | Détection de Place ID dupliqués. |
| `FOREIGN KEY (source_primary_id) → poi_sources` | Vérification que chaque POI référence une source du plan. |
| `FOREIGN KEY (poi_id)` dans aliases/tags/links | Vérification que chaque enfant référence un POI existant. |

---

## 5. Génération automatique de quality flags

Les warnings produits par `PoiFixtureValidator` sont traduits en `poi_quality_flags` :

| Warning validateur | Flag généré | `flag_type` |
|---|---|---|
| Alias partagé entre 2 POI d'une même destination | `duplicate` | `duplicate` |
| Plusieurs aliases `is_canonical=true` dans un POI | `needs_review` | `needs_review` |

Cette translation est purement textuelle (parsing des messages du validateur). Une version future pourrait utiliser des warnings structurés.

---

## 6. Commandes

### Exécuter les tests

```bash
flutter test test/poi/poi_staging_import_test.dart
```

### Exécuter le dry-run manuellement (depuis un script Dart)

```dart
import 'dart:convert';
import 'dart:io';
import 'test/poi/poi_staging_importer.dart';

void main() async {
  final json = jsonDecode(
    File('test/fixtures/poi/sample_pois_singapore.json').readAsStringSync(),
  );
  final report = await PoiStagingImporter().run(json);
  print(jsonEncode(report.toJson()));
}
```

---

## 7. Rapport produit

Le `PoiStagingReport` contient :

| Champ | Description |
|---|---|
| `dryRun` | Mode dry-run utilisé ? |
| `validationPassed` | Le validateur POI-0.2 a-t-il passé ? |
| `plan` | Plan d'insertion détaillé (6 tables). |
| `blockingErrors` | Erreurs bloquantes (validation + contraintes DB). |
| `warnings` | Warnings non bloquants. |
| `canProceed` | `true` si l'import peut théoriquement avoir lieu. |
| `writeExecuted` | `true` si un `writeExecutor` a effectivement été appelé. |

---

## 8. Sécurité et garde-fous

| Garde-fou | Implémentation |
|---|---|
| **Dry-run par défaut** | Paramètre `dryRun` défaut `true`. |
| **Pas de write sans executor** | Si `dryRun=false` et `writeExecutor=null`, une erreur bloquante est ajoutée au rapport. |
| **Pas de write si erreurs** | Même avec `dryRun=false`, le writeExecutor n'est appelé que si `blockingErrors.isEmpty`. |
| **Aucun appel réseau** | Par défaut, aucun `SupabaseClient` n'est instancié. |
| **Aucun secret requis** | Le code offline n'utilise pas d'URL Supabase ni de clé API. |

---

## 9. Conformité aux règles du projet

| Règle | Respect |
|---|---|
| Dry-run par défaut | ✅ `dryRun: true` par défaut. |
| Aucun write sans flag explicite | ✅ `dryRun=false` requis + `writeExecutor` injecté. |
| Aucun Google Places | ✅ Aucun appel Google. |
| Aucun scraping | ✅ Lecture fichier local uniquement. |
| Aucun branchement Flutter | ✅ Logique pure Dart, seuls les tests utilisent `flutter_test`. |
| Aucun provider Riverpod | ✅ Aucun provider créé. |
| Aucun moteur planning modifié | ✅ Aucun fichier `lib/` modifié. |
| Ne pas enrichir Google Place ID | ✅ `google_place_id` est recopié tel quel depuis le fixture. |
| Ne pas modifier les fixtures | ✅ `sample_pois_singapore.json` inchangé. |

---

## 10. Prochaines étapes (hors scope POI-0.3)

- **POI-1.0** : Implémenter un `writeExecutor` réel utilisant `SupabaseClient` avec `service_role` pour insertion staging.
- **POI-1.x** : Edge function ou script CLI pour exécuter l'import en production/admin.
