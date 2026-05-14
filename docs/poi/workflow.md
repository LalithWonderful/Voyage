# Workflow POI Supabase

## 1. Objectif

Ce workflow sert à importer des lots de POI dans Supabase de manière contrôlée,
traçable et sans mélanger les worktrees. Il fixe les vérifications Git, les
règles de secrets, la source des villes à importer, les conditions d'arrêt, et
le rapport attendu après chaque lot.

## 2. Règle des worktrees

Règle impérative : 1 agent = 1 worktree = 1 branche = 1 tâche.

- `/Users/lalith/Projets/Voyage` est le worktree principal sur `main`. Il sert
  aux imports réels, car c'est le seul worktree qui contient `.secrets.local`.
- `/Users/lalith/Projets/Voyage-kimi` est le worktree Kimi. Kimi y prépare les
  fichiers de villes, les fixtures POI, et les corrections de données.
- `/Users/lalith/Projets/Voyage-codex` est le worktree Codex. Codex y prépare
  l'outillage, les docs, les tests, et les garde-fous.
- Aucun agent ne doit travailler directement dans le même dossier qu'un autre.
- Ne jamais modifier le WIP non lié.
- Ne jamais utiliser `git add .`, `git add -A`, ou `git commit -am`.

## 3. Vérification obligatoire de l'état Git

Avant tout lot POI Supabase, vérifier les trois worktrees :

```bash
cd /Users/lalith/Projets/Voyage
git status --short
git branch --show-current
git log --oneline -5

cd /Users/lalith/Projets/Voyage-kimi
git status --short
git branch --show-current
git log --oneline -5

cd /Users/lalith/Projets/Voyage-codex
git status --short
git branch --show-current
git log --oneline -5
```

## 4. Que faire si les Git ne sont pas alignés ?

### Cas A - `main` n'est pas clean

- Ne pas importer.
- Ne pas merger.
- Identifier les fichiers modifiés.
- Demander validation humaine avant toute action.

### Cas B - le worktree Kimi contient du WIP

- Ne pas toucher.
- Ne pas rebase.
- Ne pas merge.
- Demander à Kimi de commit ou d'abandonner explicitement le WIP.

### Cas C - Codex contient du WIP

- Préserver le WIP.
- Faire un commit atomique si la tâche est terminée.
- Sinon arrêter.

### Cas D - `main`, Kimi et Codex ne pointent pas sur la même base

- Ne pas continuer.
- Revenir à une situation propre.
- Recommander de repartir depuis zéro si l'état est confus.

**Si l'état Git n'est pas compris ou pas aligné, on arrête le workflow POI et on reprend depuis zéro proprement. Aucun import Supabase ne doit être lancé.**

## 5. Liste des villes à importer

Kimi ne doit pas demander à l'utilisateur de saisir manuellement les variables
villes. Kimi doit produire un fichier séparé listant les villes à importer :

```text
tool/poi/import_city_list.txt
```

Format attendu : une ville par ligne.

```text
paris
london
rome
barcelona
lisbon
```

Le script d'import doit lire ce fichier au lieu d'exiger une saisie manuelle de
variables villes. Le script actuel lit déjà `tool/poi/import_city_list.txt`
lorsqu'il est lancé sans argument. Les arguments passés au script sont
actuellement interprétés comme des clés de villes explicites.

## 6. Règle `.secrets.local`

- `.secrets.local` ne doit pas être copié dans les worktrees agents.
- Les imports réels Supabase doivent être lancés depuis
  `/Users/lalith/Projets/Voyage`.
- Le script doit échouer clairement si `.secrets.local` est absent.
- `.secrets.local` ne doit jamais être commité.
- `SUPABASE_SECRET_KEY` ne doit jamais être affiché dans un message, un log, une
  doc versionnée, ou un rapport copié en clair.

## 7. Commande d'import attendue

Commande actuelle recommandée, basée sur `tool/poi/import_city_list.txt` :

```bash
cd /Users/lalith/Projets/Voyage
./tool/poi/import_poi_batch_from_local_secret.sh
```

Commande conceptuelle cible si le script accepte ensuite un fichier manifeste en
argument :

```bash
cd /Users/lalith/Projets/Voyage
./tool/poi/import_poi_batch_from_local_secret.sh tool/poi/import_city_list.txt
```

Le script actuel n'accepte pas encore un chemin de fichier en argument : il
traiterait `tool/poi/import_city_list.txt` comme une clé de ville. Ce
comportement cible doit être implémenté par Kimi ou Codex dans un lot séparé si
on veut passer explicitement le manifeste en argument.

## 8. Rapport obligatoire après import

Chaque import réel doit produire un rapport versionné distinct de `.local/`.
Utiliser le template suivant :

```text
Rapport POI Supabase - [lot]

Résumé

* Date :
* Commit main utilisé :
* Status global :
* Villes vérifiées :
* Villes importées :
* Villes réimportées :
* Villes skipped car déjà healthy :

Résultat par ville

Ville	POIs	Aliases	Links	Tags	Flags	Healthy	Issue
city							

Anomalies détectées

Corrections appliquées

Tests lancés

Limites connues

* POIs sans official_url
* POIs sans address
* Pas encore d'horaires d'ouverture structurés
* Coordonnées approximatives niveau planning
* Couverture faible éventuelle

Actions recommandées

Sujet	Action	Priorité	Owner
			
```

Le rapport local généré dans `.local/` est un artefact d'exécution et ne doit
pas être versionné.

## 9. Tests à lancer

Les tests POI disponibles sont sous `test/poi`. Pour un lot POI large, lancer :

```bash
flutter test test/poi
```

Pour une validation ciblée selon les fichiers touchés, confirmer les tests
exactement présents avec :

```bash
rg --files test/poi
```

Tests POI actuellement présents :

- `test/poi/fixture_poi_repository_test.dart`
- `test/poi/live_poi_supabase_client_test.dart`
- `test/poi/mvp_poi_fixture_importer_test.dart`
- `test/poi/osm_poi_mapping_test.dart`
- `test/poi/poi_debug_screen_test.dart`
- `test/poi/poi_domain_models_test.dart`
- `test/poi/poi_fixture_dry_run_test.dart`
- `test/poi/poi_fixture_multi_city_test.dart`
- `test/poi/poi_fixture_reviewer_test.dart`
- `test/poi/poi_mvp_fixture_contract_test.dart`
- `test/poi/poi_providers_test.dart`
- `test/poi/poi_repository_contract_test.dart`
- `test/poi/poi_repository_provider_test.dart`
- `test/poi/poi_sql_contract_test.dart`
- `test/poi/poi_staging_import_test.dart`
- `test/poi/poi_supabase_import_checker_test.dart`
- `test/poi/poi_supabase_importer_test.dart`
- `test/poi/supabase_live_guard_test.dart`
- `test/poi/supabase_poi_repository_test.dart`

Ne pas lancer de test ou script avec opt-in live (`ALLOW_LIVE_*`) pendant une
validation ordinaire.

## 10. Commit attendu

Avant commit :

```bash
git status --short
```

Stager uniquement :

```bash
git add docs/poi/workflow.md
```

Ne pas utiliser `git add .`, `git add -A`, ou `git commit -am`. Ne pas toucher
aux fichiers non liés.

Commit attendu :

```bash
git commit -m "docs(poi): document safe supabase import workflow"
```
