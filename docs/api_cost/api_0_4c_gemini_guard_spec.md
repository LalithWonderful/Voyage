# API-0.4c — Spec Gemini Guards

## Objectif

Brancher `LiveApiGuards` sur les appels Gemini live, sans inclure Places legacy
dans cette phase.

Services cibles:

- `lib/features/planning/services/ai_suggestions_service.dart`
- `lib/features/assistant/services/assistant_service.dart`

Design retenu a valider avant code:

> cache hit autorise, cache miss Gemini live bloque sans opt-in live.

Les services bas niveau doivent throw `LiveApiBlockedException` quand un appel
Gemini live serait necessaire mais non autorise. Les call sites decideront plus
tard s'ils veulent afficher un message, degrader l'UX, ou proposer une action
manuelle.

## 1. Fichiers a lire

Avant implementation API-0.4c:

- `lib/config/live_api_guards.dart`
- `lib/features/planning/services/ai_suggestions_service.dart`
- `lib/features/assistant/services/assistant_service.dart`
- `lib/features/planning/services/gemini_cache_service.dart`
- `lib/features/planning/providers/planning_provider.dart`
- `lib/features/assistant/providers/assistant_provider.dart`
- `docs/api_cost/api_live_call_inventory.md`
- `test/config/live_api_guards_test.dart`

Fichiers a surveiller sans les modifier en 0.4c sauf compilation necessaire:

- `lib/features/planning/services/places_first_pipeline.dart`
- `lib/features/planning/screens/planning_screen.dart`
- `lib/features/trips/widgets/regional_loop_sheet.dart`
- `lib/features/planning/widgets/alternatives_sheet.dart`
- `lib/features/planning/widgets/suggestion_detail_sheet.dart`

## 2. Fichiers a modifier plus tard

Implementation cible API-0.4c:

- `lib/features/planning/services/ai_suggestions_service.dart`
- `lib/features/assistant/services/assistant_service.dart`
- `lib/features/planning/providers/planning_provider.dart`
- `lib/features/assistant/providers/assistant_provider.dart`
- tests offline nouveaux, probablement:
  - `test/features/planning/services/ai_suggestions_service_gemini_guard_test.dart`
  - `test/features/assistant/services/assistant_service_gemini_guard_test.dart`

Fichiers a ne pas modifier dans API-0.4c:

- `lib/features/planning/services/places_service.dart`
- `lib/features/planning/services/places_nearby_service.dart`
- `lib/features/planning/services/geocoding_service.dart`
- `lib/features/planning/services/routes_service.dart`
- snapshots JSON
- fichiers Phase 4.8

## 3. Appels Gemini live identifies

`AiSuggestionsService`:

- `suggestRegionalItinerary()` via `_generateWithRetry()`
- `generateRaw()`
- `suggestAlternatives()`
- `describeActivitiesBatch()`
- `generateTransportBetween()`
- `describeActivity()`
- `extractDocumentFromText()`
- `extractDocumentFromImage()`

`AssistantService`:

- `sendMessage()`

## 4. Comportement exact de `AiSuggestionsService`

### Injection

Ajouter un champ immutable:

```dart
final LiveApiGuards _guards;
```

Constructeur propose:

```dart
AiSuggestionsService(
  this._client, {
  GeminiCacheService? cache,
  LiveApiGuards? guards,
  GeminiContentGenerator? generator,
})  : _cache = cache,
      _guards = guards ?? LiveApiGuards.fromEnvironment(),
      _generator = generator ?? GoogleGeminiContentGenerator();
```

Le `generator` est recommande pour les tests offline. Il evite d'instancier un
vrai `GenerativeModel` dans les tests et permet de verifier qu'un blocage se
produit avant toute tentative de generation.

### Helper de guard

Ajouter un helper interne unique:

```dart
void _assertGeminiAllowed(String operation) {
  _guards.assertAllowed(
    LiveApiFamily.gemini,
    operation: operation,
  );
}
```

Il doit etre appele apres les cache hits et avant tout `_buildModel()`,
`generateContent(...)`, ou appel au generator.

### Methodes avec cache

`suggestRegionalItinerary()`:

1. Construire la cle cache comme aujourd'hui.
2. Lire `_cache?.get('regional_itinerary', cacheKey)`.
3. Si cache hit valide: retourner le resultat sans exiger `ALLOW_LIVE_GEMINI`.
4. Cache miss: `_assertGeminiAllowed('AiSuggestionsService.suggestRegionalItinerary')`.
5. Ensuite seulement `_checkRateLimit(...)`, generation Gemini, parsing, cache put.

`generateRaw()`:

1. Si `cacheKey != null`, lire le cache action parametree (`raw`,
   `places_first_copilot`, `places_first_auto`, etc.).
2. Si `cached['raw']` existe: retourner sans flag live.
3. Cache absent ou pas de `cacheKey`: `_assertGeminiAllowed('AiSuggestionsService.generateRaw')`.
4. Ensuite generation live et cache put si applicable.

`describeActivitiesBatch()`:

1. Lire les caches `describe_activity` item par item.
2. Si tous les items sont cache hit: retourner sans flag live.
3. S'il reste au moins un miss: `_assertGeminiAllowed('AiSuggestionsService.describeActivitiesBatch')`.
4. Ensuite `_checkRateLimit(...)`, generation batch pour les misses seulement,
   puis cache put.

`generateTransportBetween()`:

1. Lire `_cache?.get('transport_pair', cacheKey)`.
2. Si cache hit valide: retourner sans flag live.
3. Cache miss: `_assertGeminiAllowed('AiSuggestionsService.generateTransportBetween')`.
4. Ensuite `_checkRateLimit(...)`, generation live, cache put.

`describeActivity()`:

1. Lire `_cache?.get('describe_activity', cacheKey)`.
2. Si cache hit valide: retourner sans flag live.
3. Cache miss: `_assertGeminiAllowed('AiSuggestionsService.describeActivity')`.
4. Ensuite `_checkRateLimit(...)`, generation live, cache put.

### Methodes sans cache

`suggestAlternatives()`:

1. Pas de cache aujourd'hui.
2. `_assertGeminiAllowed('AiSuggestionsService.suggestAlternatives')`.
3. Ensuite `_checkRateLimit(...)`, generation live.

`extractDocumentFromText()` et `extractDocumentFromImage()`:

1. Pas de cache aujourd'hui.
2. `_assertGeminiAllowed('AiSuggestionsService.extractDocumentFromText')` ou
   `_assertGeminiAllowed('AiSuggestionsService.extractDocumentFromImage')`.
3. Ensuite `_checkRateLimit(...)`, generation live.

## 5. Comportement exact de `AssistantService`

`AssistantService` n'a pas de cache volontairement: chaque tour depend de
l'historique, du message, du voyage selectionne, des activites et du contexte
deterministe injecte.

Injection proposee:

```dart
class AssistantService {
  final LiveApiGuards _guards;
  final AssistantGeminiGenerator _generator;

  AssistantService({
    LiveApiGuards? guards,
    AssistantGeminiGenerator? generator,
  })  : _guards = guards ?? LiveApiGuards.fromEnvironment(),
        _generator = generator ?? GoogleAssistantGeminiGenerator();
}
```

Ordre de decision dans `sendMessage()`:

1. Si cle Gemini absente ou placeholder: conserver l'erreur actuelle
   `Exception('Cle Gemini manquante.')`.
2. Avant de construire le `GenerativeModel` ou d'appeler le generator:

```dart
_guards.assertAllowed(
  LiveApiFamily.gemini,
  operation: 'AssistantService.sendMessage',
);
```

3. Si autorise: comportement actuel, retry transitoire inclus.
4. Si bloque: throw `LiveApiBlockedException`.

Il ne faut pas convertir `LiveApiBlockedException` en
`AssistantTransientException`, car un blocage cout n'est pas une indisponibilite
Gemini transitoire.

## 6. Strategie d'injection via providers

Ajouter ou reutiliser un provider central:

```dart
final liveApiGuardsProvider = Provider<LiveApiGuards>((ref) {
  return LiveApiGuards.fromEnvironment();
});
```

Puis injecter dans:

```dart
final aiSuggestionsServiceProvider = Provider<AiSuggestionsService>((ref) {
  return AiSuggestionsService(
    ref.watch(supabaseProvider),
    cache: ref.watch(geminiCacheServiceProvider),
    guards: ref.watch(liveApiGuardsProvider),
  );
});
```

Et cote assistant:

```dart
final assistantServiceProvider = Provider<AssistantService>((ref) {
  return AssistantService(
    guards: ref.watch(liveApiGuardsProvider),
  );
});
```

Si un `liveApiGuardsProvider` existe deja apres API-0.4a/0.4b, le reutiliser
au lieu d'en creer un second.

## 7. Cache hit / cache miss

Cache hits autorises sans `ALLOW_LIVE_GEMINI`:

- `regional_itinerary`
- `raw`
- `describe_activity`
- `transport_pair`
- actions custom de `generateRaw()`, notamment `places_first_copilot` et
  `places_first_auto`

Cache miss sans opt-in:

- throw `LiveApiBlockedException`;
- aucun `GenerativeModel` ne doit etre construit;
- aucun `generateContent(...)` ne doit etre appele;
- aucun retry ne doit demarrer.

Cache miss avec opt-in:

- `ALLOW_LIVE_GEMINI=true` autorise Gemini;
- `ALLOW_LIVE_APIS=true` autorise aussi Gemini;
- les cache puts restent best-effort comme aujourd'hui.

## 8. Rate limiting

Constat actuel:

```dart
static const _rateLimitEnabled = false;
```

`_checkRateLimit()` existe et appelle le RPC Supabase
`check_and_log_ai_usage`, mais ce chemin est desactive.

Recommandation API-0.4c:

- ne pas reactiver automatiquement `_rateLimitEnabled` dans le meme commit;
- documenter clairement que le guard Gemini est la protection anti-cout
  immediate;
- garder `_checkRateLimit()` appele uniquement apres le guard et uniquement
  lorsqu'un appel live Gemini est autorise;
- ouvrir une sous-phase dediee pour reactiver le rate limiting apres validation
  du RPC en production et en environnements de test.

Pourquoi ne pas reactiver maintenant:

- le rate limit ajoute des RPC Supabase live a chaque appel Gemini;
- si le RPC n'est pas deploye partout, le comportement dependra des
  environnements;
- API-0.4c doit rester un guard cout offline-testable, pas une migration
  Supabase.

Une API-0.4c-bis ou API-0.4d devrait traiter:

- verification migration SQL du RPC;
- tests offline de `_checkRateLimit()` avec fake Supabase/RPC si possible;
- choix produit des quotas par action;
- comportement quand Supabase rate limit est indisponible.

## 9. Tests offline a creer

Tests `AiSuggestionsService`:

- cache hit `describeActivity()` retourne sans `ALLOW_LIVE_GEMINI` et sans
  appeler le fake generator;
- cache miss `describeActivity()` sans flag throw `LiveApiBlockedException`;
- cache miss `describeActivity()` avec `allowGemini=true` appelle le fake
  generator et ecrit le cache;
- `generateRaw()` cache hit retourne sans flag;
- `generateRaw()` sans `cacheKey` et sans flag throw;
- `describeActivitiesBatch()` avec 100% cache hits retourne sans flag;
- `describeActivitiesBatch()` avec au moins un miss sans flag throw;
- `suggestAlternatives()` sans flag throw avant generation;
- `extractDocumentFromText()` sans flag throw avant generation;
- `ALLOW_LIVE_APIS=true` autorise au moins un chemin Gemini.

Tests `AssistantService`:

- `sendMessage()` sans `ALLOW_LIVE_GEMINI` throw `LiveApiBlockedException`
  avant fake generator;
- `sendMessage()` avec `allowGemini=true` appelle le fake generator;
- `ALLOW_LIVE_APIS=true` autorise `sendMessage()`;
- `LiveApiBlockedException` n'est pas convertie en
  `AssistantTransientException`.

Les tests ne doivent pas:

- instancier un vrai `GenerativeModel`;
- appeler Gemini;
- appeler Supabase;
- lancer `generate_baseline.dart`;
- lancer `places_first_harness.dart`.

## 10. Impacts attendus

Apres implementation API-0.4c:

- les flows planning qui ont deja un cache Gemini valide continuent a lire le
  cache sans flag;
- les flows planning qui ont un cache miss Gemini devront expliciter
  `ALLOW_LIVE_GEMINI=true`;
- l'assistant conversationnel sera bloque par defaut tant que Gemini live n'est
  pas autorise;
- les scripts dangereux restent proteges par API-0.3 et ne doivent pas etre
  lances;
- Places legacy reste hors scope.

## 11. Limites et risques

- Les call sites UI peuvent devoir afficher un message plus doux dans une phase
  ulterieure; API-0.4c doit privilegier la securite cout au niveau service.
- Les methodes sans cache (`suggestAlternatives`, extraction document,
  assistant) seront bloquees par defaut, ce qui peut surprendre en dev si le
  flag n'est pas passe.
- `GeminiCacheService` lui-meme reste un acces Supabase; API-0.4c ne change pas
  la politique `ALLOW_LIVE_SUPABASE`.
- Le rate limiting reste a traiter separement tant que
  `_rateLimitEnabled=false`.
- Les appels Gemini dans `places_first_pipeline.dart` passent via
  `AiSuggestionsService.generateRaw()`; ils seront couverts indirectement, mais
  le fichier ne doit pas etre modifie dans API-0.4c.
