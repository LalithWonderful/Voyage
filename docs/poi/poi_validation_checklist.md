# Checklist validation POI — Lunao

Document de référence pour valider ou rejeter un lot POI importé. À utiliser après chaque batch, avant tout merge ou décision de continuer.

Principe : un POI ou un lot **n'est pas validé par intuition**. Il passe une série de checks objectifs.  
L'objectif n'est pas d'avoir une base parfaite dès le départ, mais une base **propre, traçable et non polluée**.

On distingue deux niveaux :

- **MVP validable** : données propres, traçables, utilisables dans Lunao.
- **Premium / enrichi** : données complètes, éditorialisées, prêtes pour des recommandations avancées.

---

## 1. Validation au niveau POI individuel

Pour chaque POI importé, ces critères doivent être contrôlés.

---

### 1.1 Critères bloquants MVP

Un seul KO = POI rejeté ou exclu de la base active.

- [ ] **Nom non vide** et lisible  
  Pas `null`, pas `unnamed`, pas uniquement un code technique.

- [ ] **Coordonnées GPS présentes**  
  Latitude et longitude non nulles.

- [ ] **Coordonnées GPS cohérentes** avec la ville cible  
  Distance raisonnable avec le centre-ville ou la zone importée.

- [ ] **Type / catégorie présent**  
  Exemple : monument, musée, restaurant, parc, shopping, activité.

- [ ] **Catégorie exploitable par Lunao**  
  Pas de catégorie vide, inconnue ou trop générique du type `other` sans mapping.

- [ ] **Source identifiée**  
  Exemple : OSM, Wikidata, Wikipédia, source locale structurée.

- [ ] **ID source présent**  
  Exemple : OSM ID, Wikidata Q-ID, identifiant source stable.

- [ ] **Pas de doublon strict évident**  
  Même nom ou alias très proche + coordonnées très proches.

---

### 1.2 Critères de qualité non bloquants

Ces critères améliorent le niveau du POI, mais ne bloquent pas forcément son intégration MVP.

Chaque critère présent = +1 au score qualité.

- [ ] Adresse complète ou partielle
- [ ] Quartier ou zone identifié
- [ ] Description ou résumé
- [ ] Au moins 1 tag thématique pertinent
- [ ] Horaires d'ouverture
- [ ] Site web officiel
- [ ] Téléphone ou contact
- [ ] Image ou lien image
- [ ] Alias / nom alternatif
- [ ] Lien Wikipédia ou source éditoriale

**Score POI** : sur 10.

| Score | Niveau | Décision |
|---:|---|---|
| 8-10 | Premium | Prêt pour suggestions avancées |
| 5-7 | Bon | Utilisable et à enrichir progressivement |
| 3-4 | MVP faible | Acceptable si POI important, sinon à flagger |
| 0-2 | Très faible | À rejeter ou à retravailler sauf POI incontournable |

---

### 1.3 Critères de rejet immédiat

Si l'un de ces signaux apparaît, le POI est marqué `rejected` et n'entre pas dans la base active.

- [ ] Coordonnées clairement aberrantes : océan, autre pays, `0,0`
- [ ] Nom contenant du HTML, du code ou des caractères de contrôle
- [ ] Description manifestement non éditoriale : spam, menu brut, contenu parasite
- [ ] Doublon strict avec un POI existant
- [ ] Catégorie incohérente : cimetière taggé restaurant, hôtel taggé musée, etc.
- [ ] Contenu adulte, sensible ou hors positionnement Lunao
- [ ] POI manifestement fermé, démoli ou inexistant si l'information est détectée

---

## 2. Validation au niveau ville

Pour chaque ville importée, le rapport doit permettre de décider si la ville est exploitable.

---

### 2.1 Métriques minimales attendues

| Métrique | Seuil MVP acceptable | Seuil cible |
|---|---:|---:|
| Nombre total de POI — petite ville | 15-20 | 40+ |
| Nombre total de POI — ville moyenne | 30-50 | 80+ |
| Nombre total de POI — grande ville touristique | 80+ | 150+ |
| % POI avec coordonnées valides | 100% | 100% |
| % POI avec catégorie exploitable | 100% | 100% |
| % POI avec source identifiée | 100% | 100% |
| % POI avec ID source | 100% | 100% |
| % doublons détectés | < 5% | < 2% |
| Couverture catégories principales | au moins 3 sur 6 | 5 ou 6 sur 6 |
| % POI avec score qualité ≥ 5 | 40% | 70% |
| % POI avec adresse | indicatif | 60%+ |
| % POI avec description | indicatif | 50%+ |

**Catégories principales attendues** :

- monument / patrimoine
- musée / culture
- food
- espace vert / nature
- shopping
- activité / loisir

Les champs adresse et description sont utiles, mais ne doivent pas bloquer un lot MVP si les POI sont propres, géolocalisés, catégorisés et sourcés.

---

### 2.2 Verdict ville

- ✅ **Validée MVP**  
  Les critères bloquants sont respectés, la couverture est suffisante, les données ne polluent pas la base.

- ⭐ **Validée Premium**  
  La ville a une bonne couverture, des descriptions, des adresses, des tags et des POI emblématiques.

- ⚠️ **Validée avec réserves**  
  La ville est utilisable, mais manque d'enrichissement ou présente quelques faiblesses documentées.

- ❌ **À retravailler**  
  Plusieurs seuils MVP sont faibles, des catégories majeures manquent ou le top 5 est incomplet.

- 🚫 **Rejetée**  
  Coordonnées incohérentes, doublons massifs, sources absentes, erreurs structurelles ou données polluantes.

---

### 2.3 Signaux d'alerte ville

À vérifier même si les chiffres passent :

- [ ] Les 5 lieux les plus emblématiques de la ville sont présents ou explicitement signalés comme manquants.
- [ ] Les POI ne sont pas concentrés dans un seul quartier sans raison.
- [ ] Le lot n'est pas biaisé : uniquement restaurants, uniquement églises, uniquement hôtels, etc.
- [ ] Les noms en alphabet local sont correctement encodés.
- [ ] Les alias latins existent pour les villes en alphabet non latin, au moins pour les POI majeurs.
- [ ] Aucun volume anormal : pas 10 POI pour Paris, pas 10 000 POI pour une petite ville.
- [ ] Pas de POI manifestement hors ville ou hors pays.

---

## 3. Validation au niveau batch

Quand un batch couvre plusieurs villes, on vérifie aussi la cohérence globale.

- [ ] Toutes les villes du `tool/poi/import_city_list.txt` ont été traitées.
- [ ] Chaque ville est marquée : importée, réimportée, skipped, erreur ou déjà healthy.
- [ ] Aucune erreur silencieuse dans le log.
- [ ] Le nombre total de POI est cohérent avec la taille du batch.
- [ ] Aucun appel API live non prévu.
- [ ] Aucun appel Google Places non explicitement autorisé.
- [ ] Aucun secret n'apparaît dans les logs.
- [ ] Le rapport est généré et complet.
- [ ] Le commit Git est atomique et nommé.
- [ ] Le POI-check qualité est documenté.

---

## 4. Procédure de validation après import

---

### Étape 1 — Lire le rapport

Ouvrir le rapport généré après import.

Si le rapport manque ou est incomplet :

```text
Stop.
On corrige le script ou le reporting.
On ne valide pas le batch.
