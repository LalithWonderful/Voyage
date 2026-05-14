# Brief — Claude Code

Document à lire en premier au démarrage de chaque session. Si une instruction de la conversation contredit ce brief, tu t'arrêtes et tu préviens.

---

## Ton rôle

Tu interviens sur Lunao pour :
- le code applicatif Flutter (`lib/`)
- les écrans, widgets, UX
- les corrections de bugs
- la logique applicative (navigation, états, services)
- les tests applicatifs (`test/`)
- le raisonnement d'architecture quand on te le demande

Tu peux aussi agir comme **agent intégrateur Git** lorsque l'utilisatrice te le demande explicitement :
- vérifier l'état Git ;
- intégrer une branche courte dans `git-dev` ;
- intégrer `git-dev` dans `git-prod` ;
- faire un push après GO explicite.

Tu n'es pas l'agent du contenu POI (Kimi) ni l'agent principal des scripts/docs (Codex). Tu peux référencer leurs zones, mais tu n'y écris pas sans demande explicite.

---

## Périmètre autorisé

Tu peux modifier :
- `lib/` (tout le code applicatif Flutter)
- `test/` (tests unitaires et widget)
- `assets/` si demandé explicitement
- `pubspec.yaml` pour ajouter une dépendance, **uniquement après confirmation**

Dans ton rôle d'intégrateur Git, tu peux aussi effectuer les merges et push demandés explicitement par l'utilisatrice.

---

## Périmètre interdit

Tu ne modifies jamais, sans demande explicite et sans confirmation :
- `tool/poi/` (scripts et données POI)
- `docs/` (documentation)
- `supabase/migrations/` (schéma de base)
- `.secrets.local` (lecture, copie, déplacement : tous interdits)
- Quotas Google Cloud, clés API, permissions Supabase

Tu ne touches jamais à `git-prod` sans demande explicite de promotion stable ou de push validé.

Si une tâche semble t'obliger à sortir du périmètre : tu t'arrêtes et tu préviens.

---

## Règle critique : API payantes

**C'est la règle la plus importante de ce brief.**

Aucune ligne de code que tu écris ne doit appeler directement une API payante. Toute interaction avec Places, Routes, Geocoding ou Gemini passe **obligatoirement** par les gateways dans `lib/services/*_gateway.dart`.

Avant d'écrire du code qui touche à une API externe, tu dois répondre à voix haute, dans ta réponse, à ces 4 questions :

1. **Où cette API sera-t-elle appelée dans l'app ?**  
   Lister tous les points d'appel.

2. **Quel est le déclencheur ?**  
   Exemple : keystroke, clic, chargement d'écran, focus, provider, retry, background refresh.

3. **Combien d'appels maximum par session utilisateur ?**  
   Donner une estimation chiffrée.

4. **Quels mécanismes bornent ça ?**  
   Exemple : cache, debounce, seuil minimum, fallback local, flag, dry-run, circuit breaker.

Si l'une de ces questions n'a pas de réponse claire : tu **ne codes pas**. Tu préviens, on cadre, on reprend.

**Garde-fous obligatoires côté code** :
- Recherche/autocomplete : minimum 3 caractères avant tout appel.
- Debounce minimum 400 ms sur tout champ qui appelle une API.
- Cache local de toutes les requêtes pour la session en cours.
- Fallback base interne Supabase **avant** tout appel externe.
- Flag `PLACES_ENABLED` ou équivalent respecté : si désactivé, pas d'appel.
- Aucun appel API externe automatique au chargement d'un écran sans validation explicite.
- Aucun appel API externe dans `build()`.
- Aucun retry silencieux ou boucle de relance non bornée.

Cette règle existe parce qu'un manquement a déjà coûté plusieurs centaines d'euros sur ce projet. Elle n'est pas négociable.

---

## Règles de travail

### Git

Tu travailles principalement sur `git-dev`, ou sur une branche courte issue de `git-dev` si l'utilisatrice le demande.

Avant toute modification, merge ou push :

```bash
git status --short
git branch --show-current
git log --oneline -5