# POI-0.8 — LivePoiSupabaseClient (thin wrapper, no-live-by-default)

## Objectif

Créer le thin wrapper qui connecte le vrai `SupabaseClient` (`supabase_flutter`)
au contrat abstrait `PoiSupabaseClient` (POI-0.7). Aucune logique métier :
seulement de la translation d'appels.

## Livrables

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/data/live_poi_supabase_client.dart` | `LivePoiSupabaseClient` + `LivePoiSupabaseQuery` |
| `test/poi/live_poi_supabase_client_test.dart` | 3 tests structurels offline + 4 tests live opt-in (skipped) |
| `docs/poi/poi_0_8_live_supabase_client.md` | Ce document |

## Architecture

```
PoiRepository (contrat POI-0.6)
    ↑
SupabasePoiRepository (POI-0.7)
    ↓
PoiSupabaseClient ←── LivePoiSupabaseClient (POI-0.8) ←── SupabaseClient (supabase_flutter)
    ↓                                                  (singleton app ou instance locale)
FakePoiSupabaseClient (test POI-0.7)
```

## Implémentation

### LivePoiSupabaseClient

```dart
final liveClient = LivePoiSupabaseClient(Supabase.instance.client);
final repo = SupabasePoiRepository(liveClient);
```

- Wrappe un `SupabaseClient` existant (singleton initialisé au `main()`
  de l'app, ou instance locale pour les tests).
- Implémente `PoiSupabaseClient.from(table)` en retournant un
  `LivePoiSupabaseQuery`.

### LivePoiSupabaseQuery

Accumulateur en mémoire des opérations PostgREST :
- `select`, `eq`, `ilike`, `or`, `inFilter`, `order`, `limit`

Au moment de `execute()` / `maybeSingle()`, construit la chaîne d'appels
PostgREST réelle :

```dart
var builder = _client.from(_table).select(columns);
builder = builder.eq(...);
builder = builder.ilike(...);
builder = builder.or(...);
builder = builder.inFilter(...);
builder = builder.order(...);
builder = builder.limit(...);
return await builder;
```

**Note sur `dynamic`** : le type du builder change à chaque appil (select
→ filter → transform). Le wrapper utilise `dynamic` intentionnellement
pour éviter de recréer toute la hiérarchie de types PostgREST. C'est un
thin wrapper ; la vérification de type se fait à la compilation par
l'interface `PoiSupabaseQuery`.

## Sécurité

- **Read-only** : seules les méthodes `SELECT`-like sont exposées via
  `PoiSupabaseQuery`. Aucun `insert`, `update`, `delete`, `upsert`.
- **Pas de credential hardcodé** : le wrapper reçoit un `SupabaseClient`
  déjà initialisé. Il ne connaît ni l'URL ni la clé anon.

## Tests

### Tests structurels (offline, toujours exécutés)

3 tests qui vérifient :
- `LivePoiSupabaseClient` implémente `PoiSupabaseClient`
- `LivePoiSupabaseQuery` implémente `PoiSupabaseQuery`
- Le chaînage de méthodes est possible (`select().eq().ilike().or()...`)

Ces tests utilisent un `_FakeSupabaseClient` minimal (hérite de
`SupabaseClient` avec une URL fake) et ne font **aucun appel réseau**.

### Tests live (opt-in, skipped par défaut)

4 tests qui vérifient la connexion réelle à Supabase :
- Lecture de la table `pois`
- Lecture de la table `poi_aliases` avec projection de colonnes
- Lecture de la table `poi_tags`
- `maybeSingle` sur un `poi_id` inexistant

**Skipped par défaut.** Pour les exécuter :

```bash
flutter test \
  --dart-define=ALLOW_LIVE_SUPABASE=true \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key> \
  test/poi/live_poi_supabase_client_test.dart
```

Contraintes de sécurité :
- `ALLOW_LIVE_SUPABASE=true` est **obligatoire** (opt-in explicite).
- `SUPABASE_URL` et `SUPABASE_ANON_KEY` doivent être fournis.
- Si l'une des trois variables manque, les tests live sont skipped.
- Le client est instancié directement (`SupabaseClient(url, key)`) sans
  toucher au singleton `Supabase.instance`, évitant tout effet de bord
  sur les autres tests.
- Les credentials ne sont **jamais** commités ; ils passent par
  `--dart-define` ou des variables d'environnement.

## Transition vers l'app complète

Le wrapper est prêt à être injecté dans un provider Riverpod (phase
ultérieure) :

```dart
@Riverpod(keepAlive: true)
PoiRepository poiRepository(Ref ref) {
  final client = Supabase.instance.client;
  return SupabasePoiRepository(LivePoiSupabaseClient(client));
}
```

Mais pour l'instant (POI-0.8) :
- ❌ Pas de provider Riverpod
- ❌ Pas de branchement UI
- ❌ Pas de branchement moteur planning
- ✅ Le wrapper live existe et est testable

## Limites connues

1. **Pas de retry / circuit breaker** : le wrapper ne gère pas les
   erreurs réseau. `SupabasePoiRepository` pourra être enrichi plus tard.
2. **Pas de cache** : chaque appel va directement à Supabase.
3. **Pas de subscription realtime** : read-only pull uniquement.
