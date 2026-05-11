# Phase 4 A/B Test — Template-first vs Places-first

## Contexte

Tâche 4.6 du plan de refonte. Tâche **purement d'analyse et
documentation** : aucune nouvelle logique, aucune modification
du pipeline, aucun fichier de production touché. Le flag
`useDayTemplates` reste **OFF par défaut**.

L'objectif est de produire une comparaison **A/B chiffrée** du
baseline Singapour entre :
- **OFF** : pipeline places-first legacy (V8.28+, l'état
  pré-Phase-4)
- **ON** : pipeline template-first livré en Tâche 4.5

et de recommander une stratégie d'activation.

## Méthodologie

Trois runs sur le baseline Singapour 18-25/05/2026 (Couple,
800 €, public_transport) :

1. **Places-first OFF** :
   ```bash
   flutter test test/snapshots/generate_baseline.dart
   cp test/snapshots/singapore_baseline.json \
      test/snapshots/singapore_phase4_places_first.json
   ```
2. **Template-first ON** :
   ```bash
   flutter test --dart-define=USE_DAY_TEMPLATES=true \
     test/snapshots/generate_baseline.dart
   cp test/snapshots/singapore_baseline.json \
      test/snapshots/singapore_phase4_template_first.json
   ```
3. **Restauration canonical OFF** (3ᵉ run flag OFF) pour que
   `singapore_baseline.json` reste l'état OFF.

### Limites méthodologiques

- **Pipeline hit Google Places réel** → non strictement
  déterministe. Variations attendues ±2 pts overall, ±1-2
  visites (cf. Tâche 0.1).
- **Un seul couple OFF/ON** sur Singapour. Pour conclure
  statistiquement il faudrait ≥ 5 runs OFF + ≥ 5 ON et une
  analyse multi-destinations. Ce rapport suffit pour observer
  les **mécanismes**, pas pour conclure définitivement.
- **Aucune validation utilisateur réel** : pas de feedback
  qualité subjective, seulement les métriques `planning_metrics`.
- **Pas d'isolation des autres flags** : `useSameComplexDedup` et
  `useDestinationScope` sont OFF dans les 2 runs (A/B principal
  isolé sur `useDayTemplates`).

### Artefacts produits

| Fichier | Rôle |
|---------|------|
| [`test/snapshots/singapore_phase4_places_first.json`](../../test/snapshots/singapore_phase4_places_first.json) | Run OFF capturé — référence A/B |
| [`test/snapshots/singapore_phase4_template_first.json`](../../test/snapshots/singapore_phase4_template_first.json) | Run ON capturé — variante A/B |
| `test/snapshots/singapore_baseline.json` | Baseline officielle (canonical OFF, restaurée 3ᵉ run) |

## Résultat places-first (flag OFF)

```
overall_score    : 81.97
coherence        : 82.89
diversity        : 34.41
repetition       : 100.00
transition       : 92.53
coverage         : 100.00
visites          : 19
repas            : 4
slots totaux     : 23
jours actifs     : 8/8
free_days_count  : 1
avg inter-slot   : 1255 m
long transitions (>5km) : 0
```

## Résultat template-first (flag ON)

```
overall_score    : 74.87
coherence        : 52.52
diversity        : 44.67
repetition       : 100.00
transition       : 77.16
coverage         : 100.00
visites          : 29
repas            : 4
slots totaux     : 33
jours actifs     : 8/8
free_days_count  : 0
avg inter-slot   : 5174 m
long transitions (>5km) : 12
```

Log observé :
```
[template_first_pipeline] using template-first 29 visits
```

## Comparaison scores

| Metric | Places-first | Template-first | Delta | Lecture |
|--------|-------------:|---------------:|------:|---------|
| `overall_score` | 81.97 | 74.87 | **-7.10** | **Dégradation nette** |
| `coherence` | 82.89 | 52.52 | **-30.37** | **Dégradation catastrophique** |
| `diversity` | 34.41 | 44.67 | **+10.26** | Amélioration nette |
| `repetition` | 100.00 | 100.00 | 0.00 | Inchangé |
| `transition` | 92.53 | 77.16 | **-15.37** | **Dégradation forte** |
| `coverage` | 100.00 | 100.00 | 0.00 | Inchangé |

**Lecture globale** : template-first ajoute de la diversité
(+10) mais **détruit la cohérence** (-30) et les transitions
(-15). Overall -7 points → dégradation nette malgré la
diversité.

## Comparaison volumétrie

| Metric | Places-first | Template-first | Delta |
|--------|-------------:|---------------:|------:|
| visites | 19 | 29 | **+10 (+53%)** |
| repas | 4 | 4 | 0 |
| slots totaux | 23 | 33 | +10 |
| jours actifs | 8/8 | 8/8 | 0 |
| jours avec activité | 7 | 8 | +1 |
| free_days | 1 | **0** | -1 |

**Verdict** : template-first **sur-remplit** le planning.
29 visites vs 19 (+53%). Le `free_day` du template est
**rempli** par des activités au lieu d'être respecté →
contradiction avec l'intention éditoriale du template
`free_day`.

## Répartition par jour

| Date | OFF visites | ON visites | Template ON probable |
|------|------------:|-----------:|----------------------|
| 2026-05-18 | 3 | 3 | arrival_day |
| 2026-05-19 | 3 | 4 | marina_bay_day |
| 2026-05-20 | 4 | 4 | chinatown_civic_day |
| 2026-05-21 | 4 | 4 | orchard_botanic_day |
| 2026-05-22 | **0** | 4 | little_india_kampong_day |
| 2026-05-23 | 2 | 4 | sentosa_day |
| 2026-05-24 | 2 | 3 | free_day (rempli !) |
| 2026-05-25 | 1 | 3 | departure_day |

**Observations** :
- OFF a 1 journée vide (2026-05-22) — le legacy ne réussit pas
  à remplir ce jour. ON la remplit (4 visites).
- ON remplit systématiquement les jours en fin de voyage (24,
  25) que le legacy laisse plus légers.
- `free_day` (2026-05-24) reçoit 3 visites en ON → **non
  respecté**.

## Templates assignés (déduits)

Sur 8 jours, le `DayThemeAssigner` (Tâche 4.3) produit
typiquement la séquence :

```
Day 0 : arrival_day
Day 1 : marina_bay_day
Day 2 : chinatown_civic_day
Day 3 : little_india_kampong_day  (ou orchard_botanic)
Day 4 : orchard_botanic_day
Day 5 : sentosa_day
Day 6 : free_day
Day 7 : departure_day
```

Cf. Tâche 4.3 doc. Le pattern des visites ON suggère cette
séquence est bien appliquée mais **les lieux sélectionnés ne
respectent pas la zone primaire** du template (cf. section
"Risques" ci-dessous).

## Lieux ajoutés / retirés / partagés

**Présents dans les 2 runs (7 lieux)** :
- Jardin botanique de Singapour
- Merlion Park
- Musée national de Singapour
- Orchard Road
- Singapore Cable Car
- Supertree Grove
- Universal Studios Singapore

**OFF only (12 lieux — disparaissent en ON)** :
- ArtScience Museum
- Buddha Tooth Relic Temple
- Fort Canning Tree Tunnel
- Galerie nationale de Singapour
- Madame Tussauds Singapore
- Musée Peranakan
- Rainforest Trail
- Sentosa
- Singapore Botanic Gardens Eco Lake
- Singapore Botanic Gardens Gallop Extension
- Singapore Flyer
- Singapore Oceanarium

**ON only (22 lieux — ajoutés en ON)** :
- **Hawker centres en visit slot** : Lau Pa Sat, Maxwell Food
  Centre ⚠️ (V8.28b1 hawker block absent)
- **Cafés / lieux secondaires** : Columbus Coffee Co., SOD
  Cafe, ToMo Cafe (Thomson), Hello Arigato, State Of Affairs
  ⚠️ (quality floor V8.28f absent)
- Cloud Forest, Dôme Floral, Jardins de la Baie, Marina Bay
  Sands, SkyPark Observation Deck, Chinatown Singapore,
  Clarke Quay, Fort Canning Park, CHIJMES (vrais POIs
  iconiques manquants en OFF)
- Mega Adventure - Singapore, Resorts World Sentosa, Skyline
  Luge, Skyline Luge Singapore (Sentosa attractions, doublon
  Skyline)
- Merlion (vs Merlion Park OFF — possible doublon sémantique)
- Wings of Time Fireworks Symphony

## Analyse distances / cohérence géographique

| Day | OFF tot/max km | OFF long>5km | ON tot/max km | ON long>5km |
|-----|---------------:|-------------:|--------------:|------------:|
| 2026-05-18 | 1.6 / 1.1 | 0 | 16.4 / 11.1 | **2** |
| 2026-05-19 | 2.1 / 1.5 | 0 | 16.2 / 8.0 | **2** |
| 2026-05-20 | 7.2 / 2.9 | 0 | 19.4 / 11.3 | **2** |
| 2026-05-21 | 1.8 / 0.8 | 0 | 17.8 / 6.7 | **2** |
| 2026-05-22 | 0.0 / 0.0 | 0 | 20.2 / 11.2 | **2** |
| 2026-05-23 | 0.5 / 0.5 | 0 | 7.0 / 5.4 | **1** |
| 2026-05-24 | 1.9 / 1.9 | 0 | 7.0 / 6.4 | **1** |
| 2026-05-25 | 0.0 / 0.0 | 0 | 4.7 / 2.4 | 0 |
| **TOTAL** | | **0** | | **12** |

**Verdict** : régression catastrophique sur les transitions.
- Avg inter-slot : **1255 m → 5174 m** (× 4.1)
- **0 → 12** transitions longues (>5km) sur le voyage
- Plusieurs hops de 8-11km en ON (vs max 2.9km en OFF)

Le pipeline legacy bénéficie de :
- V8.21 anti-zigzag slot-level (cap 5km mégacité)
- V8.23 coherence guard (rayon 5km du barycentre du jour)
- V8.26 second-pick guard (cap 5km depuis 1ᵉʳ pick)

**Aucun équivalent dans le template-first 4.5** → l'algorithme
de tri du builder priorise score + anchor match **sans tenir
compte de la distance**.

## Warnings / quality regressions

Régressions concrètes observées dans le run ON :

### 1. Hawker centres en visit slot (V8.28b1 absent)

OFF : 0 ; ON : **2** (Lau Pa Sat, Maxwell Food Centre)

Le legacy a `visitBlockedNamePatterns: ['lau pa sat',
'maxwell food centre', 'hong lim market', 'food centre']` qui
exclut ces lieux des slots visite (ils restent disponibles
pour insertion repas). Le template-first ne réintroduit pas
cette protection.

### 2. Cafés obscurs / lieux secondaires (V8.28f absent)

OFF : 0 ; ON : **5** (Columbus Coffee Co., SOD Cafe, ToMo
Cafe, Hello Arigato, State Of Affairs)

Le legacy V8.28f impose un "quality floor" en mode fallback
qui exige qu'un candidat soit blueprint must-see / experience
OU metro anchor OU pattern match. Le template-first n'a pas
cette protection.

### 3. Free_day rempli

OFF : 1 free_day ; ON : 0

Le `free_day` (template avec recommendedAnchorKeys vide) du
2026-05-24 reçoit en ON 3 activités (Marina Bay Sands +
Supertree + Jardin botanique). Le template `free_day` était
censé être léger (`flexibility: 100`, slots `freeTime`).
Le builder remplit quand même les slots avec les meilleurs
candidats disponibles → contradiction avec l'intention.

### 4. Doublon sémantique Skyline / Merlion

ON : "Skyline Luge" + "Skyline Luge Singapore" (apparente
duplication via 2 placeIds Google), "Merlion Park" + "Merlion"
(idem).

Le legacy avait :
- `useSameComplexDedup` (Phase 2) pour les complexes
  sémantiques sentosa
- `_dedupKeyForCandidate` par placeId + name normalisé

Le template-first n'a pas ce niveau de dédup.

### 5. Universal Studios sur arrival_day (anomalie)

Le 2026-05-18 (arrival_day, intensité light, primaryZone
`Orchard`) reçoit "Universal Studios Singapore" (Sentosa). Ce
template arrival_day ne devrait pas pointer vers Sentosa. Cas
particulier : le builder pioche le meilleur score sans
considérer la cohérence zone primaire.

## Analyse par complexe (forbiddenComplexKeys)

| Template | forbidden | Lieux ON ce jour | Respecté ? |
|----------|-----------|------------------|------------|
| arrival_day | — (vide) | Universal Studios (Sentosa) | n/a |
| marina_bay_day | sentosa | Pas de Sentosa visible | ✅ |
| sentosa_day | gardens_by_the_bay, marina_bay_sands, orchard_shopping | Sentosa stuff (Mega Adventure, Resorts World, Skyline Luge) + Merlion | partial ✅ |
| free_day | — (vide) | Marina Bay Sands + Supertree | n/a |

`forbiddenComplexKeys` est globalement respecté dans le run.
Les rares anomalies (Universal Studios sur arrival_day) ne
sont **pas dues** à un manque de `forbiddenComplexKeys` (le
template n'en déclare pas) mais au scoring global qui ignore
la zone primaire.

## Risques observés (synthèse)

| # | Risque | Sévérité | Mitigation requise |
|---|--------|----------|--------------------|
| 1 | Avg inter-slot × 4.1, 12 long transitions | **HAUTE** | Anti-zigzag V8.21 à réintroduire |
| 2 | Coherence -30 pts (zone primaire non respectée) | **HAUTE** | Filtrage geographic par zone DI |
| 3 | Hawker centres en visit slot | MOYENNE | V8.28b1 visitBlockedNamePatterns à réintroduire |
| 4 | Cafés obscurs (5 lieux) | MOYENNE | Quality floor V8.28f à réintroduire |
| 5 | Free_day rempli | MOYENNE | Honorer `flexibility` + `freeTime` slot type strict |
| 6 | Doublon sémantique Skyline / Merlion | FAIBLE | Activer `useSameComplexDedup` en parallèle ou inclure dans template-first |
| 7 | Universal Studios sur arrival_day | MOYENNE | Pondération zone primaire dans le scoring |
| 8 | Sur-remplissage volumétrique (+53% visites) | FAIBLE-MOYENNE | Acceptable si qualité OK ; problématique si peu sélectif |

## Limites de l'A/B

1. **1 destination uniquement** : Singapour. Les protections
   legacy (V8.28b1 hawker, V8.28f quality floor) sont
   spécifiquement calibrées Singapour. Sur une destination sans
   MetroProfile curé (Bangkok, Tokyo light), le delta serait
   probablement différent.
2. **1 couple run OFF/ON** : variations Google Places dans la
   marge (±2 pts overall) — mais les écarts observés
   (-7 overall, -30 coherence) sont LARGEMENT au-dessus du
   bruit.
3. **Pas de validation utilisateur subjective** : les métriques
   `planning_metrics` sont des heuristiques. Le voyageur réel
   préférerait peut-être 29 vs 19 visites — non mesurable ici.
4. **Sub-flags non activés** : si on activait
   `useSameComplexDedup` ET `useDayTemplates` simultanément,
   le doublon Skyline/Merlion serait probablement résolu.
   Hors scope A/B principal isolé.

## Recommandation

> ❌ **ACTIVER PAR DÉFAUT : NON**
>
> 🟡 **EXPÉRIMENTATION CONTRÔLÉE : OUI, mais strictement
> dev/debug, jamais user-facing**.

### Justification

Sur le baseline Singapour :
- overall -7.10 pts (régression nette)
- coherence -30.37 pts (régression catastrophique)
- transition -15.37 pts (régression forte)
- 0 → 12 long transitions (>5km)
- 5 cafés obscurs introduits, 2 hawker centres mal-classés
- `free_day` non respecté

**Le template-first 4.5 produit un planning structurellement
moins cohérent que le legacy.** L'orchestration fonctionne (le
mécanisme s'active, le fallback est prévu, le pool est
exploité), mais l'absence des protections legacy V8.20+
crée des régressions visibles.

### Conditions avant activation future

Priorités de correction documentées dans la doc 4.5 (limites
connues), à traiter en **sous-phase 4.7** ou **phase
ultérieure** :

1. **Réintroduire anti-zigzag** intra-jour (cap distance ≤ 5km
   mégacité, anti-zigzag V8.21, coherence guard V8.23).
2. **Réintroduire quality floor** V8.28f pour filtrer les
   cafés obscurs et lieux secondaires.
3. **Réintroduire `visitBlockedNamePatterns`** V8.28b1 pour
   exclure hawker centres / Lau Pa Sat des visit slots.
4. **Honorer `mealStrategy`** des templates (Chinatown
   hawkerCenters, etc.).
5. **Honorer `free_day`** : slots `freeTime` doivent rester
   non remplis automatiquement (intent éditorial).
6. **Pondération zone primaire** : le scoring doit favoriser
   les candidates dans la zone du template (lat/lng vs
   zone.center).
7. **Activer simultanément `useSameComplexDedup`** pour
   éviter les doublons sémantiques (Skyline Luge / Skyline
   Luge Singapore).
8. **Tester sur ≥ 3 destinations** : Bangkok (mégacité avec
   patterns simples), Tokyo (mégacité dense), Paris (Europe).
9. **Validation A/B re-run** après corrections.

### Activation expérimentation contrôlée

Le template-first est **utilisable en mode dev/QA** pour :
- vérifier que les `DayTemplate` se construisent
- vérifier que `DayThemeAssigner` propose les bons templates
- mesurer l'évolution de la qualité au fil des corrections

**Ne pas exposer aux utilisateurs finaux** avant correction
des 7 priorités ci-dessus.

## Commandes exécutées

```bash
# 1. Run places-first OFF
flutter test test/snapshots/generate_baseline.dart
cp test/snapshots/singapore_baseline.json \
   test/snapshots/singapore_phase4_places_first.json

# 2. Run template-first ON
flutter test --dart-define=USE_DAY_TEMPLATES=true \
  test/snapshots/generate_baseline.dart
cp test/snapshots/singapore_baseline.json \
   test/snapshots/singapore_phase4_template_first.json

# 3. Restaure canonical OFF
flutter test test/snapshots/generate_baseline.dart

# 4. Comparator
flutter test test/snapshots/compare_snapshot.dart

# 5. Validation globale
flutter analyze
flutter test
```

### Résultats des commandes

```
flutter analyze : 35 issues info préexistants (INCHANGÉS)
flutter test    : 1056 tests verts (inchangé vs Tâche 4.5)

Run OFF #1 (capture)  : overall 81.97 / 19 visites / coverage 100 / PASS
Run ON (capture)      : overall 74.87 / 29 visites / coverage 100 / PASS
Run OFF #2 (canonical): overall 82.78 / 19 visites / coverage 100 / PASS
```

## Conclusion

**Phase 4 techniquement validée** :
- 6 tâches livrées et validées (4.1 modèle, 4.2 données,
  4.3 assigner, 4.4 builder, 4.5 pipeline flag-gated,
  4.6 A/B)
- Mécanisme runtime fonctionnel : `tryTemplateFirstPipeline`
  s'active et prend la main en flag ON
- Fallback legacy opérationnel
- Coverage et repetition préservées en ON
- 1056 tests verts ; pipeline production strictement inchangé
  par défaut

**Phase 4 PAS prête pour activation par défaut** :
- Coherence -30 pts → zones primaires non respectées
- Transitions × 4 en distance moyenne, 12 long transitions
- Protections legacy (hawker block, quality floor,
  anti-zigzag) absentes
- Free_day non respecté

**Recommandation finale** :
> Le template-first 4.5 est une **base technique** correcte
> mais **pas encore production-ready**. Garder OFF par défaut
> globalement. Réserver l'activation à un mode dev/QA en
> attendant les 7 corrections listées + validation
> multi-destinations.

Cohérent avec règle d'or 1 : *« Toute nouvelle logique doit
être derrière un feature flag, désactivé par défaut. »* — le
flag reste OFF, le legacy reste la voie par défaut.

## Confirmation invariants

- ✅ `FeatureFlags.useDayTemplates` reste **OFF par défaut**
  (aucune modification de `feature_flags.dart`).
- ✅ Pipeline production strictement non modifié
  (`places_first_pipeline.dart` inchangé, `_runAutoPlacesFirstBody`
  inchangé hors le routing flag-gated déjà livré en 4.5).
- ✅ `selectVisitsDeterministic` inchangé.
- ✅ Modèles existants inchangés.
- ✅ 1056 tests verts.
- ✅ Tâche purement de documentation : aucun code de production
  ajouté.

## Prochaine étape

**Phase 5 ou sous-phase 4.7 ?**

L'utilisateur tranchera. Options :

**Option A — sous-phase 4.7 (correction avant Phase 5)** :
adresser les 7 priorités de correction documentées ci-dessus
avant de passer à Phase 5. Permet d'avoir un template-first
production-ready avant les chantiers UI/UX de Phase 5.

**Option B — Phase 5 (continuer le plan refonte initial)** :
laisser template-first en mode dev/QA, continuer Phase 5
(DayPlanStatus, UI, etc.) qui n'a pas besoin que template-first
soit parfait pour avancer.

Recommandation produit probable :
- Option A si l'objectif est de bénéficier du template-first
  rapidement sur Singapour (avant d'étendre aux autres
  destinations).
- Option B si le plan refonte initial doit aller au bout
  d'abord, avec correction template-first en parallèle.
