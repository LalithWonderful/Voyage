# Singapore snapshot comparison

- **Baseline** : `test/snapshots/singapore_baseline.json`
- **Current**  : `test/snapshots/singapore_baseline.json`
- **Verdict**  : **PASS**

## Volume

| Metric | Baseline | Current | Delta |
|---|---:|---:|---:|
| Visits | 18 | 18 | +0 |
| Meals | 4 | 4 | — |
| Slots | 22 | 22 | — |
| Active days | 7 | 7 | — |
| Free days | 1 | 1 | — |
| Visits change % | — | — | +0.0 % |

## Quality scores

| Score | Baseline | Current | Delta | Status |
|---|---:|---:|---:|:---:|
| overall | 82.0 | 82.0 | +0.0 | OK |
| coherence | 82.3 | 82.3 | +0.0 | OK |
| diversity | 35.5 | 35.5 | +0.0 | OK |
| repetition | 100.0 | 100.0 | +0.0 | OK |
| transition | 92.2 | 92.2 | +0.0 | OK |
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
| Avg inter-slot (m) | 1303.3 | 1303.3 | +0.0 |
| Max inter-slot (m) | 10554.7 | 10554.7 | +0.0 |

## Days

| Date | Slots (b → c) | Visits (b → c) | Meals (b → c) |
|---|:---:|:---:|:---:|
| 2026-05-18 | 3 → 3 | 3 → 3 | 0 → 0 |
| 2026-05-19 | 4 → 4 | 4 → 4 | 0 → 0 |
| 2026-05-20 | 3 → 3 | 2 → 2 | 1 → 1 |
| 2026-05-21 | 4 → 4 | 4 → 4 | 0 → 0 |
| 2026-05-22 | 2 → 2 | 0 → 0 | 2 → 2 |
| 2026-05-23 | 3 → 3 | 2 → 2 | 1 → 1 |
| 2026-05-24 | 1 → 1 | 1 → 1 | 0 → 0 |
| 2026-05-25 | 2 → 2 | 2 → 2 | 0 → 0 |

## Verdict reasons

_None._
---

> ⚠️ **Note Google Places** : ce snapshot dépend de la Google Places API. 
> Des variations entre runs (visites différentes, scores légèrement différents) 
> peuvent être non fonctionnelles (rotation API, cache, etc.). Le comparateur 
> est tolérant : seuls les écarts dépassant les seuils Phase 0 déclenchent 
> WARN/FAIL. Voir `docs/migrations/phase0_task0_4.md` pour les seuils exacts.
