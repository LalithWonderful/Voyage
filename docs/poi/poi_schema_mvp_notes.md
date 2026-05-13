# POI Schema MVP Notes

Date: 2026-05-13

Migration: `supabase/sql/poi_knowledge_base_mvp.sql`

## Included

The MVP migration is an additive layer over the existing POI-0.1 schema in
`supabase/sql/poi_knowledge_base.sql`.

It keeps the current import contract intact while adding the first target
knowledge-base tables from `docs/poi/supabase_poi_knowledge_base_design.md`:

- `poi_categories`
- `poi_localized_names`
- `poi_destination_links`
- `poi_external_refs`
- `poi_quality_scores`
- `poi_import_batches`
- `poi_import_issues`
- `poi_editorial_overrides`

It also extends the existing `poi_sources` and `pois` tables with target MVP
fields such as broader source types, canonical name, primary category key,
locality/neighborhood metadata, active state, hidden-gem flag, and additional
indexes.

## Deferred

The MVP intentionally defers:

- `poi_opening_hours`
- `poi_media`
- PostGIS/geography indexes
- destination identity tables
- runtime Supabase POI provider integration
- Google Places enrichment cache tables
- import script rewrites for the new target tables

Those should be added after the schema contract and pilot fixtures are stable.

## Design Mapping

The migration implements the minimum durable layer from the target design:

- source provenance via `poi_sources` and `poi_external_refs`
- canonical POI records via `pois`
- multilingual names via `poi_localized_names`
- destination membership via `poi_destination_links`
- deterministic ranking via `poi_quality_scores`
- import auditability via `poi_import_batches` and `poi_import_issues`
- editorial correction seam via `poi_editorial_overrides`

Legacy tables such as `poi_aliases`, `poi_source_links`, `poi_tags`, and
`poi_quality_flags` remain available for the current importer and repository
until the next import contract migration.

## Known Risks

- Existing import scripts still target the POI-0.1 tables and do not populate
  all MVP tables yet.
- `pois.primary_category_key` is nullable during transition so old data remains
  valid; future imports should populate it.
- `poi_import_batches`, `poi_import_issues`, and `poi_editorial_overrides` have
  RLS enabled without client read/write policies; they are intended for
  service-role tooling/admin workflows.
- Media, opening hours, and Google Places enrichment rules still need separate
  schema work before runtime enrichment is enabled.
- Destination identity remains split across existing Dart registries until a
  dedicated destination schema/repository is implemented.
