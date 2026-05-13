# Mixed Commit ff61e43 Separation Report

Date: 2026-05-13

## 1. Executive Summary

Commit `ff61e43d42f35e9d1b5e988dc574ae2d5aac70f0` is a mixed commit already
pushed to `main`. It contains the intended POI repository provider seam, but it
also includes unrelated trip UX work, planning sheet UI changes, debug routing,
API-cost audit documents, and binary artifacts.

The POI provider seam appears technically valid as a local/offline default:
`poiRepositoryProvider` now exposes `PoiRepository` through a lazy fixture-backed
implementation, and tests cover Paris/Lisbon reads plus provider overrides.
However, the commit is not atomic. Because it is already pushed to `main`, a
history rewrite is not recommended; traceability should be restored through this
report and any future corrective work should be made in new commits.

## 2. Commit Metadata

| Field | Value |
| --- | --- |
| Commit | `ff61e43d42f35e9d1b5e988dc574ae2d5aac70f0` |
| Short hash | `ff61e43` |
| Author | `Lalith <lalith.lou@googlemail.com>` |
| Author date | `Wed May 13 18:50:10 2026 +0200` |
| Commit date | `Wed May 13 18:50:10 2026 +0200` |
| Subject | `TRIP-UX-0.2: clarify title vs destination in trip edit sheet` |
| Files changed | 14 |
| Insertions/deletions | 1663 insertions, 451 deletions, plus binary files |

Commands used for inspection:

```sh
git show --name-status ff61e43
git show --stat ff61e43
git show ff61e43 -- <relevant files>
```

## 3. Changed Files Table

| File | Status | Change size |
| --- | --- | ---: |
| `REFONTE_PLAN.md.pages` | Added | binary, 309699 bytes |
| `docs/api_cost/api_0_6_places_autocomplete_guard_inventory.md` | Added | 189 insertions |
| `docs/api_cost/remaining_live_api_audit_2026_05_13.md` | Added | 83 insertions |
| `flutter_01.png` | Added | binary, 153698 bytes |
| `lib/core/router/app_router.dart` | Modified | 61 insertions, 22 deletions |
| `lib/features/planning/widgets/activity_detail_sheet.dart` | Modified | 389 insertions, 127 deletions |
| `lib/features/planning/widgets/alternatives_sheet.dart` | Modified | 170 insertions, 43 deletions |
| `lib/features/planning/widgets/suggestion_detail_sheet.dart` | Modified | 180 insertions, 37 deletions |
| `lib/features/poi/providers/poi_repository_provider.dart` | Modified | 80 insertions, 8 deletions |
| `lib/features/profile/screens/profile_screen.dart` | Modified | 11 insertions |
| `lib/features/trips/screens/trips_screen.dart` | Modified | 328 insertions, 131 deletions |
| `lib/features/trips/widgets/trip_edit_sheet.dart` | Modified | 98 insertions, 65 deletions |
| `test/poi/poi_providers_test.dart` | Modified | 9 insertions, 18 deletions |
| `test/poi/poi_repository_provider_test.dart` | Added | 65 insertions |

## 4. Classification Table

| File | Classification | Summary | Risk | Recommended action |
| --- | --- | --- | --- | --- |
| `lib/features/poi/providers/poi_repository_provider.dart` | POI provider task-related | Replaces empty fake default with lazy `FixturePoiRepository` default while keeping `PoiRepository` abstraction overrideable. | Medium | Keep, but follow up on runtime asset/file loading before app-wide use. |
| `test/poi/poi_providers_test.dart` | POI provider task-related | Updates default provider expectations from empty fake to local Paris/Lisbon fixtures; includes formatting churn. | Low | Keep. Consider minimizing formatting churn in future test-only changes. |
| `test/poi/poi_repository_provider_test.dart` | POI provider task-related | Adds provider seam tests for repository type, Paris/Lisbon reads, and fake override. | Low | Keep. |
| `REFONTE_PLAN.md.pages` | Unrelated WIP | Adds a binary Pages document unrelated to provider seam. | Medium | Leave in pushed commit; decide separately whether binary planning docs belong in repo. |
| `docs/api_cost/api_0_6_places_autocomplete_guard_inventory.md` | Unrelated WIP | Adds API-cost/Places autocomplete audit inventory. | Low | Leave or move into a separate docs cleanup commit if needed. |
| `docs/api_cost/remaining_live_api_audit_2026_05_13.md` | Unrelated WIP | Adds remaining live API audit report. | Low | Leave; useful documentation but unrelated to provider task. |
| `flutter_01.png` | Unrelated WIP | Adds a binary screenshot/image artifact. | Medium | Review whether the asset should remain tracked. |
| `lib/core/router/app_router.dart` | Unrelated WIP | Adds POI debug route and broad formatting changes. | Medium | Keep if debug route is intended; otherwise revert in a new forward commit. Test debug route access. |
| `lib/features/profile/screens/profile_screen.dart` | Unrelated WIP | Adds debug-only POI navigation entry under profile. | Medium | Keep only if debug POI screen exposure is intended. Verify gated by `kDebugMode`. |
| `lib/features/planning/widgets/activity_detail_sheet.dart` | Unrelated WIP | Large planning sheet formatting/structure changes; keeps Places/photo/map-related code paths present. | Medium | Review separately with targeted UI tests because diff is large and unrelated. |
| `lib/features/planning/widgets/alternatives_sheet.dart` | Unrelated WIP | Large alternatives sheet formatting/structure changes; includes Supabase update path already present in this flow. | Medium | Review separately with targeted tests; do not conflate with POI provider seam. |
| `lib/features/planning/widgets/suggestion_detail_sheet.dart` | Unrelated WIP | Large suggestion detail sheet formatting/structure changes. | Medium | Review separately with widget tests or manual QA. |
| `lib/features/trips/screens/trips_screen.dart` | Unrelated WIP | Large trips screen formatting/UX changes around list display, empty states, deletion handling. | Medium | Review separately with trip screen tests/manual QA. |
| `lib/features/trips/widgets/trip_edit_sheet.dart` | Unrelated WIP | Implements trip title/destination UX changes described by commit subject. | Medium | Treat as the actual `TRIP-UX-0.2` work; validate separately. |

## 5. POI Provider-Related Changes

The POI provider task-related subset is:

- `lib/features/poi/providers/poi_repository_provider.dart`
- `test/poi/poi_providers_test.dart`
- `test/poi/poi_repository_provider_test.dart`

Observed provider behavior:

- `poiRepositoryProvider` remains a synchronous Riverpod `Provider<PoiRepository>`.
- The default implementation is now `LazyFixturePoiRepository.loadDefaultFixtures()`.
- `LazyFixturePoiRepository` defers fixture file loading until a repository method
  is called.
- The provider is still overrideable with `poiRepositoryProvider.overrideWithValue`.
- No Supabase, Google Places, Overpass, Gemini, or credential path is introduced.

Technical validity:

- The seam is valid for offline tests and local fixture-backed development.
- It preserves the existing `PoiRepository` abstraction used by downstream
  POI providers.
- It intentionally does not integrate planning, Supabase runtime reads, or
  Google Places.

Known technical caveat:

- The lazy provider loads fixtures through local file paths. That is safe for
  tests and local development, but production Flutter runtime asset loading may
  need a future `rootBundle`/asset-bundle implementation plus explicit
  `pubspec.yaml` asset registration. This should be addressed before relying on
  the provider in packaged app runtime.

Previously reported provider validation:

```sh
flutter test test/poi/poi_repository_provider_test.dart test/poi/poi_providers_test.dart
flutter analyze lib/features/poi/providers/poi_repository_provider.dart test/poi/poi_repository_provider_test.dart test/poi/poi_providers_test.dart
git diff --check -- lib/features/poi/providers/poi_repository_provider.dart test/poi/poi_repository_provider_test.dart test/poi/poi_providers_test.dart
```

Assessment: these tests are sufficient for the provider seam itself. Additional
tests are recommended only when the provider is wired into runtime planning or
when asset-bundle loading replaces local file loading.

## 6. Unrelated WIP Changes

The unrelated files fall into these groups:

- Trip UX: `lib/features/trips/widgets/trip_edit_sheet.dart`
- Trips list/profile/router/debug UI: `lib/features/trips/screens/trips_screen.dart`,
  `lib/features/profile/screens/profile_screen.dart`,
  `lib/core/router/app_router.dart`
- Planning sheets: `activity_detail_sheet.dart`, `alternatives_sheet.dart`,
  `suggestion_detail_sheet.dart`
- API-cost documentation: two files under `docs/api_cost/`
- Binary artifacts: `REFONTE_PLAN.md.pages`, `flutter_01.png`

These changes may be valid product work, but they were not part of the POI
repository provider task. They should be reviewed and tested as separate topics.

## 7. Uncertain Changes

No files are classified as uncertain. Some files are POI-adjacent, such as the
debug route/profile link, but they are still unrelated to the requested provider
seam because the task explicitly said not to integrate planning/runtime behavior.

## 8. Functional Risk Assessment

Overall functional risk of the mixed commit: **medium**.

Risk drivers:

- The POI provider seam itself is low-to-medium risk: it is offline and
  covered by focused tests, but defaulting to local file fixture loading may not
  be production-runtime safe until asset loading is formalized.
- The trip/planning UI changes are broad and touch user-facing flows. They may
  be correct, but they need separate validation because they were not reviewed
  as part of the POI provider task.
- `app_router.dart` and `profile_screen.dart` expose a debug POI path in debug
  mode. That should be intentional and checked against release builds.
- Binary artifacts in the commit increase repository hygiene risk and may not
  belong in source control.

No new live API path was identified in the POI provider-related subset.

## 9. Git Hygiene Assessment

The commit is not atomic. It combines at least three work streams:

- POI provider seam.
- Trip title/destination UX.
- Miscellaneous planning/debug/docs/assets WIP.

Because `ff61e43` was already pushed to `main`, rewriting history would create
coordination risk for anyone who pulled the commit. A revert or split can still
be done with forward-only commits if a specific subset needs removal, but the
published commit itself should be left intact.

History rewrite is not recommended because:

- It would require force-pushing `main`.
- It could invalidate collaborators' local histories.
- The commit contains potentially useful work from multiple streams.
- Traceability can be restored with this report and follow-up commits.

## 10. Recommended Decision

Leave `ff61e43` as-is on `main`.

Recommended follow-ups:

1. Treat this report as the traceability record for the mixed commit.
2. Review trip UX changes in a separate forward-only QA task.
3. Review planning sheet changes in a separate forward-only QA task.
4. Decide whether `REFONTE_PLAN.md.pages` and `flutter_01.png` should remain in
   the repository; if not, remove them in a new forward commit.
5. Before wiring the POI provider into runtime planning, add an asset-bundle
   loading seam or explicitly document that it is test/local-only.

## 11. Prevention Rules Now Adopted

- One agent = one worktree = one branch = one task.
- No shared `/Users/lalith/Projets/Voyage` worktree for coding agents.
- No `git add .`.
- No `git add -A`.
- No `git commit -am`.
- Integration only from main worktree.

