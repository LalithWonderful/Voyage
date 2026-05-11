# Phase 0 / Tâche 0.3 — Feature flags planning

## Objectif

Créer un système simple, sûr et testable de feature flags pour
préparer les futures phases de refonte du moteur de planning
Lunao. **Aucun flag n'est branché au pipeline dans cette tâche** —
ils servent uniquement de squelette pour les phases ultérieures.

## Fichiers créés / modifiés

- **`lib/config/feature_flags.dart`** *(créé)* — module pur, ~245
  lignes. Class immutable `FeatureFlags` + 4 factories +
  `applyOverrides` + `toMap` + `==`/`hashCode`/`toString`.
- **`test/config/feature_flags_test.dart`** *(créé)* — 28 tests
  unitaires sans réseau.
- **`supabase/sql/feature_flags.sql`** *(créé)* — schema + RLS +
  seed des 4 flags. Convention alignée sur les autres fichiers
  `supabase/sql/*.sql` du projet.
- **`test/snapshots/singapore_baseline.json`** *(régénéré)* — variation
  attribuable au non-déterminisme Google Places (déjà documenté
  Tâche 0.1). **Aucun flag consommé**, donc aucune variation
  fonctionnellement causée par cette tâche.
- **`docs/migrations/phase0_task0_3.md`** *(ce document)*.

**Pas de modification du pipeline**. `places_first_pipeline.dart`,
`destination_blueprints.dart`, `metro_profile.dart`,
`day_builder.dart` : **intacts**.

## Les 4 flags

| Nom Dart (camelCase) | Nom ENV (SCREAMING_SNAKE) | Phase cible |
|----------------------|---------------------------|-------------|
| `useDestinationIntelligence` | `USE_DESTINATION_INTELLIGENCE` | Phase 1 |
| `useSameComplexDedup` | `USE_SAME_COMPLEX_DEDUP` | Phase 2 — SameComplexGroup |
| `useDestinationScope` | `USE_DESTINATION_SCOPE` | Phase 3 |
| `useDayTemplates` | `USE_DAY_TEMPLATES` | Phase 4 — DayTemplate |

**Tous les flags sont `false` par défaut.** Vérifié par 3 tests
distincts (const ctor, `defaults()`, `fromEnvironmentMap({})`).

## Niveaux de configuration

Du plus prioritaire au moins :

1. **Override Supabase** (futur) via `applyOverrides({...})`.
2. **Variables d'environnement** via `--dart-define=USE_*=true` →
   `FeatureFlags.fromEnvironment()`.
3. **Défauts** : tous `false`.

## Syntaxe `--dart-define`

```bash
flutter run --dart-define=USE_DESTINATION_INTELLIGENCE=true
flutter run --dart-define=USE_SAME_COMPLEX_DEDUP=true
flutter test --dart-define=USE_DAY_TEMPLATES=true
```

**Limitation Dart** : `const String.fromEnvironment(key)` exige un
literal `key` (compile-time const). Les 4 noms sont donc enumérés
explicitement dans `FeatureFlags.fromEnvironment()`. Si un 5ᵉ flag
est ajouté plus tard, il faut ajouter une ligne dans
`fromEnvironment()` + la constante `_envKey*` + le field Dart.

## Règles de parsing bool

Implémentées dans `_parseBoolString(String?)` :

| Input (case-insensitive, trimmed) | Output |
|-----------------------------------|--------|
| `true`, `TRUE`, `True` | `true` |
| `1` | `true` |
| `yes`, `YES`, `Yes` | `true` |
| `false`, `FALSE`, `False` | `false` |
| `0` | `false` |
| `no`, `NO`, `No` | `false` |
| valeur inconnue (`maybe`, `oui`, etc.) | `null` → défaut s'applique |
| `null` ou string vide `""` | `null` → défaut s'applique |
| whitespace seulement | `null` → défaut s'applique |

Note : `String.fromEnvironment(key)` renvoie `""` quand la clé
n'est pas définie au compile-time. Notre parser le traite comme
"absent" → défaut false. C'est conforme à la spec
*"valeur absente ou inconnue → valeur par défaut"*.

## Comportement `applyOverrides(Map<String, dynamic>)`

Méthode pour appliquer des overrides venus de Supabase (futur) ou
de toute autre source dynamique. **Retourne une nouvelle
instance** (immutabilité).

Coercition `_coerceBool(dynamic)` :
- `bool` → utilisé directement
- `num` → `0` = false, autre = true
- `String` → parsé via `_parseBoolString`
- autre type (Map, List, etc.) → `null` → préserve valeur

Règles par clé :
- **Clé connue + valeur coerciable** → flag mis à jour
- **Clé connue + valeur non coerciable** (null, type bizarre,
  string invalide) → flag inchangé (préserve valeur existante)
- **Clé inconnue** → ignorée silencieusement (forward-compat avec
  futurs flags définis seulement côté Supabase)
- **Clé absente** → préserve valeur existante (différent d'une
  valeur explicite `null` côté API — même comportement ici, les
  deux préservent)

Clés attendues : **camelCase** (`useDayTemplates`, etc.) —
cohérent avec les fields Dart et la colonne `key` de
`public.feature_flags`.

Exemple :
```dart
final base = FeatureFlags.fromEnvironment();
final flags = base.applyOverrides({
  'useDayTemplates': true,
  'useSameComplexDedup': 'yes',
  'unknownFlag': true,        // ignoré
  'useDestinationScope': null, // préserve valeur existante
});
```

## Migration Supabase

Fichier : **`supabase/sql/feature_flags.sql`**.

Convention du projet : fichiers SQL standalone dans `supabase/sql/`
(pas de système de migrations versionnées formelles). Application
manuelle dans le SQL editor Supabase. Aligné sur `country_regions.sql`,
`gemini_cache.sql`, etc.

Schéma :

```sql
create table if not exists public.feature_flags (
  key         text        primary key,
  enabled     boolean     not null default false,
  description text,
  updated_at  timestamptz not null default now()
);
```

RLS : `enable row level security` + policy `for select using (true)`
(lecture pour anon + authenticated). Pas de policy write → seul
le `service_role` peut écrire (admin via Supabase dashboard). Idem
convention `country_regions.sql`.

Trigger `updated_at` automatique à chaque update.

Seed initial : insertion des 4 flags avec `enabled = false` et une
description claire de la phase cible. `on conflict (key) do
nothing` → ré-application idempotente sans écraser les valeurs
modifiées en prod.

**Branchement Supabase côté Flutter** : **PAS** fait dans cette
tâche. `FeatureFlags.fromEnvironment()` reste **sync, pure, sans
appel réseau**. Une phase future ajoutera un repository qui lit
la table, transforme en `Map<String, dynamic>`, et passe à
`applyOverrides`. La séparation a été conçue pour ça (cf. design
`applyOverrides` accepte une map locale, pas un Future ni une
connection).

## Aucun pipeline ne consomme ces flags

Vérifié par grep `grep -rn "FeatureFlag\|featureFlag\|feature_flag" lib/`
hors du module lui-même → **aucune référence**. Le pipeline de
planning, le UI, le screen `planning_screen.dart`, et tous les
services restent strictement inchangés. La règle d'or 1
(*"Ne JAMAIS casser le pipeline existant. Toute nouvelle logique
doit être derrière un feature flag, désactivé par défaut."*) est
respectée par construction : les flags existent, sont OFF, et
seront branchés au pipeline UNIQUEMENT quand la phase
correspondante introduira le nouveau code.

## Aucun comportement utilisateur changé

Le snapshot Singapour a été régénéré pour vérification. Le run
produit :
```
Total visites      : 19    (Tâche 0.2 : 22 / Tâche 0.1 : 19)
Total repas        :  4
Jours avec activité:  8
Jours libres       :  0
Doublons (par nom) :  0
Distance inter-slot moyenne : 1234.9 m
Overall score      : 78.6 / 100
```

Comparaison des 3 runs successifs (cumulés des 3 tâches Phase 0) :

| Métrique | Tâche 0.1 | Tâche 0.2 | Tâche 0.3 |
|----------|----------:|----------:|----------:|
| Total visites | 19 | 22 | 19 |
| Total repas | 4 | 4 | 4 |
| Jours actifs | 7 | 8 | 8 |
| Jours libres | 1 | 0 | 0 |
| Distance inter-slot | 1615.8 m | 1529.2 m | 1234.9 m |

Les variations entre runs sont attribuables **exclusivement** au
non-déterminisme Google Places (déjà documenté Tâche 0.1, limite
*"baseline immuable par engagement humain"*). Les flags introduits
dans cette tâche **ne sont pas consommés** et donc **ne peuvent
pas** influencer le résultat.

Le contenu lui-même reste sémantiquement cohérent : zéro doublon,
zéro répétition de visites iconiques (V8.28b1.4 OK), repas
détectés par heuristique 12:30/19:30 OK, hawker centres exclus,
pas de candidat Johor/Indonesia.

**Snapshot non modifié manuellement** : le `singapore_baseline.json`
est régénéré uniquement par le script via le pipeline production.

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants depuis Tâche 0.1, inchangés)
  0 warning, 0 error
  → lib/config/feature_flags.dart : No issues found
  → test/config/feature_flags_test.dart : No issues found

flutter test
  All tests passed!
  483 tests verts
  (455 Tâche 0.2 + 28 nouveaux tests FeatureFlags)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, JSON régénéré ~56 KB
  Overall score Singapour : 78.6 / 100
```

## Commande

```bash
# Tests purs (sans réseau)
flutter test test/config/feature_flags_test.dart

# Tous tests + baseline snapshot
flutter test
flutter test test/snapshots/generate_baseline.dart

# Compile-time --dart-define
flutter run --dart-define=USE_DESTINATION_INTELLIGENCE=true
```

## Design retenu

Class immutable simple, sans état global mutable :

```dart
class FeatureFlags {
  final bool useDestinationIntelligence;
  final bool useSameComplexDedup;
  final bool useDestinationScope;
  final bool useDayTemplates;

  const FeatureFlags({
    this.useDestinationIntelligence = false,
    this.useSameComplexDedup = false,
    this.useDestinationScope = false,
    this.useDayTemplates = false,
  });

  factory FeatureFlags.defaults();
  factory FeatureFlags.fromEnvironment();
  factory FeatureFlags.fromEnvironmentMap(Map<String, String> env);

  FeatureFlags applyOverrides(Map<String, dynamic> overrides);
  Map<String, bool> toMap();
}
```

Pattern DI préféré : créer une instance explicitement et la passer
à qui en a besoin. Évite singletons globaux mutables, simplifie
les tests (chaque test crée son `FeatureFlags`), thread-safe par
construction.

## Limites connues

1. **Branchement Supabase non implémenté côté Flutter** — la table
   existe, le mécanisme `applyOverrides` est prêt, mais aucun
   repository ne lit Supabase à ce stade. Volontaire : pas dans le
   scope Tâche 0.3 ("préparer le support sans rendre le runtime
   dépendant d'un appel réseau obligatoire"). À ajouter en phase
   ultérieure.

2. **Limitation `String.fromEnvironment`** — Dart impose un literal
   pour la clé. Ajout d'un 5ᵉ flag = modification manuelle de 3
   endroits : (a) field Dart, (b) constante `_envKey*`, (c) ligne
   dans `fromEnvironment()`. Compromis accepté pour préserver le
   const compile-time.

3. **Heuristique `_coerceBool` permissive** — `int 1` → true,
   `int 0` → false, mais `int 42` → true (pattern bool-as-int).
   Cohérent avec convention shell, mais peut surprendre si une
   colonne Supabase contient un nombre non standard.

4. **Pas de mécanisme d'invalidation runtime** — `FeatureFlags` est
   immutable : une fois construite, une nouvelle valeur ne peut pas
   être propagée aux clients qui ont déjà l'instance. Si une phase
   future nécessite des changements live (ex: kill-switch via
   Supabase), il faudra ajouter un wrapper observable
   (`ValueNotifier`, stream, Riverpod provider) par-dessus. Hors
   scope Tâche 0.3.

5. **`updated_at` n'est pas lu côté Flutter** — la colonne existe
   pour traçabilité admin Supabase. La future couche de lecture
   pourra l'utiliser pour invalider un cache TTL si pertinent.

## Confirmation contraintes

- ✅ Tous les flags `false` par défaut (testé)
- ✅ Aucun flag branché au pipeline (grep confirmé)
- ✅ Aucun comportement utilisateur changé (snapshot reflète
  uniquement non-déterminisme API préexistant)
- ✅ Aucun appel réseau obligatoire (`fromEnvironment` est pure)
- ✅ Aucun test ne dépend de Supabase
- ✅ Aucun `DestinationIntelligence` créé
- ✅ Aucun `SameComplexGroup` créé
- ✅ Aucun `DayTemplate` créé
- ✅ Aucun fichier du pipeline modifié
- ✅ Aucun code existant supprimé
- ✅ Une seule tâche, un seul commit

## Hors scope (n'est PAS dans cette tâche)

- Lecture réelle de `public.feature_flags` depuis Flutter (futur).
- Branchement effectif d'un flag au pipeline (Phase 1+).
- UI de gestion des flags (admin / debug).
- Mécanisme observable / live-update des flags.
