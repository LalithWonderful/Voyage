# Singapore snapshot comparison

- **Baseline** : `test/snapshots/singapore_baseline.json`
- **Current**  : `test/snapshots/singapore_baseline.json`
- **Verdict**  : **PASS**

## Volume

| Metric | Baseline | Current | Delta |
|---|---:|---:|---:|
| Visits | 22 | 22 | +0 |
| Meals | 4 | 4 | — |
| Slots | 26 | 26 | — |
| Active days | 8 | 8 | — |
| Free days | 0 | 0 | — |
| Visits change % | — | — | +0.0 % |

## Quality scores

| Score | Baseline | Current | Delta | Status |
|---|---:|---:|---:|:---:|
| overall | 81.1 | 81.1 | +0.0 | OK |
| coherence | 73.8 | 73.8 | +0.0 | OK |
| diversity | 42.5 | 42.5 | +0.0 | OK |
| repetition | 100.0 | 100.0 | +0.0 | OK |
| transition | 89.1 | 89.1 | +0.0 | OK |
| coverage | 100.0 | 100.0 | +0.0 | OK |

## Places

- Removed (baseline → ∅) : **0**
- Added   (∅ → current)  : **0**
- Change ratio : 0.0 %
- Repeated in baseline : 2
- Repeated in current  : 2

## Distances

| Metric | Baseline | Current | Delta |
|---|---:|---:|---:|
| Avg inter-slot (m) | 1529.2 | 1529.2 | +0.0 |
| Max inter-slot (m) | 10982.9 | 10982.9 | +0.0 |

## Days

| Date | Slots (b → c) | Visits (b → c) | Meals (b → c) |
|---|:---:|:---:|:---:|
| 2026-05-18 | 4 → 4 | 4 → 4 | 0 → 0 |
| 2026-05-19 | 3 → 3 | 3 → 3 | 0 → 0 |
| 2026-05-20 | 2 → 2 | 1 → 1 | 1 → 1 |
| 2026-05-21 | 4 → 4 | 4 → 4 | 0 → 0 |
| 2026-05-22 | 4 → 4 | 4 → 4 | 0 → 0 |
| 2026-05-23 | 3 → 3 | 2 → 2 | 1 → 1 |
| 2026-05-24 | 3 → 3 | 2 → 2 | 1 → 1 |
| 2026-05-25 | 3 → 3 | 2 → 2 | 1 → 1 |

## Verdict reasons

_None._
---

> ⚠️ **Note Google Places** : ce snapshot dépend de la Google Places API. 
> Des variations entre runs (visites différentes, scores légèrement différents) 
> peuvent être non fonctionnelles (rotation API, cache, etc.). Le comparateur 
> est tolérant : seuls les écarts dépassant les seuils Phase 0 déclenchent 
> WARN/FAIL. Voir `docs/migrations/phase0_task0_4.md` pour les seuils exacts.
