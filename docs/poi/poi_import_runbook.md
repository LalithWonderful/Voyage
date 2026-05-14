# POI Import Runbook

Procédure simple et fiable pour lancer un import POI batch vers Supabase depuis le worktree principal.

## Prérequis

1. Être dans le worktree principal :

   ```bash
   cd /Users/lalith/Projets/Voyage
   ```

2. `.secrets.local` doit être présent à la racine du repo et contenir :

   ```bash
   export SUPABASE_URL="https://..."
   export SUPABASE_SECRET_KEY="sb_secret_..."
   ```

   `.secrets.local` est listé dans `.git/info/exclude` et **ne doit jamais** être committé.

3. Le script doit être exécutable :

   ```bash
   ls -l tool/poi/import_poi_batch_from_local_secret.sh
   # attendu : -rwxr-xr-x  ...
   ```

   Si ce n'est pas le cas :

   ```bash
   chmod +x tool/poi/import_poi_batch_from_local_secret.sh
   ```

## Détection des villes (sans appel API)

Vérifier ce que le script lirait depuis le manifeste, sans déclencher d'import :

```bash
while IFS= read -r line || [ -n "$line" ]; do
  c="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$c" ] && continue
  case "$c" in \#*) continue ;; esac
  echo "$c"
done < tool/poi/import_city_list.txt
```

Vérifier qu'une fixture existe pour chaque ville (`test/fixtures/poi/pilot_pois_<city>.json`). Sans fixture, le script échoue avec `ERROR: Fixture not found`.

## Commande test — 2 villes

```bash
./tool/poi/import_poi_batch_from_local_secret.sh london amsterdam
```

> Attention : ce n'est **pas** un dry-run global. Le script enchaîne :
> dry-run → import réel Supabase → verify → ré-import idempotence → verify.
> Les villes passées en argument sont effectivement écrites en base.

Rapport généré dans `.local/poi_batch_import_report.md`.

## Commande import — manifeste complet

```bash
./tool/poi/import_poi_batch_from_local_secret.sh
```

Lit `tool/poi/import_city_list.txt` (lignes vides et `#` ignorées) et importe chaque ville séquentiellement. S'arrête sur la première erreur bloquante.

## Manifeste actuel

`tool/poi/import_city_list.txt` doit garder actives uniquement les villes dont la fixture existe :

```
test/fixtures/poi/pilot_pois_<city>.json
```

Villes actives actuelles (7) : `london`, `amsterdam`, `paris`, `rome`, `barcelona`, `lisbon`, `marrakech`.

### Current active cities (23)

| City | Fixture | POIs |
|------|---------|------|
| london | ✅ | 26 |
| amsterdam | ✅ | 26 |
| paris | ✅ | 25 |
| rome | ✅ | 25 |
| barcelona | ✅ | 25 |
| lisbon | ✅ | 10 |
| marrakech | ✅ | 26 |
| istanbul | ✅ | 20 |
| cairo | ✅ | 15 |
| bangkok | ✅ | 18 |
| tokyo | ✅ | 19 |
| singapore | ✅ | 18 |
| madrid | ✅ | 15 |
| vienna | ✅ | 15 |
| prague | ✅ | 15 |
| berlin | ✅ | 15 |
| dublin | ✅ | 15 |
| edinburgh | ✅ | 15 |
| athens | ✅ | 15 |
| venice | ✅ | 15 |
| florence | ✅ | 15 |
| new-york | ✅ | 20 |
| dubai | ✅ | 17 |

### Current backlog (27)

| City | Fixture |
|------|---------|
| munich | ❌ |
| brussels | ❌ |
| bruges | ❌ |
| copenhagen | ❌ |
| stockholm | ❌ |
| oslo | ❌ |
| helsinki | ❌ |
| naples | ❌ |
| porto | ❌ |
| seville | ❌ |
| granada | ❌ |
| valencia | ❌ |
| nice | ❌ |
| lyon | ❌ |
| marseille | ❌ |
| bordeaux | ❌ |
| strasbourg | ❌ |
| los-angeles | ❌ |
| san-francisco | ❌ |
| las-vegas | ❌ |
| miami | ❌ |
| washington-dc | ❌ |
| chicago | ❌ |
| montreal | ❌ |
| quebec-city | ❌ |
| seoul | ❌ |

## Dépannage

### `.secrets.local` absent

Le script s'arrête avec :

```
ERROR: .secrets.local not found in current directory.
```

Solution : créer `.secrets.local` à la racine du worktree principal avec `SUPABASE_URL` et `SUPABASE_SECRET_KEY`, puis :

```bash
echo '.secrets.local' >> .git/info/exclude
echo '.local/' >> .git/info/exclude
```

### Script introuvable

```
zsh: no such file or directory: ./tool/poi/import_poi_batch_from_local_secret.sh
```

Vérifier que tu es bien dans `/Users/lalith/Projets/Voyage` (`pwd`). Le script vit sur `main` depuis le commit `9b386de chore(poi): load batch import cities from manifest`.

### `code --wait: code: command not found`

Survient si un cherry-pick / merge demande un message via `$GIT_EDITOR=code --wait` alors que `code` n'est pas dans le PATH. Forcer un éditeur non interactif pour cette commande :

```bash
GIT_EDITOR=true git cherry-pick --continue
# ou
git -c core.editor=true cherry-pick --continue
```

### Fixture manquante

```
ERROR: Fixture not found: test/fixtures/poi/pilot_pois_<city>.json
```

Soit générer la fixture (pipeline OSM/Overpass — voir `docs/poi/poi_1_1_osm_overpass_extractor.md`), soit retirer la ville du manifeste, soit la passer explicitement seulement quand sa fixture sera prête.

## Worktrees agents — interdit

**Ne pas lancer ce script depuis un worktree agent** (par exemple `Voyage-claude`, `Voyage-kimi`, etc.) si `.secrets.local` n'y est pas présent. Le secret ne doit pas être dupliqué dans les worktrees agents. Les imports POI réels se font uniquement depuis le worktree principal `/Users/lalith/Projets/Voyage`.

## Activation d'une ville backlog

1. Generate or update the fixture for the new city.
2. Validate the fixture with `dart tool/poi/validate_new_fixtures.dart`.
3. Uncomment the city line in `tool/poi/import_city_list.txt`.
4. Run the batch import.
5. Verify the import succeeded and the city is healthy.

## Security

- `.secrets.local` must never be committed.
- The script never prints `SUPABASE_SECRET_KEY`.
- Real imports must only run from `/Users/lalith/Projets/Voyage`.
- Do not copy `.secrets.local` into agent worktrees.
