# POI-0.4 — Contract test offline SQL / Dart

> **Phase :** POI-0.4  
> **Objectif :** Garantir que le `PoiStagingPlan` généré par l'importer Dart (POI-0.3) respecte strictement le contrat du DDL Supabase (POI-0.1), sans aucune base de données.  
> **Livrables :** Parser SQL offline + validateur de contrat + tests + documentation.

---

## 1. Résumé

Jusqu'à présent :
- **POI-0.1** a défini le schéma SQL Supabase.
- **POI-0.2** a validé le fixture JSON contre des règles métiers.
- **POI-0.3** a transformé le fixture en plan d'insertion SQL (dry-run).

**POI-0.4** ferme la boucle : il vérifie que le plan d'insertion Dart et le schéma SQL restent **synchronisés**. Si une colonne est renommée côté SQL mais pas côté Dart, ou si un type change, ou si une contrainte `NOT NULL` est ajoutée sans alimenter le plan, le test casse immédiatement.

Ce mécanisme est le **mur de sécurité** entre le modèle Dart et le DDL PostgreSQL — l'équivalent d'un `LiveApiGuards` mais pour la cohérence schema/code.

---

## 2. Architecture

### Fichiers

| Fichier | Rôle |
|---|---|
| `test/poi/poi_sql_schema_parser.dart` | Parser SQL offline (sous-ensemble DDL POI uniquement). |
| `test/poi/poi_sql_contract_validator.dart` | Valide un `PoiStagingPlan` contre un `SqlSchema` parsé. |
| `test/poi/poi_sql_contract_test.dart` | Suite de tests : happy path + tests négatifs (plan malformé). |
| `test/poi/poi_staging_importer.dart` | Réutilisé de POI-0.3 (génère le plan). |
| `supabase/sql/poi_knowledge_base.sql` | Schéma SQL source de vérité. |

### Flux

```
poi_knowledge_base.sql
    ↓
PoiSqlSchemaParser.parse() → SqlSchema (tables, colonnes, contraintes)
    ↓
PoiStagingImporter.run(fixture) → PoiStagingPlan (6 tables de rows)
    ↓
PoiSqlContractValidator.validate(schema, plan) → PoiSqlContractReport
    ↓
Zero erreur = contrat respecté
```

---

## 3. Parser SQL (`poi_sql_schema_parser.dart`)

### Capacités

Le parser n'est **pas** un parser SQL généraliste. Il gère uniquement le sous-ensemble utilisé par `poi_knowledge_base.sql` :

| Élément | Support |
|---|---|
| `CREATE TABLE … (` | ✅ (avec `if not exists public.<name>`) |
| Colonnes + type | ✅ (`uuid`, `text`, `integer`, `boolean`, `double precision`, `timestamptz`, `jsonb`) |
| `NOT NULL` | ✅ |
| `DEFAULT <value>` | ✅ |
| `PRIMARY KEY` inline | ✅ (génère contrainte table-level) |
| `UNIQUE` inline | ✅ |
| `REFERENCES` inline | ✅ |
| Contrainte `PRIMARY KEY (cols)` | ✅ |
| Contrainte `FOREIGN KEY (cols) REFERENCES table(cols)` | ✅ (avec `public.` prefix) |
| Contrainte `UNIQUE (cols)` | ✅ (même avec `coalesce(...)`) |
| Contrainte `CHECK (expr)` | ✅ |
| Commentaires `--` et `/* */` | ✅ (supprimés avant parsing) |

### Non-supporté (hors scope)

- `ALTER TABLE` (hors DDL CREATE TABLE)
- `CREATE INDEX` (pas utile pour le contrat de données)
- `CREATE POLICY` / RLS
- `CREATE TRIGGER` / `FUNCTION`
- Types custom, domains, arrays
- Expressions `CHECK` complexes avec sous-requêtes

### Modèle de données parsé

```
SqlSchema
 └── tables: Map<String, SqlTable>
      └── SqlTable
           ├── columns: Map<String, SqlColumn>
           │    └── SqlColumn (name, type, isNullable, defaultValue)
           └── constraints: List<SqlTableConstraint>
                └── SqlTableConstraint (kind, columns, referenceTable, expression)
```

---

## 4. Validateur de contrat (`poi_sql_contract_validator.dart`)

### Règles validées

#### 4.1 Existence des tables
Toutes les tables du staging plan doivent exister dans le schéma SQL :
`poi_sources`, `pois`, `poi_aliases`, `poi_source_links`, `poi_tags`, `poi_quality_flags`.

#### 4.2 Existence des colonnes
Toute clé présente dans une row du staging plan doit correspondre à une colonne SQL existante. Une colonne inconnue (ex: typo) génère une **erreur bloquante**.

#### 4.3 NOT NULL sans default
Pour chaque colonne SQL déclarée `NOT NULL` **sans** `DEFAULT` :
- la row doit contenir cette clé ;
- la valeur doit être non-null.

Exemples de colonnes concernées :
- `pois.destination_key`, `pois.name`, `pois.normalized_name`, `pois.category`, `pois.source_primary_id`
- `poi_aliases.poi_id`, `poi_aliases.alias`, `poi_aliases.alias_normalized`
- `poi_source_links.poi_id`, `poi_source_links.source_id`
- etc.

Les colonnes `NOT NULL` avec default (ex: `created_at default now()`) ne sont pas requises dans le plan.

#### 4.4 Compatibilité des types

| SQL type | Dart type attendu |
|---|---|
| `uuid`, `text` | `String` |
| `integer` | `int` |
| `boolean` | `bool` |
| `double precision` | `double` ou `int` |
| `timestamptz` | `String` (ISO8601) ou `DateTime` |
| `jsonb` | `Map<String, dynamic>` ou `List<dynamic>` |

#### 4.5 CHECK constraints

Le validateur évalue les expressions `CHECK` du schéma contre chaque row du plan. Support limité aux patterns du DDL POI :

| Pattern SQL | Exemple | Validation |
|---|---|---|
| `col >= min and col <= max` | `trust_level >= 1 and trust_level <= 5` | ✅ |
| `col is null or (col >= min and col <= max)` | `lat is null or (lat >= -90 and lat <= 90)` | ✅ |
| `col is null or col > min` | `typical_duration_minutes is null or typical_duration_minutes > 0` | ✅ |
| `col in ('a', 'b', 'c')` | `category in ('must_see', 'museum', ...)` | ✅ |
| Expressions complexes non listées | — | ⚠️ skipped (warning implicite) |

#### 4.6 Contraintes d'unicité

Pour chaque contrainte `UNIQUE` du schéma SQL, le validateur vérifie qu'aucune row du plan ne la viole.

Support limité : les expressions `coalesce(col, '')` sont évaluées (cas de `poi_source_links`).

Contraintes uniques actuelles dans le schéma :
- `poi_aliases(poi_id, alias_normalized)`
- `poi_source_links(poi_id, source_id, coalesce(source_poi_identifier, ''))`

> **Note :** Le schéma SQL ne définit pas de `UNIQUE` explicite sur `(destination_key, normalized_name)` ni sur `google_place_id`. L'importer Dart (POI-0.3) simule ces contraintes en plus du SQL. Le contract test ne valide que les contraintes SQL existantes ; les règles Dart supplémentaires restent documentées dans POI-0.3.

#### 4.7 Ordre d'insertion (FK)

Le validateur construit le graphe des dépendances FK à partir du schéma SQL et vérifie que l'ordre des tables dans le `PoiStagingPlan` respecte la topologie :

```
poi_sources → pois → poi_aliases
                    → poi_source_links
                    → poi_tags
                    → poi_quality_flags
```

---

## 5. Commandes

### Exécuter les tests

```bash
flutter test test/poi/poi_sql_contract_test.dart
```

### Exécuter tous les tests POI

```bash
flutter test test/poi/
```

---

## 6. Tests négatifs

La suite inclut 5 scénarios de corruption artificielle pour prouver que le contract test détecte les divergences :

1. **Colonne inexistante** — ajout d'une clé `nonexistent_column` dans une row → erreur "column not found".
2. **NOT NULL violé** — `name` mis à `null` dans `poi_sources` → erreur "NOT NULL column missing or null".
3. **Type mismatch** — `lat` mis à `"not_a_number"` → erreur "type mismatch".
4. **CHECK violé** — `trust_level` mis à `99` → erreur "CHECK violated".
5. **Unique violé** — duplication d'un alias dans `poi_aliases` → erreur "violates unique constraint".

---

## 7. Rapport produit

`PoiSqlContractReport` fournit :

| Champ | Description |
|---|---|
| `isValid` | `true` si zéro erreur bloquante. |
| `errors` | Erreurs bloquantes (schema mismatch, type, NOT NULL, CHECK, unique, FK order). |
| `warnings` | Warnings non bloquants (réservé pour extensions futures). |

Le rapport est JSON-sérialisable via `toJson()`.

---

## 8. Conformité aux règles du projet

| Règle | Respect |
|---|---|
| Aucune base de données requise | ✅ Parser + validateur 100 % offline. |
| Aucun Supabase / aucun secret | ✅ Aucun `supabase_flutter`, aucune URL, aucune clé. |
| Aucun Google Places | ✅ Aucun appel réseau. |
| Aucun scraping | ✅ Lecture fichier local uniquement. |
| Aucun branchement Flutter | ✅ Logique pure Dart (seuls les tests utilisent `flutter_test`). |
| Aucun provider Riverpod | ✅ Aucun provider créé. |
| Aucun moteur planning modifié | ✅ Aucun fichier `lib/` modifié. |
| Ne pas modifier les fixtures | ✅ `sample_pois_singapore.json` inchangé. |
| Parser limité au sous-ensemble POI | ✅ Pas de parser SQL généraliste. |

---

## 9. Maintenance future

### Quand modifier le parser

Si le schéma SQL POI évolue avec un nouvel élément DDL non supporté (ex: nouveau type de contrainte, `ALTER TABLE`, `PARTITION`), le test de parsing échouera ou le contract test laissera passer une incohérence. Il faudra alors :

1. Ajouter le support dans `PoiSqlSchemaParser`.
2. Ajouter la règle correspondante dans `PoiSqlContractValidator`.
3. Ajouter un test négatif dans `poi_sql_contract_test.dart`.

### Quand le contract test casse

Le contract test casse si :
- Une colonne est renommée côté SQL mais pas côté Dart.
- Une colonne `NOT NULL` est ajoutée sans alimentation dans l'importer.
- Un type SQL change (ex: `integer` → `smallint`).
- Une contrainte `CHECK` est ajoutée/modifiée.

C'est le comportement attendu : le test est le **gardien de la cohérence**.

---

## 10. Prochaines étapes (hors scope POI-0.4)

- **POI-0.5 / POI-0.6** : Option B — exécution du DDL sur une base Supabase locale ou staging pour validation end-to-end (insert réel en base de test, rollback après test).
- **POI-1.x** : Branchement du staging import à une edge function ou un script admin avec `service_role`.
