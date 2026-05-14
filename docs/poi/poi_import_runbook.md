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

`tool/poi/import_city_list.txt` liste 12 villes. Fixtures disponibles à la date du runbook : `london`, `amsterdam`, `paris`, `rome`, `barcelona`, `lisbon`, `marrakech`. Manquantes : `istanbul`, `cairo`, `bangkok`, `tokyo`, `singapore` — il faut générer leur fixture avant d'utiliser le manifeste complet, sinon le script s'arrête à la première ville sans fixture.

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
