# API-0.5 — No live API by default (consolidation)

## 1. Objectif

API-0.5 ne livre aucun nouveau service guardé. C'est la phase de
consolidation qui prouve que Lunao est en mode :

> no live API by default

pour toutes les familles d'appels live critiques inventoriees en
API-0.1, et qui documente noir sur blanc :

- l'etat exact des guards livres en API-0.2 a API-0.4d ;
- ce qui reste hors scope ;
- les commandes interdites par defaut ;
- les seules commandes live autorisees explicitement ;
- la checklist a satisfaire avant un eventuel run A/B live controle
  (Tache 4.9).

API-0.5 ajoute uniquement :

- ce document ;
- un test de consolidation offline `test/config/live_api_guard_integration_test.dart`.

Aucun service de production n'est modifie en API-0.5. Aucun appel live
n'est consomme.

## 2. Etat des guards livres

Phases successives livrees, chacune validee par un commit dedie :

| Phase | Sujet | Commit |
| --- | --- | --- |
| API-0.1 | Inventaire des appels live | `8f3d0a0` |
| API-0.2 | `LiveApiGuards` central + enum `LiveApiFamily` | `76fa230` |
| API-0.3 | Guards des scripts dangereux | `2c937f4` |
| API-0.4a | `PlacesNearbyService` + `GeocodingService` | `fb31b2f` |
| API-0.4b | `RoutesService` | `83febcd` |
| API-0.4c | `AiSuggestionsService` + `AssistantService` (Gemini) | `ab090db` |
| API-0.4d | `PlacesService` legacy | `fecec63` |
| API-0.5 | Consolidation + doc + test integration | `<commit en cours>` |

Module central :

- `lib/config/live_api_guards.dart` — classe immutable `LiveApiGuards`,
  enum `LiveApiFamily`, exception `LiveApiBlockedException`.
- Defaults fermes : chaque famille est bloquee tant qu'un flag
  `--dart-define` ne l'autorise pas explicitement.
- Flag global `ALLOW_LIVE_APIS=true` autorise toutes les familles ;
  sinon chaque famille requiert son flag specifique.

Helper test-only :

- `test/helpers/live_api_script_guards.dart` — `LiveApiScriptGuardException`
  + message pedagogique pour les deux scripts dangereux.

## 3. Familles couvertes

Les familles suivantes throw `LiveApiBlockedException` avant tout
`http.*` quand un appel live serait necessaire et que le flag
correspondant n'est pas explicitement vrai.

| Famille `LiveApiFamily` | Flag dart-define | Service(s) gardes | Cache hit autorise sans flag |
| --- | --- | --- | --- |
| `googlePlaces` | `ALLOW_LIVE_GOOGLE_PLACES` | `PlacesNearbyService` (API New), `PlacesService` (legacy) | Oui via `gemini_cache` / `places_cache` / `place_lookup_cache` |
| `googleGeocoding` | `ALLOW_LIVE_GOOGLE_GEOCODING` | `GeocodingService` | Pas de cache dedie ; toute query non vide passe par le guard |
| `googleRoutes` | `ALLOW_LIVE_GOOGLE_ROUTES` | `RoutesService` | Oui via `gemini_cache` action `routes_pair` |
| `gemini` | `ALLOW_LIVE_GEMINI` | `AiSuggestionsService`, `AssistantService` | Oui via `gemini_cache` pour les actions cachees ; les paths sans cache requierent le flag |

Comportements communs :

- `LiveApiBlockedException` est leve avant le `http.*` ; aucun appel
  reseau n'est tente.
- Les cache hits valides restent autorises pour eviter de degrader
  inutilement l'UX quand la donnee est deja en cache Supabase.
- Pour les services sans cache (Geocoding, Assistant), tout appel non
  trivial est garde.
- `LiveApiBlockedException` n'est pas converti en `[]` / `null` /
  `AssistantTransientException` silencieux ; les call sites recoivent
  l'exception et decident.

## 4. Familles encore non couvertes ou partiellement couvertes

Les familles ci-dessous sont declarees dans `LiveApiFamily` mais ne sont
pas encore branchees sur des services / call sites.

### 4.1 Supabase live (`supabase`)

- Inventaire : Auth, PostgREST, RPC, Storage.
- Flag prevu : `ALLOW_LIVE_SUPABASE`.
- Etat : non branche. `LiveApiGuards` connait la famille mais aucun
  service Supabase ne l'invoque encore.
- Risque concret : tout test ou script qui passe par `Supabase.initialize()`
  + providers reels peut toucher l'instance Supabase de developpement.
- Mitigation actuelle : les scripts dangereux `generate_baseline.dart`
  et `places_first_harness.dart` n'instancient pas Supabase (cf.
  API-0.3 §"Supabase n'est pas requis"). Les tests offline n'utilisent
  pas le client reel. Aucun guard automatique ne couvre encore un
  hypothetique script futur qui appellerait Supabase.

### 4.2 Network images / Place Photo URLs (`networkImages`)

- Flag prevu : `ALLOW_LIVE_NETWORK_IMAGES`.
- Etat : non branche.
- Sources : `CachedNetworkImage` (`suggestion_detail_sheet.dart`,
  `activity_detail_sheet.dart`, `alternatives_sheet.dart`,
  `planning_screen.dart`), `NetworkImage` avatar (`profile_screen.dart`).
- Risque concret : `PlacesService.findInfo()` construit des URLs
  Place Photo ; meme si `findInfo` lui-meme est garde en API-0.4d, des
  URLs deja resolues (cachees en base) peuvent encore declencher un
  chargement live d'image cote UI. Hors run UI reel, ce risque est
  nul en tests offline.
- Decision : laisser hors scope API-0 jusqu'a une phase UI dediee.

### 4.3 Google Maps SDK / URLs externes

- Pas de famille dediee dans `LiveApiFamily`. Les sorties Maps URLs sont
  des `launchUrl()` (web ou app externe) et ne consomment pas l'API
  Maps cote Lunao.
- Risque concret : affichage `GoogleMap` (`google_maps_flutter`) dans
  `trip_map_screen.dart` peut consommer le quota Maps SDK selon le
  billing. Aucun guard cote app.
- Decision : tracker comme cout produit, hors `LiveApiGuards`.

### 4.4 Geolocator / position appareil (`deviceLocation`)

- Flag prevu : `ALLOW_LIVE_DEVICE_LOCATION`.
- Etat : non branche.
- Surface : `LocationService.instance.getCurrentLocation()` utilise
  par `planning_screen.dart` pour certains trajets.
- Risque concret : pas de cout API direct, mais comportement
  utilisateur non-deterministe en tests / runs scripts. Aucun
  test ni script offline n'appelle ce service aujourd'hui.

### 4.5 Frankfurter currency API (`currencyApi`)

- Flag prevu : `ALLOW_LIVE_CURRENCY_API`.
- Etat : non branche.
- Surface : `CurrencyService.getRate()` utilise par
  `currency_provider.dart` et `planning_provider.dart` pour le
  calcul budget.
- Risque concret : appel HTTP `api.frankfurter.app` sans coût Google,
  mais reseau requis. Aucun test offline n'appelle ce service.

### 4.6 Synthese de couverture

| Famille | Branche services | Tests offline | Risque residuel |
| --- | --- | --- | --- |
| `googlePlaces` | Oui (Places New + legacy) | Oui | Faible — defense-in-depth en place |
| `googleGeocoding` | Oui | Oui | Faible |
| `googleRoutes` | Oui | Oui | Faible |
| `gemini` | Oui (AiSuggestions + Assistant) | Oui | Faible |
| `supabase` | Non | N/A | Moyen si nouveau script Supabase est ajoute |
| `networkImages` | Non | N/A | Faible hors run UI reel |
| `deviceLocation` | Non | N/A | Faible — pas d'usage en script |
| `currencyApi` | Non | N/A | Faible — Frankfurter free tier |

## 5. Scripts proteges

Les deux scripts capables de generer des dizaines a centaines de RPC
Google par run sont proteges des le boot :

- `test/snapshots/generate_baseline.dart` — appelle
  `assertLiveApisAllowedForGenerateBaseline()` avant de creer
  `GeocodingService` et `PlacesNearbyService`.
- `test/dev/places_first_harness.dart` — appelle
  `assertLiveApisAllowedForPlacesFirstHarness()` avant le pipeline.

Familles requises pour chaque script :

- `generate_baseline.dart` : `googlePlaces` + `googleGeocoding`.
- `places_first_harness.dart` : `googlePlaces` + `googleGeocoding`.

Sans flags, les scripts echouent immediatement avec un message
`LiveApiScriptGuardException` qui liste :

- le nom complet du script ;
- les familles manquantes ;
- la liste exacte des `--dart-define=...` requis.

Defense en profondeur : meme si le guard de script etait contourne,
chaque service bas niveau (`PlacesNearbyService`, `GeocodingService`,
`RoutesService`, `PlacesService`, `AiSuggestionsService`,
`AssistantService`) refuse le live tant que son flag specifique n'est
pas vrai.

## 6. Commandes interdites par defaut

Aucune des commandes suivantes ne doit etre lancee tant qu'aucun flag
explicite n'est passe :

```bash
flutter test test/snapshots/generate_baseline.dart
flutter test test/dev/places_first_harness.dart
```

Tout `flutter run` lance en local depuis une session refonte / API
sans intention explicite de hit live Google / Gemini est aussi a
considerer comme interdit. Les services de production sont gardes ;
ils throw, ils ne fallback pas silencieusement.

Commande de sanity check des guards (offline, autorisee) :

```bash
flutter test test/config/live_api_guards_test.dart
flutter test test/snapshots/generate_baseline_guard_test.dart
flutter test test/config/live_api_guard_integration_test.dart
```

## 7. Commandes live autorisees explicitement

Toute commande ci-dessous consomme du quota live et doit etre lancee
uniquement avec opt-in user explicite, dans le cadre d'une tache
identifiee (par exemple Tache 4.9 A/B live).

Baseline snapshot Singapour (Places + Geocoding) :

```bash
flutter test \
  --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true \
  --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true \
  test/snapshots/generate_baseline.dart
```

Harness Places-first multi-profils :

```bash
flutter test \
  --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true \
  --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true \
  test/dev/places_first_harness.dart
```

Run d'une partie ciblee de l'app avec une seule famille (exemple
Gemini uniquement) :

```bash
flutter test \
  --dart-define=ALLOW_LIVE_GEMINI=true \
  <test cible>
```

Ouverture complete (deconseillee en cout-sensible) :

```bash
flutter test --dart-define=ALLOW_LIVE_APIS=true <test cible>
```

Toujours preferer les flags specifiques aux flags globaux pour
limiter l'exposition.

## 8. Checklist avant 4.9 A/B live controle

Pre-requis a cocher avant tout run live de la Tache 4.9 sur Singapour.
Tous obligatoires.

- [x] `LiveApiGuards` central livre (API-0.2, `76fa230`).
- [x] Scripts `generate_baseline.dart` et `places_first_harness.dart`
      proteges (API-0.3, `2c937f4`).
- [x] `PlacesNearbyService` + `GeocodingService` gardes (API-0.4a,
      `fb31b2f`).
- [x] `RoutesService` garde (API-0.4b, `83febcd`).
- [x] `AiSuggestionsService` + `AssistantService` gardes (API-0.4c,
      `ab090db`).
- [x] `PlacesService` legacy garde (API-0.4d, `fecec63`).
- [x] Document API-0.5 valide et test de consolidation offline vert.
- [ ] User opt-in explicite et trace pour le run live (4.9 A/B).
- [ ] Flags requis explicites en ligne de commande :
      `--dart-define=ALLOW_LIVE_GOOGLE_PLACES=true`
      `--dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true`
      `--dart-define=ALLOW_LIVE_GOOGLE_ROUTES=true` si Routes est dans
      le scope du run.
      Gemini reste `false` pour 4.9 (le pipeline 4.7+ est deterministe).
- [ ] Budget chiffre estime avant run (RPC Places ~50-100/profil,
      Geocoding ~quelques unites par profil).
- [ ] Aucun service Supabase ecrit pendant le run (les scripts gardes
      n'utilisent pas Supabase).

Tant que les trois dernieres cases ne sont pas explicitement cochees
par l'utilisateur en debut de session 4.9, ne lancer aucun
`flutter test ... --dart-define=ALLOW_LIVE_*=true`.

## 9. Risques restants

Risques connus a la cloture d'API-0.5 :

1. **Supabase live non garde** — un futur script qui instancie
   `Supabase.initialize()` ou un provider auth/PostgREST/Storage peut
   appeler la base de dev sans opt-in. Mitigation : tout nouveau
   script doit ajouter `LiveApiGuards.assertAllowed(supabase, ...)`
   au boot. Une famille dediee `ALLOW_LIVE_SUPABASE` existe deja dans
   le module central, il suffit de la brancher.
2. **Network images via URLs deja cachees** — si une donnee
   `places_cache` ou `place_lookup_cache` contient deja une URL Place
   Photo, l'UI peut declencher un GET image en runtime. Pas un appel
   Places facturable au sens RPC, mais c'est un trafic Google. Hors
   run UI reel, ce risque est nul.
3. **Maps SDK / `GoogleMap` widget** — affichage carte consomme du
   quota Maps SDK quand l'ecran s'ouvre. Pas garde par
   `LiveApiGuards` (concept different : SDK natif vs API REST). A
   tracker comme cout produit dedie.
4. **Geolocator / Frankfurter** — pas de garde, surface limitee et
   inoffensive en runs offline. A surveiller si un script futur les
   utilise.
5. **Cache hits Places** — autorises sans flag par design ; si le
   cache Supabase est vide (env neuf, table tronquee), le premier
   appel ira live, donc le guard est bien ce qui empeche un cold start
   massif sans flag.
6. **Flag global `ALLOW_LIVE_APIS=true`** — ouvre tout d'un coup.
   A reserver aux runs internes coute-controles ; preferer les flags
   specifiques.
7. **Tests existants qui instancient un service garde sans flag** —
   si un test cree `PlacesService()` ou `GeocodingService()` sans
   injecter de guards autorises et tente un live, il throw
   `LiveApiBlockedException`. C'est le comportement voulu mais ca
   peut casser un test legacy si l'un d'eux n'avait pas ete migre.
   Mitigation : tests bas niveau utilisent fakes et n'atteignent pas
   le live ; cas residuel a traiter au cas par cas.

## 10. Conclusion no-live-by-default

A la cloture d'API-0.5, Lunao est en mode :

- defaults fermes : `LiveApiGuards.defaults()` et
  `LiveApiGuards.fromEnvironmentMap({})` bloquent les 8 familles ;
- 4 familles critiques (`googlePlaces`, `googleGeocoding`,
  `googleRoutes`, `gemini`) gardees au niveau service avec
  defense-in-depth ;
- 2 scripts dangereux gardes au niveau script avant toute
  instanciation de service ;
- une famille (`supabase`) declaree mais pas encore branchee, jugee
  non bloquante car aucun script ou test offline ne l'invoque ;
- 3 familles restantes (`networkImages`, `deviceLocation`,
  `currencyApi`) declarees mais pas encore branchees, surface jugee
  faible pour API-0 ;
- aucune commande `flutter test ... live` ne peut s'executer sans
  flag explicite ;
- ce document + le test integration offline servent de filet final
  contre une regression du regime no-live-by-default.

A partir d'ici, et tant que les trois cases finales de la section 8
ne sont pas cochees, **aucun appel live Google Places / Routes /
Geocoding / Gemini ne sera consomme par Lunao**.

Prochaine etape une fois l'opt-in obtenu : Tache 4.9 A/B live controle
sur Singapour (cf. `docs/migrations/phase5_readiness_checklist.md`
section B pour les seuils chiffres a atteindre).
