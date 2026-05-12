# POI-1.0 — Écran debug interne POI

## Objectif

Écran de développement minimal pour visualiser et inspecter la qualité des données POI exposées par les providers Riverpod (POI-0.9), avant toute intégration dans le planning ou la carte utilisateur.

## Fichiers livrés

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/debug/poi_debug_screen.dart` | Écran debug complet |
| `test/poi/poi_debug_screen_test.dart` | Tests widget (6 scénarios) |
| `docs/poi/poi_1_0_debug_screen.md` | Ce document |

## Architecture

```
ProfileScreen (kDebugMode)
    └── "Debug POI" button
        └── /debug/poi  (GoRoute, hors ShellRoute)
            └── PoiDebugScreen (ConsumerStatefulWidget)
                ├── _FilterPanel (état local: destination, query, catégorie, must-see, limit)
                ├── poiSearchProvider(_currentParams)  ← Riverpod watch
                └── _PoiListView / _ErrorView / loading
```

## Accès

L'écran est **invisible en release builds** :

- Le bouton d'accès dans `ProfileScreen` est wrappé dans `if (kDebugMode)`.
- La route `/debug/poi` existe toujours dans le router mais n'est pas référencée dans la navigation principale.
- En mode debug, le bouton apparaît dans une section **"DÉVELOPPEMENT"** en bas de l'écran Profil.

## Fonctionnalités

### Filtres

| Filtre | Widget | Provider param |
|--------|--------|----------------|
| `destination_key` | TextField | `PoiSearchParams.destinationKey` |
| Recherche textuelle | TextField | `PoiSearchParams.query` |
| Catégorie | DropdownButtonFormField | `PoiSearchParams.category` |
| Must-see only | Checkbox | `PoiSearchParams.mustSeeOnly` |
| Limite | TextField (number) | `PoiSearchParams.limit` |

### Affichage par POI

Chaque POI est rendu dans une card (`_PoiDebugCard`) affichant :

- **Nom** en gras
- **Catégorie** avec emoji (mapping `_categoryEmojis`)
- **Index** dans la liste + ID tronqué
- **Badge MUST-SEE** (conditionné par `poi.isMustSee`)
- **Métriques** en chips : score, importance touristique, durée, prix, gratuit, famille, pluie
- **Source primaire** (`sourcePrimaryId`) en style monospace

### États

| État | Visuel |
|------|--------|
| `loading` | `CircularProgressIndicator` centré |
| `error` | Icône ⚠️ + message + bouton "Réessayer" |
| `empty` | Icône 📭 + "Aucun POI trouvé" |
| `data` | Liste scrollable de cards |

## Dépannage

**"Aucun POI trouvé" avec destination par défaut (`singapore`)**
→ Le `poiRepositoryProvider` par défaut injecte un `FakePoiRepository` vide. Pour voir des données :
1. Override le provider avec un `FakePoiRepository` peuplé, ou
2. Override avec `SupabasePoiRepository(LivePoiSupabaseClient(...))` si Supabase est configuré.

**Écran inaccessible**
→ Vérifie que l'app est lancée en mode debug (`flutter run`, pas `flutter run --release`).

## Extension future

- Ajouter un affichage des `tags` (nécessite de charger `poi_tags` via un provider dédié).
- Ajouter un mode "liste brute" (JSON) pour déboguer les payloads.
- Ajouter un sélecteur de `destination_key` dynamique (dropdown alimenté par une table destinations).
