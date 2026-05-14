# POI-DATA-0.6 — Audit Provenance Sources POI

## Date
2026-05-14

## Scope
Auditer le modèle POI Lunao (Supabase + Dart + fixtures + imports) pour vérifier si la provenance de chaque POI est stockée, traçable et distinguée par source (Google Places, OSM, Wikidata, éditorial, etc.).

---

## 1. Schéma Supabase — État actuel

### Tables impliquées

| Table | Rôle | Colonne de provenance |
|---|---|---|
| `poi_sources` | Référentiel des sources autorisées | `source_type` (CHECK sur 7 valeurs) |
| `pois` | Cœur POI | `source_primary_id` (FK → poi_sources) |
| `poi_source_links` | Traçabilité fine POI ↔ source externe | `source_id`, `source_poi_identifier`, `source_url`, `source_raw_data` |
| `poi_aliases` | Alias | `source_id` (FK → poi_sources) |
| `poi_tags` | Tags | `source_id` (FK → poi_sources) |
| `poi_quality_flags` | Flags qualité | **Aucune colonne source** |

### Types de source autorisés (CHECK)

```
official_board, official_venue, unesco,
wikidata, openstreetmap, open_data_gov, editorial
```

> **Note** : `google_places` n'est **pas** dans la liste `source_type`. Google Places n'est représenté que par le champ `pois.google_place_id`.

---

## 2. Réponses aux 8 questions

### Q1 — Existe-t-il un champ `source` ou `source_primary` dans `pois` ?

**Oui.** `pois.source_primary_id` (UUID, NOT NULL, FK → `poi_sources`).

Chaque POI a une source primaire obligatoire.

### Q2 — Existe-t-il une table `poi_sources` ou équivalent ?

**Oui.** `poi_sources` est le référentiel des sources autorisées avec :
- `source_id`, `name`, `source_type`, `trust_level`, `is_active`
- Contrainte CHECK sur 7 `source_type`

### Q3 — Les fixtures indiquent-elles la provenance ?

**Partiellement.**

- Chaque fixture a une section `sources` avec une source unique (généralement `source_type: "editorial"`, `trust_level: 5`).
- Chaque POI a `source_primary_id` qui pointe vers cette source.
- Les **tags** et **aliases** dans le fixture JSON n'ont pas de `source_id` explicite.
- Le `PoiStagingImporter` assigne automatiquement `source_primary_id` aux tags et aliases lors de la construction du plan.

> Conséquence : dans Supabase, tous les tags et aliases d'un POI portent le même `source_id` que le POI lui-même. On ne peut pas distinguer un tag OSM d'un tag éditorial.

### Q4 — Les imports conservent-ils la source ?

**Oui pour la source primaire, non pour les enrichissements.**

- `PoiStagingImporter._buildPlan` crée un `poi_source_links` pour la source primaire avec :
  - `source_poi_identifier: ''` (vide)
  - `source_url: officialUrl`
  - `source_raw_data: {}`
- Les upserts utilisent `onConflict` sur les clés naturelles, donc les ré-imports préservent les liens existants.

### Q5 — Les enrichissements Google Places sont-ils distingués des sources OSM/Wikidata ?

**Non.**

- `google_place_id` est un champ texte nullable dans `pois`.
- Il n'y a **pas** de ligne dans `poi_sources` pour Google Places (type non autorisé).
- Il n'y a **pas** de `poi_source_links` créé automatiquement pour Google Places.
- Si un POI a un `google_place_id`, on sait qu'il a été enrichi, mais on ne sait pas quand, par quel batch, ni quels champs précis viennent de Google.

### Q6 — Peut-on savoir quel champ vient de quelle source ?

**Non, pas au niveau champ.**

- Le schéma est au niveau **ligne** (poi, alias, tag, lien), pas au niveau **champ**.
- `poi_source_links.source_raw_data` (jsonb) peut stocker des données brutes d'audit, mais il est vide (`{}`) dans le pipeline actuel.
- `pois.payload` (jsonb) est extensible mais n'est pas utilisé pour tracer la provenance champ par champ.

### Q7 — Les rapports POI affichent-ils la provenance ?

**Non.**

- `PoiDryRunReport` compte les sources (`sourceCount`) mais n'affiche pas leur type ni leur trust level.
- `PoiStagingReport` affiche les `insert_counts` mais pas la répartition par source.
- `PoiImportCheckReport` (post-import) affiche les counts mais ne vérifie pas la cohérence des `source_id`.
- Les rapports markdown existants (`poi_supabase_import_2026_05_14.md`, `poi_supabase_import_23_city_report.md`) ne mentionnent pas la provenance.

### Q8 — Quels changements minimaux recommander pour rendre la provenance obligatoire ?

Voir section 5 ci-dessous.

---

## 3. Manques identifiés

### M1 — Google Places n'est pas une source traçable
- `google_places` absent de `poi_sources.source_type`.
- Aucun `poi_source_links` créé pour les enrichissements Google.
- Impossible de savoir quels POI ont été enrichis par Google Places vs créés manuellement.

### M2 — `source_poi_identifier` vide pour les sources primaires
- Dans `poi_source_links`, `source_poi_identifier` est systématiquement `''` pour le lien primaire.
- On ne peut pas retrouver l'identifiant externe du POI dans sa source (ex: Q12345 pour Wikidata, node OSM).

### M3 — Tags et aliases n'ont pas de provenance fine
- Les fixtures ne permettent pas de spécifier un `source_id` différent par tag ou alias.
- Le staging importer assigne le `source_primary_id` du POI à tous ses enfants.
- Si un tag vient d'une source différente (ex: OSM pour les coordonnées, Wikidata pour les dates), cette information est perdue.

### M4 — Quality flags sans source
- `poi_quality_flags` n'a pas de `source_id`.
- Un flag "donnée obsolète" ne peut pas être attribué à une source spécifique.

### M5 — Pas de traçabilité d'import batch
- Aucune table `poi_import_batches` ni champ `import_batch_id`.
- Impossible de savoir quel POI a été importé lors de quel batch, par quel agent, à quelle date.

### M6 — Checker ne valide pas la cohérence source
- `PoiSupabaseImportChecker` ne vérifie pas :
  - que chaque POI a au moins un `poi_source_links`
  - que les `source_id` des aliases/tags correspondent à la source primaire du POI
  - que `source_poi_identifier` est renseigné pour les sources non-éditoriales

### M7 — `source_raw_data` inutilisé
- `poi_source_links.source_raw_data` est toujours `{}` dans le pipeline.
- Cette colonne jsonb pourrait stocker la réponse brute OSM/Overpass ou les métadonnées Google Places.

---

## 4. Proposition de modèle minimal

### 4.1 Ajouter `google_places` comme source type

```sql
-- Migration
alter table public.poi_sources
  drop constraint if exists poi_sources_source_type_check;

alter table public.poi_sources
  add constraint poi_sources_source_type_check
    check (source_type in (
      'official_board', 'official_venue', 'unesco',
      'wikidata', 'openstreetmap', 'open_data_gov',
      'editorial', 'google_places'
    ));
```

### 4.2 Créer une source Google Places dans `poi_sources`

```sql
insert into public.poi_sources (source_id, name, source_type, trust_level, is_active)
values (
  'google-places-001',
  'Google Places API',
  'google_places',
  3,
  true
)
on conflict (source_id) do nothing;
```

### 4.3 Créer automatiquement un `poi_source_links` pour Google Places

Dans `PoiStagingImporter._buildPlan`, si `poi['google_place_id']` est présent, ajouter un deuxième lien :

```dart
if (googlePlaceId != null && googlePlaceId.isNotEmpty) {
  sourceLinks.add({
    'poi_id': poiId,
    'source_id': googlePlacesSourceId, // 'google-places-001'
    'source_poi_identifier': googlePlaceId,
    'source_url': 'https://maps.google.com/?q=place_id:$googlePlaceId',
    'source_raw_data': <String, dynamic>{},
  });
}
```

### 4.4 Ajouter `source_id` optionnel dans les fixtures pour tags/aliases

Modifier le fixture JSON pour accepter :

```json
{
  "tag": "historic",
  "tag_category": "vibe",
  "confidence": 98,
  "source_id": "optional-uuid"
}
```

Le staging importer utiliserait `tag['source_id'] ?? sourcePrimaryId`.

### 4.5 Ajouter `source_id` dans `poi_quality_flags`

```sql
alter table public.poi_quality_flags
  add column if not exists source_id uuid
  references public.poi_sources(source_id);
```

### 4.6 Table `poi_import_batches` (optionnel mais recommandé)

```sql
create table if not exists public.poi_import_batches (
  batch_id      uuid        primary key default gen_random_uuid(),
  city_key      text        not null,
  agent_name    text        not null,
  started_at    timestamptz not null default now(),
  completed_at  timestamptz,
  status        text        not null check (status in ('running', 'success', 'partial', 'failed')),
  report_json   jsonb       not null default '{}',
  created_at    timestamptz not null default now()
);

-- Lier les POIs à leur batch
alter table public.pois
  add column if not exists import_batch_id uuid
  references public.poi_import_batches(batch_id);
```

---

## 5. Tests à ajouter

### T1 — Vérifier que Google Places génère un lien source

```dart
test('google_place_id creates a poi_source_links entry', () {
  final fixture = buildFixtureWithGooglePlaceId('ChIJ...');
  final report = importer.run(fixture, dryRun: true);
  final googleLinks = report.plan!.poiSourceLinks
    .where((l) => l['source_id'] == 'google-places-001');
  expect(googleLinks, hasLength(1));
  expect(googleLinks.first['source_poi_identifier'], 'ChIJ...');
});
```

### T2 — Vérifier la cohérence source_id post-import

```dart
test('all poi_tags source_id match poi source_primary_id or an explicit source', () {
  // Post-import verification
  final tags = await reader.select('poi_tags', eqFilters: {'poi_id': poiId});
  for (final tag in tags) {
    expect(tag['source_id'], anyOf(equals(poiSourceId), isNotNull));
  }
});
```

### T3 — Vérifier que chaque POI a au moins un poi_source_links

```dart
test('every poi has at least one source link', () async {
  final pois = await reader.select('pois');
  for (final poi in pois) {
    final links = await reader.select('poi_source_links',
      eqFilters: {'poi_id': poi['poi_id']});
    expect(links, isNotEmpty,
      reason: 'POI ${poi['poi_id']} has no source links');
  }
});
```

### T4 — Vérifier `source_poi_identifier` pour les sources non-éditoriales

```dart
test('non-editorial sources have a source_poi_identifier', () async {
  final links = await reader.select('poi_source_links');
  for (final link in links) {
    final source = await reader.select('poi_sources',
      eqFilters: {'source_id': link['source_id']}).first;
    if (source['source_type'] != 'editorial') {
      expect(link['source_poi_identifier'],
        isNotNull.and(isNotEmpty),
        reason: 'Link ${link['link_id']} missing identifier');
    }
  }
});
```

### T5 — Vérifier que `poi_sources` contient Google Places

```dart
test('google_places source exists in poi_sources', () async {
  final sources = await reader.select('poi_sources');
  final hasGoogle = sources.any((s) => s['source_type'] == 'google_places');
  expect(hasGoogle, isTrue);
});
```

---

## 6. Conclusion

**Verdict** : La provenance est **structurellement supportée** mais **partiellement utilisée**.

- ✅ Chaque POI a une source primaire (`source_primary_id`).
- ✅ La table `poi_sources` permet de modéliser différents types de source.
- ✅ `poi_source_links` permet la traçabilité fine.
- ❌ Google Places n'est pas modélisé comme une source.
- ❌ Les tags/aliases héritent aveuglément de la source primaire.
- ❌ Les identifiants externes (`source_poi_identifier`) sont vides.
- ❌ Aucune traçabilité de batch d'import.
- ❌ Le checker ne valide pas la cohérence de la provenance.

**Priorité recommandée** :
1. P0 — Ajouter `google_places` dans `poi_sources` et créer les liens lors de l'import.
2. P1 — Remplir `source_poi_identifier` pour les sources non-éditoriales (OSM node ID, Wikidata QID).
3. P2 — Ajouter `source_id` optionnel dans les fixtures pour tags/aliases.
4. P3 — Table `poi_import_batches` pour traçabilité temporelle.
