# Phase 5 — Checklist de readiness avant activation

> **Document de référence projet.** À ouvrir avant toute décision
> GO/NO-GO Phase 5. Aucune logique métier ici — chaque item est
> tranché OUI/NON et bloque ou non l'avancement.
>
> Statut au **2026-05-12** : **NO-GO Phase 5 user-facing**. Next
> step prioritaire = API-0.3 puis API-0.4 puis Tâche 4.9 A/B live
> contrôlé.

---

## Distinction préalable : 2 chemins possibles

Avant de cocher quoi que ce soit, il faut décider quel type de
Phase 5 on vise. Les pré-requis ne sont pas les mêmes.

### Chemin A — Phase 5 user-facing (réelle exposition utilisateur)

Inclut tout ce qui touche à l'utilisateur final :
- `DayPlanStatus` exposé dans l'UI.
- Bannières / messages (« journée légère », « aidez-nous à
  construire cette journée », « free day intentionnel »).
- CTA dépendants du résultat template-first.
- Tout affichage qui reflète un état du moteur stabilisé 4.7.

**Verdict actuel : NO-GO** tant que les sections A, B, C, D, F
ci-dessous ne sont pas validées en totalité. Ce chemin demande
notamment API-0.x complet, A/B live 4.9, validation
multi-destinations et stratégie de rollout claire.

### Chemin B — Phase 5 technique / dormante

Création des modèles `DayPlanStatus` et helpers associés derrière
flag OFF, **sans UI ni exposition utilisateur**. Code dormant à la
manière des Phases 1.1, 2.1, 4.1.

**Possible plus tard, pas prioritaire actuellement.** Les chantiers
prioritaires restent API-0.3, API-0.4, Tâche 4.9. Cette piste ne
remplace pas le chemin A — elle ne fait qu'anticiper sans débloquer
l'exposition.

**Conséquence pour la checklist** : tant que la décision sur le
chemin n'est pas prise par le user, **les pré-requis du chemin A
s'appliquent par défaut**. Le chemin B est mentionné comme option
explicite si le user souhaite paver le terrain sans exposer.

---

## A. Pré-requis API & coûts (bloquants chemin A)

Référence : [`docs/api_cost/api_live_call_inventory.md`](../api_cost/api_live_call_inventory.md)
(commit `8f3d0a0`).

- [ ] **A1 — API-0.2 livrée** : kill switch global API uniforme
  (env var / flag / proxy) capable de couper tous les appels live
  mentionnés dans l'inventaire (Google Places legacy + Places New +
  Geocoding + Routes v2 + Gemini + Supabase + Maps SDK + Frankfurter).
  **Critère** : kill switch testé en local, OFF → 0 appel sortant
  observé sur une session complète (planning + navigation + UI).
- [ ] **A2 — API-0.3 livrée** : `generate_baseline.dart` et
  `places_first_harness.dart` rejouables sans burn de quota Places.
  **Critère** : un re-run snapshot Singapore n'incrémente PAS le
  compteur Google Places (cache / proxy / mocks rejouables en
  place).
- [ ] **A3 — API-0.4 livrée** : guards branchés dans les services
  live (`places_service.dart`, `places_nearby_service.dart`,
  `geocoding_service.dart`, `routes_service.dart`,
  `ai_suggestions_service.dart`, `assistant_service.dart`).
  **Critère** : chaque service consulte le kill switch / quotas
  avant tout `http.post` / `http.get`.
- [ ] **A4 — Coût par planning généré chiffré** : combien d'appels
  Places New / Geocoding / Routes / Gemini déclenchés par un planning
  utilisateur final ? **Critère** : ordre de grandeur connu et
  acceptable au regard du budget cible. Phase 5 multipliera ce coût
  par le nombre d'utilisateurs actifs.
- [ ] **A5 — Coût UI ambient chiffré** : autocompletes
  (`autocompleteDestinations`, `autocompleteCities`,
  `autocompleteTransport`), Place Photo dans `CachedNetworkImage`,
  Maps SDK tiles. **Critère** : volumétrie estimée et caches
  Supabase (`places_cache`, `place_lookup_cache`,
  `gemini_cache`) vérifiés actifs.
- [ ] **A6 — Rate limiting Gemini réactivé** : `_rateLimitEnabled`
  dans `ai_suggestions_service.dart` est actuellement `false` (cf.
  inventaire). **Critère** : flag remis à `true` et
  `check_and_log_ai_usage` RPC effectivement protège les appels.
- [ ] **A7 — Alerting cost en place** : seuils alertes Google
  Cloud Console + Supabase pour Places API, Routes API, Gemini,
  Storage. **Critère** : alerte testée à un seuil bas (ex : 10 €
  / jour) avant prod.

## B. Pré-requis validation moteur (bloquants chemin A)

Référence : [`docs/migrations/phase4_task4_7.md`](phase4_task4_7.md)
section « Validation A/B live — reportée ».

- [ ] **B1 — A/B live 4.9 Singapore effectué** : re-run
  `generate_baseline.dart` ON vs OFF post-4.7 avec API-0.x en
  place. **Critère** : couple OFF/ON capturé et
  `singapore_baseline.json` canonical restauré (3ᵉ run OFF).
- [ ] **B2 — `coherence_score` ≥ 70** sur run ON (vs 52.52 en
  4.6). **Critère** : valeur lue dans le JSON capturé.
- [ ] **B3 — `transition_score` ≥ 85** (vs 77.16 en 4.6).
- [ ] **B4 — `avg inter-slot` < 2 000 m** (vs 5 174 m en 4.6).
- [ ] **B5 — Long transitions (> 5 km) ≤ 3** sur les 8 jours
  (vs 12 en 4.6).
- [ ] **B6 — `free_days_count` ≥ 1** (vs 0 en 4.6).
- [ ] **B7 — 0 hawker / food centre en visit slot** (vs 2 en
  4.6 : Lau Pa Sat, Maxwell Food Centre).
- [ ] **B8 — 0 visite avec rating < 4.0** hors anchor recommandé
  (vs 5 cafés obscurs en 4.6 : Columbus Coffee, SOD Cafe,
  ToMo Cafe, Hello Arigato, State Of Affairs).
- [ ] **B9 — `overall_score` ON ≥ 80** (vs 74.87 en 4.6, et
  81.97 en OFF). Critère implicite : le template-first ne doit
  plus dégrader globalement.

**Si l'un de B2-B9 n'est pas atteint** → NO-GO chemin A,
déclencher **Tâche 4.10** (corrections complémentaires) avant
toute nouvelle tentative.

## C. Pré-requis qualité & robustesse (bloquants chemin A)

- [ ] **C1 — Multi-destinations testé** : au moins 2 destinations
  en plus de Singapour (ex : Bangkok + Paris, ou Tokyo + Rome)
  avec `DestinationIntelligence` + `DayTemplate[]` curés et A/B
  live ON vs OFF. **Critère** : aucune des 6 régressions 4.6
  ne réapparaît hors Singapour.
- [ ] **C2 — Combinaison `useSameComplexDedup` +
  `useDayTemplates`** testée offline : risque doublons sémantiques
  (Skyline Luge / Skyline Luge Singapore, Merlion / Merlion Park)
  levé. **Critère** : un test offline démontre que le dedup
  s'applique bien à l'output template-first.
- [ ] **C3 — `mealStrategy` consommée** par le builder OU
  décision explicite de la laisser indicative : si l'UI Phase 5
  expose la stratégie repas (« hawker centres », « fine dining »),
  le builder doit l'honorer. Sinon : décision documentée que la
  sélection repas reste déléguée au legacy
  `insertDeterministicMeals`.
- [ ] **C4 — Suite globale verte** : `flutter analyze` 35 issues
  info inchangés + `flutter test` 1085+ tests verts. **Critère** :
  exécutés juste avant le GO, sans appel live.
- [ ] **C5 — `useDayTemplates` sur `category != all`** : actuellement
  le routing template-first est limité à
  `SuggestionCategory.all`. Si Phase 5 expose le template-first
  pour d'autres catégories (resto, transport), validation
  explicite requise.

## D. Pré-requis produit & scope (bloquants chemin A)

- [ ] **D1 — Scope Phase 5 figé** : liste écrite et signée des
  features user-facing (`DayPlanStatus`, bannière « journée
  légère », CTA « construisez cette journée », libellés free_day,
  etc.). **Critère** : doc dédié type
  `docs/migrations/phase5_scope.md`.
- [ ] **D2 — Stratégie de rollout définie** : `useDayTemplates`
  reste-t-il OFF par défaut globalement ? Activation par
  destination ? Cohorte beta ? A/B utilisateur ? **Critère** :
  décision écrite.
- [ ] **D3 — Messaging utilisateur drafté** : libellés FR/EN pour
  les états `light_day`, `incomplete_day`, `free_day`, etc.
  Validés produit + traduction.
- [ ] **D4 — Comportement si fallback legacy** : que voit
  l'utilisateur quand `tryTemplateFirstPipeline.isUsable == false`
  et que le code retombe sur le pipeline legacy ? **Critère** :
  décision UX (rien d'affiché ? bannière neutre ?) documentée.
- [ ] **D5 — Test utilisateur subjectif** : ≥ 3 voyageurs réels
  sur Singapore (live ON post-4.7) ou ≥ 5 sur fixtures Phase 4.8
  rendues en mock UI. **Critère** : feedback recueilli, pas
  catastrophique.

## E. Pré-requis observabilité (recommandés)

Ces items ne bloquent pas la décision Phase 5 elle-même, mais sont
fortement recommandés pour un rollout sain.

- [ ] **E1 — Métriques runtime live** : log structuré sur chaque
  pipeline run (template-first activé ? fallback ? raison ?)
  routé vers Supabase ou équivalent. Permet d'observer le ratio
  template-first vs fallback en prod.
- [ ] **E2 — Métriques qualité runtime** :
  `planning_metrics.computePlanningMetrics()` calculé sur chaque
  planning généré et stocké, pour suivre la qualité réelle vs
  A/B Singapore.
- [ ] **E3 — Compteurs A/B prêts** : si rollout cohorte,
  infrastructure de bucketing utilisateur en place et testée.

## F. Pré-requis sécurité opérationnelle (bloquants pour tout run live répété ou activation user-facing)

Ces règles sont durables et s'appliquent à toute activité live
récurrente (re-run snapshot, A/B live, exposition utilisateur).
Elles ne sont **pas négociables** dès qu'on sort du strict mode
développement isolé.

- [ ] **F1 — Zéro API live sans opt-in explicite** documenté.
  Aucun script ne doit déclencher Google Places / Routes /
  Geocoding / Gemini / Supabase / Maps SDK / Frankfurter live
  sans confirmation explicite. **Critère** : règle inscrite dans
  `CLAUDE.md` ou README dev au niveau projet, lisible par tout
  contributeur (humain ou agent).
- [ ] **F2 — `generate_baseline.dart` reste opt-in explicite**
  même après API-0.3. **Critère** : un commentaire d'en-tête
  clair indique le mécanisme de re-run sécurisé (cache / proxy /
  mocks rejouables) et l'opt-in nécessaire pour bypass.
  `places_first_harness.dart` : même régime.
- [ ] **F3 — Aucun nouveau flag à `true` par défaut** dans
  Phase 5. **Critère** : diff de
  [`lib/config/feature_flags.dart`](../../lib/config/feature_flags.dart)
  vide côté defaults (`useDestinationIntelligence`,
  `useSameComplexDedup`, `useDestinationScope`, `useDayTemplates`
  restent OFF).

---

## Décision finale

**GO Phase 5 chemin A (user-facing)** uniquement si :
- TOUS les items section **A** cochés (sinon coût non maîtrisé).
- TOUS les items section **B** cochés (sinon moteur non validé live).
- TOUS les items section **C** cochés (sinon non robuste hors Singapour).
- TOUS les items section **D** cochés (sinon scope produit flou).
- TOUS les items section **F** cochés (sinon garde-fous opérationnels absents).

Items section **E** : recommandés, non strictement bloquants — peuvent être livrés en parallèle des premiers jalons Phase 5 user-facing.

**Si un seul item bloquant (A, B, C, D, F) n'est pas atteint** : pas Phase 5 user-facing. Soit retour Tâche 4.10 (B), soit retour API-0.x (A), soit retour multi-destinations (C), soit retour produit (D), soit mise à jour des règles projet (F).

**Phase 5 chemin B (technique / dormante)** : possible dès lors que les invariants flag OFF par défaut sont respectés (items F1-F3 toujours obligatoires). Mais **non prioritaire actuellement** — ne paie pas pour l'objectif principal (template-first user-ready). Pas recommandé tant que la séquence API-0.3 → API-0.4 → 4.9 n'est pas achevée.

---

## Statut au 2026-05-12

**Décision actuelle** : **NO-GO Phase 5 user-facing** (chemin A).

État des sections bloquantes :
- A : non commencée (API-0.1 inventaire livré côté Codex,
  reste 0.2 / 0.3 / 0.4).
- B : non commencée (A/B live 4.9 conditionné par section A).
- C : partielle (C4 vert : 1085 tests verts, 35 issues info ;
  reste C1, C2, C3, C5).
- D : non commencée.
- F : partielle (règles documentées dans
  [`planning_engine_refactor_status.md`](planning_engine_refactor_status.md)
  §11 mais non répliquées au niveau `CLAUDE.md` projet ; flags
  defaults inchangés → F3 ✅).

**`useDayTemplates` reste OFF par défaut.** Cohérent avec la
recommandation Phase 4.6 et maintenu après 4.7 / 4.8.

---

## Next step prioritaire

Séquence stricte recommandée :

1. **API-0.3 — Protection `generate_baseline.dart` / `places_first_harness.dart`** : cache / proxy / mocks rejouables permettant le re-run snapshot sans burn de quota Google Places.
2. **API-0.4 — Branchement des guards** dans les services live (`places_service.dart`, `places_nearby_service.dart`, `geocoding_service.dart`, `routes_service.dart`, `ai_suggestions_service.dart`, `assistant_service.dart`).
3. **Tâche 4.9 — A/B live contrôlé** : re-run `generate_baseline.dart` ON vs OFF post-4.7 avec API-0.x en place, comparaison aux seuils chiffrés section B.
4. **Décision Phase 5** : sur la base des résultats 4.9, repasser cette checklist item par item. Si B2-B9 atteints → tenter section C, D, F. Sinon → Tâche 4.10.

**Items E (observabilité)** peuvent démarrer en parallèle de la
séquence ci-dessus sans la bloquer (instrumentation pure, pas
d'effet sur les flags ni sur les coûts).

---

## Références

- [`docs/migrations/planning_engine_refactor_status.md`](planning_engine_refactor_status.md) — état complet de la refonte Phase 0 → 4.8.
- [`docs/migrations/phase4_task4_6.md`](phase4_ab_test.md) — A/B live 4.6 (chiffres référence).
- [`docs/migrations/phase4_task4_7.md`](phase4_task4_7.md) — stabilisation moteur, seuils chiffrés attendus.
- [`docs/migrations/phase4_task4_8.md`](phase4_task4_8.md) — validation offline fixture-based.
- [`docs/api_cost/api_live_call_inventory.md`](../api_cost/api_live_call_inventory.md) — inventaire des appels live (API-0.1, commit `8f3d0a0`).
