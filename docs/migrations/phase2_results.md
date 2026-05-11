# Phase 2 Results — SameComplexDedup A/B Validation

## Contexte

Tâche 2.5 du plan de refonte. Tâche **purement de mesure /
documentation / validation**. Conformément à la spec :
- aucune nouvelle logique métier ;
- aucune modification du pipeline production ;
- aucune modification du sélecteur ;
- aucune modification du modèle `SameComplexGroup`, du matcher,
  des données Singapour ;
- le flag `useSameComplexDedup` **reste OFF par défaut**.

L'objectif est de produire une comparaison A/B observable entre :
- **OFF** : `useSameComplexDedup = false` (comportement
  pré-Phase 2, baseline officielle)
- **ON**  : `useSameComplexDedup = true` (dédup complexe activée
  derrière le flag)

pour décider si la déduplication peut être activée par défaut
plus tard et à quelles conditions.

## Méthodologie

Sur le trip baseline standard (Singapour 18/05/2026 →
25/05/2026, Couple, 800 €, public_transport, 5 intérêts) :

1. **Run flag OFF** via :
   ```
   flutter test test/snapshots/generate_baseline.dart
   ```
   → résultat capturé dans
   [`test/snapshots/singapore_phase2_off.json`](../../test/snapshots/singapore_phase2_off.json).
2. **Run flag ON** via :
   ```
   flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
     test/snapshots/generate_baseline.dart
   ```
   → résultat capturé dans
   [`test/snapshots/singapore_phase2_on.json`](../../test/snapshots/singapore_phase2_on.json).
3. **Restauration canonical OFF** : un 3ᵉ run flag OFF pour que
   `test/snapshots/singapore_baseline.json` (le baseline
   officiel) reste l'état OFF.

### Limites de l'A/B

Le pipeline appelle la **vraie API Google Places**. Les runs ne
sont **pas strictement déterministes** :
- rotation Google Places (résultats légèrement différents d'un
  run à l'autre)
- cache Gemini / Supabase qui se réchauffe entre runs
- Variations attendues : ±2 pts sur `overall_score`, ±1-2
  visites, quelques substitutions de lieux

→ **Les variations < 3 pts ne sont pas attribuables à la
dédup** ; elles entrent dans la marge Google Places observée
depuis Tâche 0.1. Une vraie validation rigoureuse nécessiterait
≥ 5 runs OFF + ≥ 5 runs ON et une analyse statistique. Ce
rapport présente **un seul couple OFF/ON** ; il est suffisant
pour observer le **mécanisme** (rejet `same_complex_cap`,
substitutions), pas pour conclure définitivement sur la
qualité.

### Artefacts produits

| Fichier | Rôle |
|---------|------|
| [`test/snapshots/singapore_phase2_off.json`](../../test/snapshots/singapore_phase2_off.json) | Copie du baseline généré flag OFF — référence A/B |
| [`test/snapshots/singapore_phase2_on.json`](../../test/snapshots/singapore_phase2_on.json) | Copie du baseline généré flag ON — variante A/B |
| `test/snapshots/singapore_baseline.json` | **Baseline officielle** (reste en état OFF, restaurée par 3ᵉ run) |

Ces 2 artefacts dédiés Phase 2 ne sont **pas régénérés
automatiquement** par les commandes standard. Ils servent
uniquement à documenter le couple OFF/ON observé en Tâche 2.5.
Pour les régénérer manuellement (audit ou validation future) :

```bash
flutter test test/snapshots/generate_baseline.dart
cp test/snapshots/singapore_baseline.json \
   test/snapshots/singapore_phase2_off.json

flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
  test/snapshots/generate_baseline.dart
cp test/snapshots/singapore_baseline.json \
   test/snapshots/singapore_phase2_on.json

flutter test test/snapshots/generate_baseline.dart   # restore
```

## Résultat flag OFF

| Champ | Valeur |
|-------|--------|
| `overall_score` | **81.46** |
| `coherence` | 82.11 |
| `diversity` | 33.14 |
| `repetition` | 100.00 |
| `transition` | 92.07 |
| `coverage` | 100.00 |
| visites | 18 |
| repas | 4 |
| slots totaux | 22 |
| jours actifs | 8 / 8 |
| jours vides (free) | 1 |
| avg inter-slot dist | 1457 m |
| logs `places_complex_dedup_reject` | **0** |

## Résultat flag ON

| Champ | Valeur |
|-------|--------|
| `overall_score` | **81.76** |
| `coherence` | 81.86 |
| `diversity` | 34.99 |
| `repetition` | 100.00 |
| `transition` | 91.93 |
| `coverage` | 100.00 |
| visites | 18 |
| repas | 4 |
| slots totaux | 22 |
| jours actifs | 8 / 8 |
| jours vides (free) | 1 |
| avg inter-slot dist | 1322 m |
| logs `places_complex_dedup_reject` | **1** |

Log observé :
```
[places_complex_dedup_reject] name="Singapore Oceanarium"
  complex=sentosa strategy=exactName
  reason=same_complex_cap_day day=2026-05-20 count=1/1
```

## Comparaison scores

| Metric | OFF | ON | Delta | Lecture |
|--------|----:|---:|------:|---------|
| `overall_score` | 81.46 | 81.76 | **+0.29** | Neutre — dans la marge Google Places |
| `coherence` | 82.11 | 81.86 | -0.25 | Neutre |
| `diversity` | 33.14 | 34.99 | **+1.85** | Légère amélioration |
| `repetition` | 100.00 | 100.00 | 0.00 | Inchangé |
| `transition` | 92.07 | 91.93 | -0.13 | Neutre |
| `coverage` | 100.00 | 100.00 | 0.00 | **Inchangé** — aucune journée vide créée |
| avg inter-slot dist | 1457 m | 1322 m | **-135 m** | Marche moins longue entre activités |

**Lecture globale** : aucun score ne dégrade significativement.
Coverage et repetition strictement préservés. Diversité +1.85 pts
attendue car la dédup force le remplacement d'une attraction
Sentosa par une attraction d'un autre thème.

## Comparaison volumétrie

| Metric | OFF | ON | Delta |
|--------|----:|---:|------:|
| visites | 18 | 18 | 0 |
| repas | 4 | 4 | 0 |
| slots totaux | 22 | 22 | 0 |
| jours actifs | 8 | 8 | 0 |
| jours vides (free) | 1 | 1 | 0 |
| visites par jour | 3/4/2/4/2/1/2 | 3/4/2/4/2/1/2 | inchangé |

**Verdict couverture** : ✅ PASS. La dédup ne crée aucune
journée vide ni baisse de couverture. Le sélecteur remplace les
candidats rejetés par d'autres lieux disponibles dans la pool.

## Lieux ajoutés / retirés

| Côté | Lieux |
|------|-------|
| **OFF only** | Cloud Forest · Indian Heritage Centre · Singapore Oceanarium |
| **ON only**  | Fort Canning Tree Tunnel · Musée national de Singapour · Wings of Time Fireworks Symphony |

3 substitutions sur 18 visites (17%). Les substitutions ON sont
qualitativement cohérentes (musée national, parc fort canning,
spectacle nocturne Wings of Time).

**Repas identiques** OFF et ON (Nummun Thai Kitchen + SOD Cafe ×
2 jours) — la dédup n'agit pas sur les repas (Tâche 2.4 spec : le
filter est dans le picker des visites uniquement).

## Rejets `same_complex_cap` observés

| reason | complexKey | candidate | day | count | max |
|--------|-----------|-----------|-----|------:|----:|
| `same_complex_cap_day` | `sentosa` | Singapore Oceanarium | 2026-05-20 | 1 | 1 |

**1 seul rejet** observable sur ce run. Cela ne reflète pas la
totalité de l'impact (cf. analyse par complexe ci-dessous) — les
2 autres substitutions OFF→ON ne déclenchent pas de log car
elles sont dues à un **réordonnancement du scoring** induit par
l'absence de Sentosa Oceanarium (et non à un rejet direct).

## Analyse par complexe

Comptage heuristique par substring (peut sur-compter, mais
suffisant pour observer les tendances) :

| complexKey | OFF | ON | Δ | Notes |
|------------|----:|---:|--:|-------|
| `sentosa` | 4 | 4 | 0 | Substitution Singapore Oceanarium → Wings of Time Fireworks Symphony |
| `gardens_by_the_bay` | 2 | 1 | **-1** | Cloud Forest disparaît ; Supertree Grove conservé |
| `marina_bay_sands` | 1 | 1 | 0 | ArtScience Museum stable |
| `chinatown_heritage` | 1 | 1 | 0 | Buddha Tooth Relic Temple stable |
| `clarke_quay_riverside` | 0 | 0 | 0 | Aucun pick dans la pool |
| `orchard_shopping` | 1 | 1 | 0 | Orchard Road stable |

### sentosa (cap maxPerTrip=2, observé 4 visites en OFF *côté heuristique*)

Le comptage substring annonce 4 visites Sentosa dans les 2 runs.
**Mais le matcher réel ne reconnaît pas tous ces titres** :
- "Sentosa" (seul) : normalisé `sentosa`, similarité avec
  l'alias normalisé `sentosa island` = `1 - 7/14 = 0.50` → **non
  matché** (< 0.85, false negative)
- "Wings of Time Fireworks Symphony" : normalisé 32 chars vs
  l'alias `wings of time` 13 chars → similarité ≈ 0.41 → **non
  matché** (false negative)

→ **Côté matcher**, les compteurs sont :
- OFF : Universal Studios + Singapore Oceanarium + Madame
  Tussauds = **3** sentosa matchés (> maxPerTrip=2, mais
  flag OFF court-circuite le cap)
- ON : Universal Studios + Madame Tussauds = **2** sentosa
  matchés (cap maxPerTrip=2 respecté ✅)

Le cap fait bien son travail : **3 → 2 sentosa picks**. Mais le
matcher a 2 false negatives sur ce dataset, ce qui dilue
l'effet visible.

### gardens_by_the_bay (cap maxPerDay=1, maxPerTrip=2)

- OFF : Supertree Grove + Cloud Forest (2 picks, ≤ maxPerTrip=2)
- ON : Supertree Grove seul

Cloud Forest probablement bloqué par cap day (Supertree Grove
pris le même jour) ou trip. Pas de log capturé pour cette
rejection (la pool peut avoir présenté Cloud Forest sur un slot
où d'autres caps ont été appliqués en premier).

### Autres complexes

Marina Bay Sands, Chinatown, Orchard : 1 pick chacun en OFF et
ON → sous les caps même en OFF, donc invariant.

## Risques observés

1. **False negatives du matcher** (vu ci-dessus) :
   - "Sentosa" seul, "Wings of Time Fireworks Symphony" non
     reconnus comme `sentosa`.
   - **Conséquence** : un pick "humainement Sentosa" peut passer
     malgré le cap. C'est un **trade-off conscient** : refuser
     le matching trop permissif (cf. Tâche 2.3 : test "Bay" →
     null pour rejeter substring). La piste future est d'ajouter
     ces noms comme aliases explicites (cf. recommandation
     ci-dessous), pas d'élargir la stratégie fuzzy.

2. **1 seul rejet observable** sur le run. Le mécanisme **agit**
   (Singapore Oceanarium bloquée), mais la quantification fine
   nécessiterait des runs multiples + un dataset plus dense en
   collisions sentosa.

3. **Variations Google Places** entre runs OFF et ON : les 2
   autres substitutions (Cloud Forest, Indian Heritage Centre)
   peuvent partiellement venir de cette variation, pas
   uniquement de la dédup. Difficile à isoler sans plusieurs
   runs.

4. **Pas testé sur les autres destinations** (Bangkok, Tokyo,
   Paris, Hong Kong, Dubai, Bali, …). Les complexes connus
   sont uniquement Singapour (Tâche 2.2). Pour d'autres
   destinations, `loadLocalComplexGroupsForDestination`
   retourne `[]` → no-op total.

## Recommandation

| Aspect | Verdict |
|--------|---------|
| Mécanisme fonctionne | ✅ OUI |
| Coverage préservée | ✅ OUI |
| Scores stables | ✅ OUI (overall +0.29, diversity +1.85) |
| Effet observable | ✅ OUI (rejet `same_complex_cap_day` loggé, substitution sentosa) |
| Validé sur 3+ destinations | ❌ NON (Singapour uniquement) |
| Effets de bord sur d'autres destinations | ❌ Non testés |

**Recommandation finale** :

> 🟡 **Activable en expérimentation contrôlée sur Singapour
> (via dart-define ou override Supabase ciblé). Garder OFF par
> défaut globalement** tant que :
> 1. Le matcher false-negative sur "Sentosa" / "Wings of Time
>    Fireworks Symphony" n'est pas résolu (élargir la liste
>    d'aliases ou ajouter une stratégie préfixe contrôlée).
> 2. La dédup n'est pas testée sur au moins **3 destinations
>    distinctes** (Singapour + 2 autres parmi Bangkok / Tokyo /
>    Paris / Hong Kong).
> 3. Les substitutions ON sont validées qualitativement par
>    un humain (Wings of Time Fireworks Symphony à la place
>    de Singapore Oceanarium : est-ce un pick désirable pour
>    un voyageur Couple ?).

**Cohérent avec règle d'or 1** : *« Toute nouvelle logique doit
être derrière un feature flag, désactivé par défaut. »* — le
flag reste OFF tant que validation multi-destinations non
faite.

## Validations exécutées

```
flutter analyze
  35 issues info préexistants (Tâche 0.1) — INCHANGÉ
  0 nouveau warning/error.

flutter test
  746 tests verts (inchangé vs Tâche 2.4).

flutter test test/snapshots/generate_baseline.dart   (OFF)
  → overall 81.46 / 18 visites / coverage 100%
  → 0 log [places_complex_dedup_reject]
  → comparator self-check : PASS

flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
  test/snapshots/generate_baseline.dart   (ON)
  → overall 81.76 / 18 visites / coverage 100%
  → 1 log [places_complex_dedup_reject] :
    Singapore Oceanarium / sentosa / same_complex_cap_day
  → comparator self-check : PASS

flutter test test/snapshots/generate_baseline.dart   (restore OFF)
  → baseline canonical restauré, overall 82.78
  → comparator self-check : PASS
```

## Confirmation des invariants

- ✅ `FeatureFlags.useSameComplexDedup` **reste OFF par défaut**
  (aucune modification `lib/config/feature_flags.dart`).
- ✅ **Pipeline production non modifié** (aucune modification
  `lib/features/planning/services/places_first_pipeline.dart`).
- ✅ **Sélecteur non modifié** (aucune modification de
  `selectVisitsDeterministic`).
- ✅ **Modèle `SameComplexGroup`** intact.
- ✅ **Données Singapour complexes** intactes.
- ✅ **Matcher** `complex_matcher.dart` intact.
- ✅ Aucun nouveau fichier de logique métier — uniquement
  documentation et artefacts d'observation.

## Conclusion

**Phase 2 est techniquement validée** :
- 4 tâches livrées et validées indépendamment (2.1 modèle,
  2.2 données, 2.3 matcher, 2.4 intégration flag-gated).
- 746 tests verts ; 35 issues info préexistants inchangés.
- Mécanisme observable : rejet `same_complex_cap_day` capturé
  en run réel Singapour.
- Coverage 100% préservée en flag ON.
- Scores quasi-identiques (overall +0.29) — pas de
  dégradation.

**Phase 2 n'est PAS encore prête pour activation par défaut** :
- Validation sur Singapour uniquement.
- 2 false negatives du matcher identifiés ("Sentosa" seul,
  "Wings of Time Fireworks Symphony").
- 1 seul rejet observable par run baseline (insuffisant pour
  conclure sur l'impact qualitatif réel).

**Prochaines étapes possibles (hors scope Phase 2)** :
1. Phase 3 — `DestinationScope` (selon plan refonte).
2. Extension `complex_registry.dart` à 2-3 destinations
   supplémentaires pour valider sur d'autres patterns
   (Bangkok / Tokyo / Paris).
3. Élargissement aliases pour réduire false negatives
   (`Sentosa` seul, `Wings of Time Fireworks Symphony`,
   variantes commerciales).
4. Étude d'une stratégie matching `prefix` contrôlée (où
   `wings of time` matcherait le préfixe d'un titre plus
   long) — risque/bénéfice à mesurer.
