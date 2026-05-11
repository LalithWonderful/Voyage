# Phase 1 / Tâche 1.3 — Loader + cache `DestinationIntelligence`

## Objectif

Créer un **service disponible mais dormant** capable de charger
une `DestinationIntelligence` depuis le registre local Dart,
optionnellement depuis Supabase, avec cache mémoire et fallback
gracieux pour destinations inconnues. **Aucun branchement au
pipeline production** ; le flag `useDestinationIntelligence` reste
OFF par défaut et non consommé.

## Fichiers créés

- **`lib/services/destination_intelligence_loader.dart`** *(créé,
  ~200 lignes)* — classe `DestinationIntelligenceLoader` +
  interfaces injectables `DestinationIntelligenceRemoteSource` et
  `DestinationCenterResolver` + `defaultLocalDestinationRegistry`
  + `typedef DestinationIntelligenceBuilder`. Module pur, sans
  appel réseau direct.
- **`test/services/destination_intelligence_loader_test.dart`**
  *(créé)* — **22 tests** purement unitaires, 10 groupes.
- **`docs/migrations/phase1_task1_3.md`** *(ce document)*.

**Aucun fichier de production modifié** :
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/data/destination_blueprints.dart` intact
- `lib/features/planning/data/metro_profile.dart` intact
- `lib/features/planning/data/segment_city_canonicals.dart` intact
- `lib/features/planning/services/day_builder.dart` intact
- `lib/config/feature_flags.dart` intact (`useDestinationIntelligence`
  toujours OFF, non consommé)
- `lib/models/destination_intelligence.dart` intact
- `lib/data/destinations/singapore.dart` intact

## Design du loader

### API publique

```dart
typedef DestinationIntelligenceBuilder = DestinationIntelligence Function();

abstract class DestinationIntelligenceRemoteSource {
  Future<DestinationIntelligence?> loadDestinationIntelligence(
      String destinationKey);
}

abstract class DestinationCenterResolver {
  Future<GeoPoint?> resolveCenter(String destinationKey);
}

class DestinationIntelligenceLoader {
  DestinationIntelligenceLoader({
    DestinationIntelligenceRemoteSource? remoteSource,
    DestinationCenterResolver? centerResolver,
    Map<String, DestinationIntelligenceBuilder>? localRegistry,
  });

  Future<DestinationIntelligence> load(String destinationKey);
  void clearCache();
  bool isCached(String destinationKey);
}

final Map<String, DestinationIntelligenceBuilder>
    defaultLocalDestinationRegistry = {
  'singapore': buildSingaporeDestinationIntelligence,
};
```

### Choix de design

| Aspect | Choix | Justification |
|--------|-------|---------------|
| Registre local | `Map<String, Builder>` (refs de fonctions, pas instances) | Lazy : pas de construction si destination jamais demandée |
| Interfaces injectables | `abstract class` (pas mixin) | Simple, idiomatique Dart, mockable sans framework |
| Cache | `Map<String, DestinationIntelligence>` mémoire, keyé sur clé normalisée | Session-only, simple, deterministe |
| Normalisation | `trim().toLowerCase()` | Simple, pas d'aliasing complexe (cf. spec) |
| Erreurs remote/resolver | Attrapées silencieusement → fallback | `load()` ne lève jamais d'exception en production |
| Fallback center neutre | `GeoPoint(0, 0)` | Documenté ; signal facile à détecter en debug |

## Ordre de priorité cache / local / remote / fallback

```
1. Cache mémoire                  (clé normalisée)
   └─ hit → retourner
2. Registre local                 (data Dart curated)
   └─ trouvé → cacher + retourner
3. Source remote (si fournie)     (Supabase, futur)
   ├─ retourne DI valide → cacher + retourner
   ├─ retourne null      → fallback
   └─ throw              → fallback (silencieux)
4. Fallback minimal               (DI valide construit en mémoire)
   ├─ centerResolver (si fourni) → tente résolution
   └─ sinon → centre neutre (0, 0)
```

**Justification choix local-first** : les données validées en code
(`lib/data/destinations/*.dart`) ont déjà passé tous les tests
(10 zones / 15 anchors / validate vide / round-trip JSON). Une
mise à jour Supabase mal configurée ne doit pas pouvoir dégrader
silencieusement une destination embarquée. Une phase ultérieure
peut inverser cet ordre si un besoin de kill-switch dynamique
émerge — il suffira d'inverser 2 lignes dans `load()`.

## Stratégie de normalisation des clés

```dart
String _normalizeKey(String s) => s.trim().toLowerCase();
```

Cas couverts (testés) :
- `"Singapore"` → `"singapore"`
- `" SINGAPORE "` → `"singapore"`
- `" singapore "` → `"singapore"`

Cas **non** couverts (volontaire, spec explicite *"Ne pas ajouter
une logique d'aliases complexe"*) :
- `"Singapour"` (français) → **PAS** mappé à `"singapore"`
- `"SG"` (code pays) → **PAS** mappé à `"singapore"`
- `"Sing"` (abbréviation) → **PAS** mappé

Si besoin d'aliases futurs : étendre via `localRegistry` injectée
(ex: `{'singapore': sg, 'singapour': sg, 'sg': sg}`) ou ajouter
une logique dédiée dans une phase ultérieure.

## Stratégie de cache

- **Type** : `Map<String, DestinationIntelligence>` mémoire,
  session-only.
- **Clé** : clé normalisée (`_normalizeKey`).
- **Hit** : retourne l'instance cachée sans rebuild.
- **Miss** : tente local → remote → fallback ; cache le résultat.
- **`clearCache()`** : vide complètement.
- **`isCached(key)`** : vérifie présence via clé normalisée.

Pas de cache persistant (DB, filesystem). Pas de TTL. Pas
d'invalidation automatique. Volontaire : le loader Phase 1.3 est
un service simple, l'enrichissement (TTL, observabilité, kill-
switch) viendra avec les phases qui le consommeront.

## Comportement fallback

Quand la destination est absente du registre local et du remote
(ou que remote retourne null / throw), le loader construit un
`DestinationIntelligence` minimal **garantissant** que
`validate().isEmpty == true`.

Valeurs du fallback :

```dart
DestinationIntelligence(
  destinationKey: <clé normalisée>,
  canonicalCenter: <centerResolver?.resolveCenter() ?? GeoPoint(0, 0)>,
  countryCode: 'XX',                  // ISO 3166-1 "unknown" reserved
  allowedCountryCodes: ['XX'],
  blockedCountryCodes: [],
  borderSensitivity: BorderSensitivity.medium,
  tripMode: TripMode.cityBreak,
  zones: [
    TouristZone(
      name: 'Unknown area',
      center: <même centre>,
      radiusKm: 5.0,
      theme: 'generic_unknown',
    ),
  ],
  anchors: [
    DestinationAnchor(
      name: <clé normalisée si non-vide, sinon 'unknown_destination'>,
      placeQueries: [<même name>],
      importance: 3,
      recommendedDuration: Duration(minutes: 90),
    ),
  ],
  transportRules: TransportRules(
    maxTransitionKm: 5.0,
    dominantMode: 'public_transport',
    hasMetro: false,
    hasMetroAnchorLogic: false,
  ),
)
```

**Cas spécial clé vide** : `load('')` retourne un fallback avec
`destinationKey = 'unknown_destination'` (pour respecter
`validate()` qui exige `destinationKey` non-vide). Documenté.

## Comment Supabase est préparé sans être obligatoire

- L'interface `DestinationIntelligenceRemoteSource` est définie
  dans `lib/services/destination_intelligence_loader.dart`.
- **Aucune implémentation concrète Supabase** créée dans cette
  tâche — uniquement l'interface.
- Le loader accepte `remoteSource: null` (default) → fallthrough
  direct au fallback si destination absente du local.
- Les tests utilisent des `_FakeRemoteSource` en mémoire (aucun
  appel `supabase_flutter` ni client réel).
- Une phase ultérieure créera une implémentation
  `SupabaseDestinationIntelligenceRemoteSource` dans un fichier
  séparé qui pourra dépendre de `supabase_flutter` — sans
  contaminer le loader pur.

## Pourquoi aucun appel Google Places direct dans le loader

La spec mentionne *"fallback gracieux : retourne un DI minimal
basé sur Google Places (centre déduit de la ville)"*. Implémenter
ça côté loader créerait :
- une dépendance directe au `GeocodingService` du projet
  (couplage avec le pipeline)
- des tests dépendants de la clé API Google (coûteux, non-
  déterministe)
- un loader async qui prend potentiellement plusieurs secondes
  par fallback (UX-bloquant en cascade)

Choix retenu : abstraction `DestinationCenterResolver` injectable.
Le loader appelle `resolver?.resolveCenter(key)` si fourni, sinon
centre neutre. Une phase ultérieure pourra wrapper le
`GeocodingService` existant via une implémentation concrète sans
toucher au loader.

## Tests unitaires — 22 tests, 10 groupes

| Groupe | Tests | Couverture |
|--------|------:|-----------|
| 1. Load Singapour local | 1 | retour valide, zones attendues, megaCity, high |
| 2. Normalisation clé | 2 | "Singapore" / " SINGAPORE " / "singapore" → même cache |
| 3. Cache hit | 2 | builder appelé 1×, clearCache force rebuild |
| 4. Destination inconnue fallback | 2 | cityBreak / medium / 1 zone / 1 anchor / clé vide |
| 5. Fallback avec centerResolver | 4 | center utilisé / null / throw / GeoPoint invalide |
| 6. Remote source optionnelle | 2 | DI retourné + caché / null → fallback |
| 7. Remote source absente | 1 | fallback gracieux |
| 8. Priorité local-first | 1 | local gagne, remote PAS consulté |
| 9. Erreur remote | 2 | throw → fallback silencieux / local prioritaire |
| 10. Edge cases | 5 | isCached, clearCache, custom registry, cache shared |

Aucune dépendance réseau / Supabase / Google Places. Fakes en
mémoire (`_FakeRemoteSource`, `_FakeCenterResolver`,
`_CountingBuilder`).

## Confirmation : le pipeline ne consomme pas encore le loader

- ✅ `grep -rn "DestinationIntelligenceLoader" lib/features/`
  → **aucune référence**
- ✅ `lib/config/feature_flags.dart::useDestinationIntelligence`
  reste OFF et non consommé
- ✅ `places_first_pipeline.dart` n'importe NI le loader, NI
  les modèles `DestinationIntelligence`
- ✅ Le loader Phase 1.3 est **disponible mais dormant**

## Limites connues

1. **Pas de cache persistant** — le cache mémoire est perdu à
   chaque redémarrage. Acceptable pour un loader appelé une
   poignée de fois par run. Une persistence (SharedPreferences
   / SQLite / mémoire admin) pourrait être ajoutée en phase
   ultérieure si besoin.

2. **Pas de TTL** — une entrée cachée reste valide indéfiniment
   tant que `clearCache()` n'est pas appelé. Volontaire : pas
   de risque de staleness en Phase 1.3 (rien ne consomme le
   loader). À durcir si Supabase devient source primaire.

3. **`countryCode = 'XX'` en fallback** — ISO 3166-1 reserve
   `XA`-`XZ` pour usage privé. `XX` est largement utilisé
   informellement comme "unknown". Pas un standard strict mais
   conforme à la convention.

4. **Erreurs silencieuses** — toute exception remote /
   centerResolver est attrapée et fait fall through. Bon pour la
   robustesse en production, moins bon pour le debug. Si un
   wrapper observabilité est ajouté plus tard, on pourra logger
   ces exceptions sans changer le contrat public.

5. **Pas d'observabilité** — pas de log, pas de métrique. Une
   phase de monitoring future pourra ajouter des callbacks
   optionnels (`onCacheHit`, `onLocalLoad`, `onRemoteLoad`,
   `onFallback`) injectables.

6. **`localRegistry` mutable** après création** — le `Map`
   passé au constructeur n'est pas copié. Un appelant peut
   modifier la map de l'extérieur. Acceptable car le loader
   est typiquement créé une fois et la map est rarement
   modifiée hors construction. Si besoin de strict immutability,
   wrapper avec `UnmodifiableMapView`.

7. **`centerResolver` peut être lent** — le fallback `await`
   le résolveur sans timeout. Un wrapper futur peut ajouter
   `Future.timeout(Duration(seconds: 3))` si besoin.

## Commande

```bash
# Tests unitaires purs (22 tests, ~0.1s)
flutter test test/services/destination_intelligence_loader_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/services/destination_intelligence_loader.dart : No issues
  → test/services/...test.dart : No issues
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  581 tests verts (559 Tâche 1.2 + 22 nouveaux Tâche 1.3)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré (variation Google Places
  attendue, cf. Tâche 0.1)

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check : PASS
```

## Hors scope (n'est PAS dans cette tâche)

- ❌ Implémentation concrète `SupabaseDestinationIntelligenceRemoteSource`
- ❌ Implémentation concrète `GoogleGeocodingCenterResolver`
- ❌ Branchement au pipeline `places_first_pipeline.dart`
- ❌ Consommation du flag `useDestinationIntelligence`
- ❌ Cache persistant (SharedPreferences, SQLite, etc.)
- ❌ TTL / invalidation automatique
- ❌ Observabilité / métriques cache
- ❌ DayTemplate, SameComplexGroup — Phases ultérieures

## Recommandations pour la Tâche 1.4

Quand le loader sera **enfin branché** au pipeline (probablement
Tâche 1.4 ou plus tard) :

1. Le branchement doit être derrière `flags.useDestinationIntelligence`
   (règle d'or 1).
2. Une implémentation `SupabaseDestinationIntelligenceRemoteSource`
   peut être créée dans un fichier séparé (`lib/services/
   supabase_destination_intelligence_source.dart`) — elle
   importera `supabase_flutter` sans contaminer le loader pur.
3. Le `GeocodingService` existant peut être wrappé via un
   `GeocodingServiceDestinationCenterResolver` similaire — encore
   un fichier séparé.
4. Le pipeline doit lire le loader **une fois par trip** (cache
   trip-scoped), pas par day / par slot.
5. Le snapshot Singapour doit être **comparé** avant/après
   branchement via le comparator de la Tâche 0.4 pour valider
   l'absence de régression.
