import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:voyage/config/feature_flags.dart';
import 'package:voyage/data/complexes/complex_registry.dart';
import 'package:voyage/data/day_templates/day_template_registry.dart';
import 'package:voyage/data/destinations/destination_intelligence_registry.dart';
import 'package:voyage/features/planning/data/destination_blueprints.dart';
import 'package:voyage/features/planning/data/metro_profile.dart';
import 'package:voyage/features/planning/data/segment_city_canonicals.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/day_builder.dart';
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/interests_to_places_mapping.dart';
import 'package:voyage/features/planning/data/destination_key_mapper.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/poi_candidate_adapter.dart';
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/planning/services/template_first_pipeline.dart';
import 'package:voyage/models/destination_intelligence.dart';
import 'package:voyage/models/same_complex_group.dart';
import 'package:voyage/services/complex_matcher.dart';
import 'package:voyage/services/destination_scope_rejection.dart';
import 'package:voyage/services/same_complex_rejection.dart';
import 'package:voyage/services/scope_validator.dart';

/// Champs UX/profil **pas encore exploités** par le pipeline de suggestion
/// (audit Niveau A 2026-05-08, à creuser plus tard) :
/// - **Pondération des intérêts** : tous traités à poids égal aujourd'hui.
///   Sera ajouté avec une UI "jusqu'à 3 intérêts favoris".
/// - **Âge des voyageurs** (`trip.travelers.age`) : seul `hasKids` (any < 13)
///   est exploité dans le prompt Gemini. Pas de différenciation senior /
///   jeune adulte / etc. dans le scoring.
/// - **Nombre de voyageurs** : non exploité (resto pour 2 vs 5 = même reco).
/// - **Distinction couple/famille/solo/amis** : passe seulement par
///   `trip.travelerType`, pas par la composition réelle.
/// - **`trip.budgetIncludesFlight`** : Assistant Lunao uniquement.
/// - **`user_profiles.preferred_*_transport_mode`** : pas branché ici.
///   L'override voyage `trip.localTransportMode` est consommé, pas le profil
///   global. À ajouter en V2 quand UI profil sera livrée.
/// - **`trip.targetPeriod`/`periodMode`** : affichage uniquement, pas exploité
///   pour différencier saison touristique/basse dans le scoring.

/// Cap maximum de `priceLevel` Places (échelle 0-4) en fonction du budget
/// par personne déclaré sur le voyage. Logique prudente : on évince
/// uniquement les lieux dont le priceLevel est manifestement incohérent
/// avec le budget. Les lieux sans priceLevel (Google le manque souvent)
/// sont toujours conservés.
///
/// Seuils (validés Lalith 2026-05-08) :
/// - < 50 €/jour     → cap 2 (économique : street food, casual)
/// - 50-120 €/jour   → cap 3 (standard : bistrots, restos corrects)
/// - > 120 €/jour    → pas de cap (autorise priceLevel 4)
///
/// Retourne null si pas de budget ou durée invalide → comportement actuel
/// (cap géré exclusivement par le profil voyageur).
int? priceLevelCapForBudget({
  required num? budgetPerPersonEur,
  required int durationDays,
}) {
  if (budgetPerPersonEur == null || durationDays <= 0) return null;
  final perDay = budgetPerPersonEur / durationDays;
  if (perDay < 50) return 2;
  if (perDay < 120) return 3;
  return null;
}

/// Clé stable pour dédupliquer un candidat dans le sélecteur global. On
/// privilégie le `placeId` Google (unique et fiable). Fallback prudent :
/// nom normalisé + coords arrondies à 3 décimales (~111m × 73m en France)
/// pour les rares cas où placeId est vide.
String _dedupKeyForCandidate(NearbyCandidate c) {
  if (c.placeId.isNotEmpty) return 'pid:${c.placeId}';
  final lat = c.latitude.toStringAsFixed(3);
  final lng = c.longitude.toStringAsFixed(3);
  return 'name:${_normalizeForMatch(c.name)}@$lat,$lng';
}

/// Multiplicateur appliqué à `maxConsecutiveDistanceMeters` selon le mode
/// de déplacement local choisi par l'utilisateur. Permet de resserrer le
/// clustering si l'utilisateur préfère marcher, ou de l'élargir s'il
/// préfère taxi/voiture (validé Lalith 2026-05-08).
///
/// Si null ou 'best' → 1.0 (comportement actuel basé sur le profil voyageur).
double transportDistanceFactor(String? localTransportMode) {
  switch (localTransportMode) {
    case 'walk':
      return 0.7;
    case 'public_transport':
      return 1.0;
    case 'taxi':
      return 1.5;
    case 'car':
      return 1.3;
    case 'scooter':
      return 1.2;
    default:
      // 'best', null, 'comfort', 'budget' → conservatif, pas de modif.
      return 1.0;
  }
}

/// Distance maximum effective entre 2 activités successives, en croisant
/// le profil voyageur (base) et la préférence de transport local de
/// l'utilisateur (multiplicateur). Fallback : 1500m si aucun profil.
int effectiveMaxConsecutiveDistance({
  required TravelerPlacesProfile? travelerProfile,
  required String? localTransportMode,
  int fallback = 1500,
}) {
  final base = travelerProfile?.maxConsecutiveDistanceMeters ?? fallback;
  final factor = transportDistanceFactor(localTransportMode);
  return (base * factor).round();
}

/// Stopwords FR/EN à ignorer quand on tokenise une query pour le check de
/// matching. Tout mot ≤4 chars OU dans cette liste est considéré comme
/// non-significatif (articles, prépositions, auxiliaires) et ne participe pas
/// au matching. Ex: "parc du château" → mots signif = ["parc", "château"].
const Set<String> _queryStopwords = <String>{
  // FR
  'le', 'la', 'les', 'un', 'une', 'des', 'du', 'de', 'au', 'aux', 'et', 'ou',
  'avec', 'sans', 'sur', 'sous', 'dans', 'pour', 'par', 'chez', 'mais', 'donc',
  // EN
  'the', 'a', 'an', 'of', 'in', 'on', 'at', 'and', 'or', 'with', 'without',
  'for', 'by', 'to', 'from',
};

/// Normalise une string pour le matching : lowercase + suppression des
/// diacritiques courants (français/espagnol/italien). Volontairement simple,
/// pas de package externe — couvre 95% des cas FR.
String _normalizeForMatch(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[àâäáã]'), 'a')
      .replaceAll(RegExp(r'[éèêëẽ]'), 'e')
      .replaceAll(RegExp(r'[îïíìĩ]'), 'i')
      .replaceAll(RegExp(r'[ôöóòõ]'), 'o')
      .replaceAll(RegExp(r'[ùûüúũ]'), 'u')
      .replaceAll(RegExp(r'[ç]'), 'c')
      .replaceAll(RegExp(r'[ñ]'), 'n');
}

/// Tokenize une string en mots significatifs pour le matching :
/// - normalisation accents/casse
/// - split sur tout caractère non alphanumérique
/// - garde uniquement les mots de longueur ≥4 ET hors stopwords
List<String> _significantWords(String s) {
  final normalized = _normalizeForMatch(s);
  return normalized
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length >= 4 && !_queryStopwords.contains(w))
      .toList(growable: false);
}

/// Mots qui décrivent une **catégorie sémantique** plutôt qu'un nom propre.
/// Si tous les mots significatifs d'une query sont dans cet ensemble, on
/// considère la query comme générique et on désactive le hard filter
/// `_filterByQueryNameMatch` (les Places ne s'appellent jamais "Cheap Eats"
/// ou "Free Activities" — l'API Google Places les retourne par sémantique
/// d'établissement, pas par nom).
///
/// Cas concrets observés (logs Lalith 2026-05-08) :
/// - "cheap eats" / "budget restaurant" / "pique-nique" → restos locaux
///   sans ces mots dans le nom (Restaurant Sayef, Khmissa, ...)
/// - "free activities" → Place Moulay Hassan, Port Sqala, ...
/// - "fine dining" / "rooftop bar" → restos haut-de-gamme
/// - "viewpoint" / "scenic stop" → points de vue
/// - "hostel" / "coworking" / "guided tour" → catégories métier
const Set<String> _genericCategoricalQueryWords = <String>{
  // Budget/prix
  'cheap', 'eats', 'budget', 'free', 'pique', 'nique', 'lowcost',
  'economique', 'gratuit', 'pascher',
  // Catégorie générique
  'activities', 'activity', 'restaurant', 'food', 'tour', 'tours',
  'hostel', 'hotel', 'cafe', 'bar', 'walking', 'guided',
  // Style culinaire/expérience
  'fine', 'dining', 'street', 'local', 'rooftop', 'romantic', 'sunset',
  'cozy', 'quiet', 'wellness', 'lively', 'photo', 'spot', 'spots',
  'night', 'market', 'hall', 'business', 'lunch', 'breakfast', 'dinner',
  // Travel
  'viewpoint', 'scenic', 'roadside', 'diner', 'coworking',
  'boutique', 'michelin', 'luxury', 'spa',
};

/// True si la query est composée UNIQUEMENT de mots dans
/// [_genericCategoricalQueryWords]. Dans ce cas le filtre name-match est
/// trop strict et rejette des candidats valides — on retombe en mode
/// "garde tout, scoring départage".
bool _isGenericCategoricalQuery(List<String> queryWords) {
  if (queryWords.isEmpty) return true;
  return queryWords.every(_genericCategoricalQueryWords.contains);
}

/// Pour certaines queries spécifiques, certains types Places sont des
/// signaux **forts** qui justifient l'acceptation même si le nom du Place
/// ne contient pas de mot de la query. Évite de rejeter "Royal Theatre"
/// (`performing_arts_theater`) pour la query "salle de spectacle" sous
/// prétexte que le mot "salle" n'est pas dans le name (logs Lalith
/// 2026-05-08).
///
/// Match : la clé de map est cherchée par préfixe normalisé dans la query
/// (ex: query "salle de concert" matche la clé "salle de concert", la
/// query "théâtre" matche "theatre"). Permet de couvrir les variations
/// FR/EN sans dupliquer.
const Map<String, Set<String>> _queryStrongTypes = <String, Set<String>>{
  // ─── Spectacles / scènes / concerts / cinéma ─────────────────────
  'salle de spectacle': {
    'performing_arts_theater',
    'event_venue',
    'cultural_center',
    'live_music_venue',
    'movie_theater',
    'convention_center',
  },
  'salle de concert': {
    'performing_arts_theater',
    'event_venue',
    'live_music_venue',
    'cultural_center',
    'movie_theater',
  },
  'theatre': {'performing_arts_theater', 'event_venue', 'cultural_center'},
  'concert': {
    'performing_arts_theater',
    'event_venue',
    'live_music_venue',
    'cultural_center',
  },
  'cinema': {'movie_theater'},
  'spectacle': {
    'performing_arts_theater',
    'event_venue',
    'cultural_center',
    'live_music_venue',
  },
  'cabaret': {
    'performing_arts_theater',
    'event_venue',
    'cultural_center',
    'live_music_venue',
  },
  'festival': {
    'event_venue',
    'cultural_center',
    'performing_arts_theater',
    'stadium',
    'arena',
  },
  'live music': {
    'live_music_venue',
    'performing_arts_theater',
    'event_venue',
    'cultural_center',
  },
  // ─── Sport-événement (à regarder, pas pratiqué) ──────────────────
  // Les écoles/salles de pratique remontent via Activité et leur
  // primaryType (`sports_school`, `gym`, `fitness_center`) — pas ici.
  'kick boxing event': {'stadium', 'arena', 'event_venue', 'sports_complex'},
  'boxing event': {'stadium', 'arena', 'event_venue', 'sports_complex'},
  // ─── Quality-1C (Lalith 2026-05-10) — queries catégorielles
  // Shopping/Culture/Nature qui rejetaient leurs candidats en lexical
  // mismatch sur Paris. L'infra `_queryStrongTypes` accepte le lieu
  // sur match du primary type, sans exiger le mot de la query dans
  // le name (cas BHV Marais / Samaritaine pour "rue commerçante",
  // Tour Saint-Jacques pour "monument historique", etc.).
  // ─── Shopping ────────────────────────────────────────────────────
  // NB : clés normalisées (sans accents) — `_strongTypesForQuery`
  // applique `_normalizeForMatch` sur la query qui strip les accents
  // (« commerçante » → « commercante »). Une seule clé par variante.
  'rue commercante': {
    'shopping_mall',
    'department_store',
    'clothing_store',
    'shoe_store',
    'gift_shop',
    'jewelry_store',
    'book_store',
    'market',
    'store',
  },
  'boutique souvenirs': {'gift_shop', 'souvenir_store', 'store'},
  'magasin d': {
    // Capture "magasin d'usine" (apostrophe normalisée selon
    // `_normalizeForMatch`). Outlet → shopping types.
    'shopping_mall', 'department_store', 'outlet_store', 'store',
  },
  'marche local': {'market', 'farmers_market', 'flea_market'},
  // ─── Culture (monuments / sites historiques / etc.) ──────────────
  'monument historique': {
    'historical_landmark',
    'historical_place',
    'monument',
    'tourist_attraction',
    'cultural_landmark',
  },
  'site historique': {
    'historical_landmark',
    'historical_place',
    'monument',
    'tourist_attraction',
    'cultural_landmark',
  },
  'lieu historique': {
    'historical_landmark',
    'historical_place',
    'monument',
    'tourist_attraction',
    'cultural_landmark',
  },
  'site culturel': {
    'cultural_center',
    'tourist_attraction',
    'museum',
    'historical_landmark',
  },
  'patrimoine culturel': {
    // Strict — ne s'applique que si type fort présent. Aussi marqué
    // dans `_strictNoLexicalQueries` (lexical mismatch insuffisant,
    // le strong type devient mandatory).
    'historical_landmark', 'historical_place', 'monument',
    'tourist_attraction', 'cultural_center', 'museum', 'art_museum',
    'history_museum', 'cultural_landmark',
  },
  // ─── Nature / vues ──────────────────────────────────────────────
  'point de vue': {
    'scenic_spot',
    'observation_deck',
    'tourist_attraction',
    'viewpoint',
  },
  'foret': {'park', 'national_park', 'nature_preserve', 'natural_feature'},
  'lac': {'natural_feature', 'park', 'tourist_attraction'},
  'reserve naturelle': {
    'national_park',
    'state_park',
    'park',
    'nature_preserve',
    'tourist_attraction',
  },
  'jardin botanique': {
    'botanical_garden',
    'park',
    'tourist_attraction',
    'garden',
  },
  // ─── Plage / front de mer ──────────────────────────────────────
  'plage': {'beach', 'natural_feature', 'tourist_attraction'},
  'bord de mer': {
    'beach',
    'natural_feature',
    'park',
    'tourist_attraction',
    'scenic_spot',
  },
  'front de mer': {
    'beach',
    'natural_feature',
    'park',
    'tourist_attraction',
    'scenic_spot',
  },
  // ─── Randonnée / sentier ───────────────────────────────────────
  'sentier de randonnee': {
    'hiking_area',
    'park',
    'national_park',
    'state_park',
    'natural_feature',
    'tourist_attraction',
  },
  'balade nature': {
    'park',
    'national_park',
    'natural_feature',
    'tourist_attraction',
    'hiking_area',
  },
};

/// V8.12 (Lalith 2026-05-10 — Quality-1C dangerous query gate) —
/// queries où le LEXICAL match ne suffit PAS pour accepter un
/// candidat. Le strong type (cf. `_queryStrongTypes`) devient
/// mandatory.
///
/// Cas observé : query "patrimoine" matchait "Patrimoine et
/// Financement" (finance) en lexical → kept même si types pas
/// touristiques. Pour ces queries ambiguës, on force la classification
/// par type Google.
///
/// Idem que `_queryStrongTypes`, le match est par substring (la clé
/// est cherchée dans la query normalisée).
const Set<String> _strictNoLexicalQueries = <String>{
  'patrimoine culturel',
  // « patrimoine » seul est trop ambigu — supprimé en upstream
  // (cf. `interests_to_places_mapping.dart` Culture textQueries).
};

/// V8.12 — vrai si la query exige un strong type (lexical mismatch
/// rejette même avec mots dans le name).
bool _isStrictNoLexicalQuery(String textQuery) {
  final norm = _normalizeForMatch(textQuery);
  for (final marker in _strictNoLexicalQueries) {
    if (norm.contains(marker)) return true;
  }
  return false;
}

/// Retourne le set de types forts associés à la query (normalisée), ou
/// null si la query n'a pas d'override. Le matching se fait par substring
/// pour couvrir les variations (ex: "théâtre populaire" → matche "theatre").
Set<String>? _strongTypesForQuery(String textQuery) {
  final norm = _normalizeForMatch(textQuery);
  for (final entry in _queryStrongTypes.entries) {
    if (norm.contains(entry.key)) return entry.value;
  }
  return null;
}

/// Map query (mot-clé sémantique) → set d'intérêts pour lesquels cette
/// query est compatible. Utilisé pour filtrer les `additionalTextQueries`
/// du profil voyageur (Grand luxe, Couple, Backpack...) AVANT le merge
/// avec les queries de l'intérêt.
///
/// Sans ce filtre, "luxury spa" issue du profil "Grand luxe" se mergeait
/// avec l'intérêt Événements et ramenait des spas dans la pool événements.
/// Cas observé Lalith 2026-05-08 (test budget élevé).
///
/// Set vide `{}` = query JAMAIS appliquée (ex: "boutique hotel" — un
/// hôtel n'est pas une activité touristique). Query absente de la map =
/// permissive (compatible par défaut, comportement actuel).
const Map<String, Set<String>> _premiumQueryCompatibilities =
    <String, Set<String>>{
      // ─── Wellness / Spa ────────────────────────────────────────────────
      'luxury spa': {'Wellness', 'Esthétique'},
      'spa': {'Wellness', 'Esthétique'},
      'wellness': {'Wellness'},
      'massage': {'Wellness', 'Esthétique'},
      'hammam': {'Wellness', 'Esthétique'},

      // ─── Gastronomie ──────────────────────────────────────────────────
      'fine dining': {'Gastronomie', 'Bons plans'},
      'michelin': {'Gastronomie'},
      'gourmet restaurant': {'Gastronomie'},
      'gastronomic': {'Gastronomie'},
      'romantic restaurant': {'Gastronomie', 'Couple'},
      'business lunch': {'Gastronomie'},
      'street food': {'Gastronomie', 'Bons plans', 'Hors circuit'},
      'food hall': {'Gastronomie', 'Bons plans'},
      'cozy cafe': {'Gastronomie', 'Hors circuit'},
      'roadside diner': {'Gastronomie'},

      // ─── Bars / Nightlife ─────────────────────────────────────────────
      'rooftop bar': {'Nightlife', 'Événements', 'Gastronomie'},
      'cocktail bar': {'Nightlife', 'Événements'},
      'lounge bar': {'Nightlife'},
      'lively bar': {'Nightlife'},
      'local bar': {'Nightlife'},
      'hotel bar': {'Nightlife'},

      // ─── Hôtels / hébergement → JAMAIS comme activité ─────────────────
      'boutique hotel': <String>{},
      'luxury hotel': <String>{},
      'hostel': <String>{},

      // ─── Vues / nature ─────────────────────────────────────────────────
      'viewpoint': {'Nature', 'Spots populaires'},
      'scenic stop': {'Nature', 'Spots populaires'},
      'sunset spot': {'Nature', 'Couple', 'Spots populaires'},
      'quiet park': {'Nature', 'Wellness'},
      'photo spot': {'Spots populaires', 'Hors circuit'},

      // ─── Culture / visites guidées ────────────────────────────────────
      'guided tour': {'Culture', 'Spots populaires'},
      'free walking tour': {'Culture', 'Spots populaires', 'Bons plans'},

      // ─── Marché / shopping nocturne ───────────────────────────────────
      'night market': {'Spots populaires', 'Shopping', 'Bons plans'},

      // ─── Pro / coworking ──────────────────────────────────────────────
      'coworking': {'Voyage pro'},
    };

/// True si la query du profil voyageur est compatible avec l'intérêt
/// courant. Si la query n'est dans aucune entrée de la map, on retourne
/// true (default permissif — couvre les queries sans pollution connue).
bool isProfileQueryCompatibleWithInterest(String query, String interest) {
  final norm = _normalizeForMatch(query);
  for (final entry in _premiumQueryCompatibilities.entries) {
    if (norm.contains(entry.key)) {
      return entry.value.contains(interest);
    }
  }
  return true;
}

/// Filtre B + Logging C combinés pour les résultats d'un searchText.
/// - B : si la query a au moins 1 mot signif, exiger qu'au moins 1 de ces mots
///   soit dans le name du Place (substring match). Sinon → reject + log.
///   Si la query n'a aucun mot signif (query trop générique type "outlet" ou
///   très courte), on accepte tout (tolérant pour ne pas perdre de bons résultats).
/// - C : pour chaque résultat (accepté ou rejeté), log la paire
///   query → name → primary type → adresse → coords. Permet à Lalith
///   d'identifier les data-bugs Google (ex: Place "Parc du Château" Épinal
///   qui pointe en fait sur le Château d'Épinal voisin) pour les blacklister
///   manuellement via `_isExcludedPlace` ou pour signaler à Google Maps.
List<NearbyCandidate> _filterByQueryNameMatch(
  List<NearbyCandidate> results,
  String textQuery,
  String interest,
) {
  // Log d'entrée systématique : permet de voir si la fonction est appelée
  // mais avec 0 results (Places API n'a rien retourné pour cette query).
  debugPrint(
    '[places_first_match] >> filter q="$textQuery" interest=$interest '
    'results=${results.length}',
  );
  final queryWords = _significantWords(textQuery);
  // Query générique (catégorielle) : aucun nom propre dedans, juste des
  // mots qui décrivent une catégorie ("cheap eats", "free activities",
  // "fine dining"...). Le name-match strict rejetterait quasi tout, alors
  // qu'on s'appuie sur la sémantique d'établissement de Google Places.
  // → On garde tous les résultats, le scoring départage en aval.
  // Idem si queryWords vide (query trop courte/non analysable).
  if (queryWords.isEmpty || _isGenericCategoricalQuery(queryWords)) {
    final reason = queryWords.isEmpty ? 'générique' : 'catégorielle';
    for (final c in results) {
      final primaryType = c.types.isNotEmpty ? c.types.first : '?';
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ($reason) '
        '→ "${c.name}" type=$primaryType addr="${c.address}" '
        '@${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}',
      );
    }
    return results;
  }
  // Types Places "forts" qui dispensent du name-match pour cette query
  // (ex: "salle de spectacle" + primary=performing_arts_theater → accepté
  // même si le nom ne contient pas "salle" ou "spectacle").
  final strongTypes = _strongTypesForQuery(textQuery);
  // V8.12 (Quality-1C) — queries strictes : le lexical mismatch
  // rejette même avec mots dans le name. Force le strong type.
  // Couvre les queries ambiguës (« patrimoine culturel »).
  final isStrict = _isStrictNoLexicalQuery(textQuery);
  final kept = <NearbyCandidate>[];
  for (final c in results) {
    final nameNorm = _normalizeForMatch(c.name);
    final matched = queryWords.any((qw) => nameNorm.contains(qw));
    final primaryType = c.types.isNotEmpty ? c.types.first : '?';
    final matchedByStrongType =
        strongTypes != null && strongTypes.contains(primaryType);
    // Order : strong type prioritaire (categorical_query), puis lexical
    // (sauf si strict). Strict queries ne peuvent passer QUE par strong
    // type — un lexical mismatch ou un lexical-match-only sont rejetés.
    if (matchedByStrongType) {
      kept.add(c);
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✓ '
        'reason=strong_type ($primaryType) "${c.name}" addr="${c.address}" '
        '@${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}',
      );
    } else if (matched && !isStrict) {
      kept.add(c);
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✓ '
        'reason=lexical_match "${c.name}" type=$primaryType '
        'addr="${c.address}" '
        '@${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}',
      );
    } else if (matched && isStrict) {
      // Strict : lexical seul insuffisant. On rejette pour éviter
      // « Patrimoine et Financement » et autres faux positifs sur
      // queries ambiguës.
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✗ '
        'reason=strict_no_strong_type "${c.name}" type=$primaryType '
        '— lexical match mais query stricte exige type fort',
      );
    } else {
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✗ '
        'reason=lexical_mismatch "${c.name}" type=$primaryType '
        '— aucun mot (${queryWords.join(",")}) dans le name '
        'et pas de type fort',
      );
    }
  }
  return kept;
}

/// Types Places à exclure de la pool DÈS la récolte. Lieux jamais touristiques
/// par eux-mêmes : administrations, écoles, médical, agences, infrastructure
/// du quotidien. Filtre déterministe en amont — Gemini ne peut PAS les
/// proposer puisqu'ils n'arrivent jamais dans la pool.
///
/// Exception : si le lieu a aussi un type "touristique reconnu" (ex: hôtel
/// de ville historique = `local_government_office` + `historical_landmark`),
/// on garde — c'est un monument à visiter, pas un bureau.
const Set<String> _excludedPlaceTypes = <String>{
  // Géopolitique : "Epinal la ville" comme activité, c'est non. Places attache
  // parfois `locality`/`political` à des lieux trop génériques.
  'locality', 'political', 'country', 'administrative_area_level_1',
  'administrative_area_level_2', 'administrative_area_level_3',
  'sublocality', 'neighborhood',
  // Services personnels : salon de tatouage tagué `body_art_service`,
  // coiffeurs, esthétique, manucures... sont des services pratiques, pas
  // des attractions touristiques. Vu Nancy 26/04 STEVE ART TATTOO sélectionné
  // comme activité culturelle pour Senior.
  'body_art_service', 'hair_salon', 'beauty_salon', 'nail_salon',
  'barber_shop', 'tattoo_parlor', 'tattoo', 'massage', 'spa_and_beauty',
  'tanning_studio', 'piercing_shop',
  // Bars / clubs / nightlife / casinos : aucun intérêt courant ne les demande
  // sauf "Nightlife" (et même là, casinos rarement). Cas observé Bussang
  // 2026-04-28 : "Casino of Bussang" remontait pour profil Road-trip Randonnée
  // car classé `tourist_attraction` côté Google. Si un futur intérêt "Casino"
  // ou "Vegas-like" est ajouté, on créera une exception conditionnelle.
  'pub', 'irish_pub', 'sports_bar', 'wine_bar', 'cocktail_bar',
  'lounge_bar', 'night_club', 'hookah_bar', 'karaoke', 'casino',
  // Sports / stades : pas un intérêt général touristique. Stade Marcel Picot,
  // Stade de la Colombière etc. sortaient comme "Événements" alors que ce
  // sont juste des terrains.
  'stadium', 'sports_complex',
  // Administratif
  'local_government_office', 'city_hall', 'courthouse', 'embassy',
  'post_office', 'town_square_government',
  // Éducatif (sauf monument touristique reconnu — voir _touristicSignals)
  'school', 'primary_school', 'secondary_school', 'university',
  'language_school', 'tutoring_center', 'preschool',
  // Quotidien
  'gas_station', 'parking', 'supermarket', 'convenience_store',
  'liquor_store', 'bank', 'atm', 'currency_exchange',
  // Bibliothèques municipales / médiathèques (sauf signal touristique
  // — Bibliothèque Stanislas Nancy passe car aussi `historical_landmark`).
  'library',
  // Médical / soins
  'hospital', 'pharmacy', 'dentist', 'doctor', 'medical_office',
  'physiotherapist', 'veterinary_care', 'medical_lab',
  // Sécurité / urgence
  'police', 'fire_station',
  // Funéraire
  'cemetery', 'funeral_home',
  // Agences / logistique
  'travel_agency', 'real_estate_agency', 'insurance_agency',
  'storage', 'moving_company', 'car_rental', 'car_repair', 'car_dealer',
  'car_wash', 'auto_parts_store',
  // Hébergement (l'app gère ça via les docs perso, pas comme activité)
  'lodging', 'hotel', 'motel', 'guest_house', 'extended_stay_hotel',
  'campground', 'rv_park', 'resort_hotel', 'bed_and_breakfast',
};

/// Types qui légitiment un lieu comme touristique même s'il a aussi un type
/// blacklisté. Ex: l'Hôtel de Ville de Bruxelles est `local_government_office`
/// (admin) + `historical_landmark` (touristique reconnu) → on garde.
const Set<String> _touristicSignals = <String>{
  'tourist_attraction',
  'historical_landmark',
  'historical_place',
  'museum',
  'art_gallery',
  'monument',
};

/// Types pour lesquels le rejet est **HARD** sur le primary : aucun signal
/// touristique secondaire ne peut les sauver.
const Set<String> _hardExcludedPrimaryTypes = <String>{
  // Bars / clubs / nightlife
  'bar', 'pub', 'irish_pub', 'sports_bar', 'wine_bar',
  'cocktail_bar', 'lounge_bar', 'night_club', 'hookah_bar', 'karaoke',
  // Services personnels
  'body_art_service', 'tattoo', 'tattoo_parlor', 'hair_salon',
  'beauty_salon', 'nail_salon', 'barber_shop', 'massage',
  'spa_and_beauty', 'tanning_studio', 'piercing_shop',
  // Sports / stades
  'stadium', 'sports_complex', 'sports_club',
  // Hébergements en primary : un hostel/hotel ne doit pas être proposé
  // comme activité touristique, même s'il a un type secondaire `art_gallery`
  // ou `tourist_attraction`. Cas observé Lalith 2026-05-08 : "Chill Art
  // Hostel" pické à 16:30 alors que c'est un lieu de séjour. Les cas
  // particuliers (hostel-café, hostel-art space) sont reportés en V2.
  'hostel', 'lodging', 'hotel', 'motel', 'guest_house',
  'extended_stay_hotel', 'bed_and_breakfast', 'private_guest_room',
  'campground', 'rv_park', 'resort_hotel',
};

/// Types pour lesquels le rejet est **HARD sur N'IMPORTE QUEL type** (primary
/// ou secondaire). Pour les types qui polluent en secondaire (Lalith 26/04 :
/// STEVE ART TATTOO `art_gallery` primary + `body_art_service` secondaire,
/// Cosmic Park `amusement_center` primary + `karaoke` secondaire, Sport
/// Bowling Epinal `bowling_alley` primary + `karaoke` secondaire).
const Set<String> _hardExcludedAnyTypes = <String>{
  'body_art_service',
  'tattoo',
  'tattoo_parlor',
  'karaoke',
  'adult_entertainment',
  'sex_shop',
  'strip_club',
};

/// V8.4 (Lalith 2026-05-10 — Phase Quality-1A) — types **purement
/// services/commerce** sans dimension touristique possible. Rejet
/// hard sur le primary, sans exception (vs `_excludedPlaceTypes`
/// qui a une porte de sortie via `_touristicSignals`).
///
/// Observés dans les pools voyages réels : bijouteries, parfumeries,
/// pharmacies, salles de sport, chiropracteurs, électroménager,
/// quincailleries... Aucun voyageur ne tour a une `Loretta Farma &
/// Beauty` ou un `Studio Conectar` (gym).
const Set<String> _qualityHardBlocklistPrimaryTypes = <String>{
  // Médical / paramédical
  'chiropractor', 'foot_care', 'health', 'optician', 'skin_care_clinic',
  // Commerce service-y
  'jewelry_store', 'drugstore', 'cosmetics_store',
  'electronics_store', 'hardware_store', 'wholesaler',
  'furniture_store',
  // Sport personnel (pas un loisir touristique)
  'gym', 'fitness_center', 'sports_school', 'sports_coaching',
  // Bureaux / services
  'corporate_office', 'finance', 'accounting',
  'service', 'non_profit_organization',
  // Service de proximité (artisans / utilitaires)
  'plumber', 'electrician', 'laundry',
  // V8.5 — additions retour test Brésil :
  // - `manufacturer` : usine, ne se visite pas (sauf cas niche genre
  //   chocolaterie touristique qui auront `tourist_attraction`).
  // - `hair_care` : variante Google de hair_salon (déjà couvert dans
  //   `_excludedPlaceTypes`) qui passait à travers en primary.
  'manufacturer', 'hair_care',
};

/// V8.4 (Lalith 2026-05-10 — Phase Quality-1A) — types **commerciaux
/// génériques** rejetés sauf si pairé avec un signal touristique
/// (`_touristicSignals`). Couvre les cas où Google met `store` /
/// `clothing_store` en primary mais le lieu est aussi un monument /
/// market traditionnel / centre commercial historique.
///
/// Exemples valides : « Pernambucanas » primary `department_store`
/// sans signal touristique → rejet. Mais une concept-store dans un
/// monument ancien avec `tourist_attraction` secondaire → garde.
const Set<String> _qualitySoftBlocklistPrimaryTypes = <String>{
  'store',
  'clothing_store',
  'department_store',
  'shoe_store',
  'home_goods_store',
  'sporting_goods_store',
  'pet_store',
  'toy_store',
  'gift_shop', // sauf si tourist_attraction (cas placita Olvera Mexico)
  'food_store', 'grocery_store', 'asian_grocery_store', 'convenience_store',
  // Logements de fortune (ne devraient pas remonter mais Google parfois...)
  'private_guest_room',
};

/// V8.4 — types « strong travel-safe » qui bypass la règle
/// `reviews < 20` (rule 3). Un musée à 15 avis reste pertinent ; un
/// store à 15 avis est suspect. Liste fermée et conservatrice.
///
/// V8.12 (Lalith 2026-05-10 — Quality-1C) — théâtres / concert halls
/// / cinémas RÉINTÉGRÉS. La purge V8.6 (sortie de
/// `performing_arts_theater`, `concert_hall`, `philharmonic_hall`)
/// rejetait par effet de bord les vrais lieux culturels statiques
/// (Théâtre Mogador, Olympia, Grand Rex, Salle Pleyel...) qui ont
/// une valeur touristique propre — visites guidées, architecture,
/// patrimoine — même sans show daté. La règle weak event garde
/// `event_venue` / `convention_center` / `stadium` / `arena` /
/// `sports_complex` génériques.
const Set<String> _qualityTravelSafeTypes = <String>{
  'tourist_attraction',
  'historical_landmark', 'historical_place',
  'museum', 'art_museum', 'history_museum', 'science_museum',
  'monument', 'sculpture',
  'national_park', 'state_park', 'park', 'city_park',
  'beach',
  'viewpoint', 'scenic_spot',
  'aquarium', 'zoo',
  'art_gallery',
  'cultural_center',
  'cathedral', 'basilica',
  'castle', 'fort',
  'plaza',
  'observation_deck',
  'bridge',
  'waterfall', 'lighthouse',
  'amusement_park', 'theme_park',
  'market', 'farmers_market',
  // V8.12 — venues culturels statiques (réintégrés).
  'performing_arts_theater', 'concert_hall', 'philharmonic_hall',
  'live_music_venue', 'comedy_club', 'opera_house', 'movie_theater',
};

/// V8.4 — types religieux. Rule 5 : ne pass que si aussi
/// `_touristicSignals` OU reviews ≥ 200 (cathédrale connue, basilique
/// historique). Une église de quartier à 24 avis n'est pas une
/// activité touristique.
const Set<String> _qualityReligiousTypes = <String>{
  'church',
  'place_of_worship',
  'mosque',
  'synagogue',
  'buddhist_temple',
  'hindu_temple',
  'shinto_shrine',
};

/// V8.7 (Lalith 2026-05-10 — Quality-1A v4 final gate) — types
/// PRIMARY ou SECONDARY qui interdisent absolument la sélection comme
/// activité touristique, peu importe les autres signaux. Plus
/// exhaustif que `_qualityHardBlocklistPrimaryTypes` (gather-level)
/// car appliqué à TOUS les types du candidat (`c.types.any(...)`),
/// pas juste primary. Couvre les leaks observés sur run debug
/// Thaïlande 45j (Lalith) où des places passaient le gather mais
/// pollutaient quand même la sélection finale.
///
/// Inclut ce qui était dans `_qualityHardBlocklistPrimaryTypes` +
/// medical_clinic, painter, general_contractor, tire_shop,
/// auto_parts_store, car_dealer, car_repair, car_wash, car_rental,
/// gas_station, dentist, hospital, physiotherapist, atm, lawyer,
/// roofing_contractor, insurance_agency, real_estate_agency,
/// cannabis_store, weed_dispensary, bus_station, transit_station,
/// train_station, supermarket, hypermarket, grocery_store.
const Set<String> _qualityFinalBlockedTypes = <String>{
  // Médical / paramédical
  'medical_clinic', 'dentist', 'doctor', 'hospital', 'physiotherapist',
  'optician', 'chiropractor', 'foot_care', 'skin_care_clinic',
  'pharmacy', 'drugstore', 'health',
  // Auto / transport personnel
  'tire_shop', 'auto_parts_store', 'car_repair', 'car_dealer',
  'car_wash', 'car_rental', 'gas_station',
  // Construction / utilitaires
  'painter', 'general_contractor', 'electrician', 'plumber',
  'roofing_contractor', 'hardware_store', 'home_goods_store',
  'furniture_store',
  // Bureaux / finance / juridique
  'real_estate_agency', 'insurance_agency', 'finance', 'bank', 'atm',
  'accounting', 'lawyer', 'corporate_office', 'manufacturer',
  'wholesaler', 'service', 'non_profit_organization',
  // Commerce service-y
  'jewelry_store', 'electronics_store', 'cosmetics_store',
  // Sport personnel
  'gym', 'fitness_center', 'sports_school', 'sports_coaching',
  // Substances réglementées (UX trip planning ≠ recommander cannabis)
  'cannabis_store', 'weed_dispensary',
  // Transit (point de transit, pas une destination touristique)
  'bus_station', 'transit_station', 'train_station', 'subway_station',
  'taxi_stand', 'transit_depot',
  // Alimentaire de masse (pas une activité touristique)
  'supermarket', 'hypermarket', 'grocery_store', 'asian_grocery_store',
  'convenience_store', 'food_store',
  // Hair/beauty (déjà dans `_excludedPlaceTypes` mais on ré-affirme
  // en final gate pour les leaks via secondary types)
  'hair_care', 'hair_salon', 'beauty_salon', 'barber_shop', 'nail_salon',
  // Laverie etc.
  'laundry',
};

/// V8.7 — types de restauration / nourriture. Hors scope « visites
/// auto » (les restos sont gérés on-demand, cf. project_restaurant_ux).
/// Exception : un `market` (déjà touristique-safe) peut avoir ces
/// types en secondaire — voir `_isAllowedFinalVisitCandidate`.
const Set<String> _qualityFinalFoodTypes = <String>{
  'restaurant',
  'cafe',
  'bakery',
  'deli',
  'food_court',
  'meal_takeaway',
  'meal_delivery',
  'noodle_shop',
  'coffee_shop',
  'ice_cream_shop',
  'dessert_shop',
  'juice_shop',
  'tea_house',
  'food', // type générique Google
  // V8.28f2 (Lalith 2026-05-11) — additions pour cohérence avec
  // _mealPlaceTypes. Pâtisseries / boulangeries fines / confiseries /
  // chocolatiers sont alimentaires, pas des visites auto.
  'pastry_shop',
  'cake_shop',
  'confectionery',
  'donut_shop',
  'chocolate_shop',
  'candy_store',
  // `*_restaurant` (italian_restaurant, sushi_restaurant, etc.)
  // détecté par suffixe dans `_isAllowedFinalVisitCandidate`.
};

/// V8.7 — types qui légitiment un `market` même s'il est aussi
/// `food`/`grocery`. Les marchés alimentaires emblématiques sont des
/// activités touristiques (Smorgasburg, Borough Market, marchés
/// flottants). Sans ces types secondaires, un food market reste
/// food-only.
const Set<String> _qualityMarketTravelTypes = <String>{
  'tourist_attraction',
  'market',
  'farmers_market',
  'flea_market',
  // Note : `night_market`, `food_market`, `floating_market` ne sont
  // pas dans la v1 Google Places API standard mais on les liste pour
  // cohérence si un jour ils sortent.
  'night_market', 'food_market', 'floating_market',
};

/// V8.8 (Lalith 2026-05-10 — Quality-1A v5) — types « hébergement »
/// qui ne doivent JAMAIS apparaître dans une visite, peu importe la
/// position dans `c.types`. Couvre le cas observé : « Wellness Stay
/// & Hotel Sukhumvit 107 » primary=`spa`, secondary=`hotel,lodging`.
/// Le primary spa passait, le secondary hotel n'était pas vérifié.
const Set<String> _qualityFinalLodgingTypes = <String>{
  'hotel',
  'lodging',
  'motel',
  'guest_house',
  'resort_hotel',
  'hostel',
  'bed_and_breakfast',
  'extended_stay_hotel',
  'campground',
  'rv_park',
  'private_guest_room',
  'inn',
};

/// V8.8 (Lalith 2026-05-10 — Quality-1A v5) — patterns titre/adresse
/// qui rejettent un candidat même quand ses types Google sont
/// innocuous (shopping_mall, museum, point_of_interest, etc.). Cas
/// observés où Google ne donne pas le bon type :
///
/// - cannabis/weed/marijuana → primary `point_of_interest` ou `store`,
///   pas de `cannabis_store`. Détection par nom seule possible.
/// - « Benjamin Moore » → primary `painter`/`general_contractor`/
///   `home_goods_store`. Multi-types, peut leak via secondary.
/// - « OUTDOOR BOTANICA » (paint store) → primary `shopping_mall`,
///   passe les filtres types.
/// - « Michelin Car Service » → primary `tire_shop`, sometimes
///   `auto_parts_store`. Couvert par hard blocklist mais redondance
///   par nom OK.
/// - « Eye Plus Glasses » → primary `medical_clinic`. Idem couvert.
/// - « bus station » / « bến xe » → primary parfois juste
///   `point_of_interest` (pas tagué `bus_station`).
/// - « BITEC » / « Convention Center » → primary peut être `museum`
///   pour une exhibition à l'intérieur. Le contexte adresse vaut.
///
/// Regex case-insensitive, mots ancrés sur \b. Match sur titre ET
/// adresse (l'adresse capture les exhibitions à BITEC).
final RegExp _qualityFinalBlockedNamePattern = RegExp(
  r'\b('
  // Substances réglementées / cannabis
  r'weed|cannabis|marijuana|ganja|420|dispensary'
  r'|'
  // Brands non-touristiques observées
  r'benjamin\s+moore|outdoor\s+botanica'
  r'|'
  // Auto / mécanique
  r'tire\s+(shop|service)?|auto\s+parts?|car\s+service|car\s+wash'
  r'|michelin\s+car'
  r'|'
  // Optique / médical
  r'eye\s+plus\s+glasses'
  r'|'
  // Transit
  r'bus\s+station|bus\s+terminal|bến\s+xe'
  r'|'
  // Convention / hall (se retrouvent en adresse pour les exhibitions)
  r'bitec|convention\s+cent(re|er)'
  r')\b',
  caseSensitive: false,
);

/// V8.8 — seuil minimum d'avis même pour les types « strong travel-
/// safe ». Avant : un `market` à 1 avis passait le filtre via
/// `_qualityTravelSafeTypes`. Cas observé : « Chợ Chiều ★4.0 (1 avis) »
/// sélectionné en Shopping. 5 avis = signal minimal de réalité.
const int _qualityFinalMinReviewsTravelSafe = 5;

/// V8.9 (Lalith 2026-05-10 — Q1B low-confidence) — types « strong »
/// qui légitiment un candidat à reviews entre [10, 30[. Cas observés
/// `ป่าสงวนแห่งชาติ ★4.0 (10 avis)`, `Entrance to National Park ★4.1
/// (7 avis)` étaient acceptés via `_qualityTravelSafeTypes` (large
/// liste). Sous 30 avis on durcit : seules ces catégories de
/// destination iconique passent.
const Set<String> _qualityStrongTravelTypesStrict = <String>{
  'tourist_attraction',
  'historical_landmark',
  'historical_place',
  'museum',
  'art_museum',
  'history_museum',
  'national_park',
  'state_park',
  'beach',
  'scenic_spot',
  'viewpoint',
  'monument',
};

/// V8.9 (Lalith 2026-05-10 — Q1B volume cap) — seuil reviews qui
/// définit un « major » iconique (Statue of Liberty ~140k, Eiffel
/// Tower ~400k, etc.). Cap 2/jour pour éviter les journées sur-
/// chargées de must-see (qui demandent plus de temps + énergie).
const int _qualityMajorReviewsThreshold = 5000;
const int _qualityMaxMajorsPerDay = 2;

/// V8.9 — types qui qualifient un place comme « major touriste »
/// (avec reviews ≥ threshold). Mêmes types que la liste « strict »
/// pour low-confidence — un major DOIT être un type iconique, pas
/// un café avec 50000 avis.
const Set<String> _qualityMajorTouristTypes = <String>{
  'tourist_attraction',
  'historical_landmark',
  'historical_place',
  'museum',
  'art_museum',
  'history_museum',
  'monument',
  'national_park',
  'state_park',
  'beach',
  'castle',
  'cathedral',
  'basilica',
  'observation_deck',
  'amusement_park',
  'theme_park',
};

bool _isMajorTouristPlace(NearbyCandidate c) {
  final reviews = c.userRatingCount ?? 0;
  if (reviews < _qualityMajorReviewsThreshold) return false;
  return c.types.any(_qualityMajorTouristTypes.contains);
}

/// V8.10 (Lalith 2026-05-10 — Q1B fix orphan-day pour villes) —
/// noms de pays / régions où la destination est trop large pour
/// servir de centre de recherche utile. Pour ces destinations, si
/// l'utilisateur a des segments mais qu'un jour retombe sur
/// `source=destination`, on skip (cf. orphan-day rule).
///
/// Pour les autres destinations (= villes), on autorise le fallback
/// destination — un trip « Paris » 4 jours avec segments mal alignés
/// doit quand même fetcher la pool autour de Paris.
///
/// Liste FR + EN, lowercase. La normalisation accent-insensitive
/// est faite par `_normalizeBroadDestination` avant lookup.
const Set<String> _qualityBroadDestinationNames = <String>{
  // ─── Pays — Europe ──────────────────────────────────────────────────
  'france', 'italie', 'italy', 'espagne', 'spain', 'portugal',
  'allemagne', 'germany', 'royaume-uni', 'royaume uni', 'united kingdom',
  'uk', 'angleterre', 'england', 'ecosse', 'scotland', 'pays de galles',
  'wales', 'irlande', 'ireland', 'grece', 'greece', 'pays-bas',
  'pays bas', 'netherlands', 'hollande', 'belgique', 'belgium', 'suisse',
  'switzerland', 'autriche', 'austria', 'norvege', 'norway', 'suede',
  'sweden', 'danemark', 'denmark', 'finlande', 'finland', 'islande',
  'iceland', 'croatie', 'croatia', 'tchequie', 'czechia',
  'republique tcheque', 'czech republic', 'pologne', 'poland', 'hongrie',
  'hungary', 'russie', 'russia', 'roumanie', 'romania', 'bulgarie',
  'bulgaria', 'serbie', 'serbia', 'slovenie', 'slovenia', 'slovaquie',
  'slovakia', 'estonie', 'estonia', 'lettonie', 'latvia', 'lituanie',
  'lithuania', 'malte', 'malta', 'chypre', 'cyprus', 'luxembourg',
  // ─── Pays — Amériques ───────────────────────────────────────────────
  'etats-unis', 'etats unis', 'united states', 'usa', 'us', 'canada',
  'mexique', 'mexico', 'bresil', 'brazil', 'argentine', 'argentina',
  'chili', 'chile', 'perou', 'peru', 'colombie', 'colombia', 'equateur',
  'ecuador', 'bolivie', 'bolivia', 'venezuela', 'uruguay', 'paraguay',
  'cuba', 'jamaique', 'jamaica', 'republique dominicaine',
  'dominican republic', 'haiti', 'porto rico', 'puerto rico',
  'guatemala', 'panama', 'costa rica', 'honduras', 'salvador',
  'el salvador', 'nicaragua',
  // ─── Pays — Asie ────────────────────────────────────────────────────
  'thailande', 'thailand', 'vietnam', 'japon', 'japan', 'chine', 'china',
  'inde', 'india', 'indonesie', 'indonesia', 'malaisie', 'malaysia',
  'philippines', 'coree', 'korea', 'coree du sud', 'south korea',
  'taiwan', 'taïwan', 'singapour', 'singapore', 'cambodge', 'cambodia',
  'laos', 'birmanie', 'myanmar', 'sri lanka', 'nepal', 'bhoutan',
  'bhutan', 'maldives', 'pakistan', 'bangladesh', 'mongolie', 'mongolia',
  'kazakhstan', 'ouzbekistan', 'uzbekistan',
  // ─── Pays — Océanie ─────────────────────────────────────────────────
  'australie', 'australia', 'nouvelle-zelande', 'nouvelle zelande',
  'new zealand', 'fidji', 'fiji', 'polynesie francaise',
  'french polynesia', 'tahiti',
  // ─── Pays — Afrique ─────────────────────────────────────────────────
  'egypte', 'egypt', 'maroc', 'morocco', 'tunisie', 'tunisia', 'algerie',
  'algeria', 'libye', 'libya', 'afrique du sud', 'south africa', 'kenya',
  'tanzanie', 'tanzania', 'ethiopie', 'ethiopia', 'ouganda', 'uganda',
  'rwanda', 'madagascar', 'maurice', 'mauritius', 'reunion', 'la reunion',
  'senegal', 'cote d ivoire', 'cote d\'ivoire', 'ivory coast', 'ghana',
  'nigeria', 'cameroun', 'cameroon', 'zimbabwe', 'namibie', 'namibia',
  'botswana', 'mozambique',
  // ─── Pays — Moyen-Orient ────────────────────────────────────────────
  'turquie', 'turkey', 'emirats', 'emirats arabes unis',
  'united arab emirates', 'uae', 'dubai', // Dubai is borderline city/country
  'israel', 'jordanie', 'jordan', 'liban', 'lebanon', 'iran', 'irak',
  'iraq', 'arabie saoudite', 'saudi arabia', 'qatar', 'oman', 'koweit',
  'kuwait', 'bahrein', 'bahrain', 'yemen',
  // ─── Régions / continents ───────────────────────────────────────────
  'asie', 'asia', 'europe', 'amerique du nord', 'north america',
  'amerique du sud', 'south america', 'amerique latine', 'latin america',
  'afrique', 'africa', 'oceanie', 'oceania', 'moyen-orient', 'moyen orient',
  'middle east', 'asie du sud-est', 'asie du sud est', 'southeast asia',
  'south east asia', 'asie centrale', 'central asia', 'caraibes',
  'caribbean', 'mediterranee', 'mediterranean', 'balkans', 'scandinavie',
  'scandinavia', 'peninsule iberique', 'iberian peninsula', 'baltique',
  'baltics', 'baltic',
};

/// Normalise une destination pour le lookup `_qualityBroadDestinationNames` :
/// trim, lowercase, strip diacritiques (é→e, ï→i, ç→c, etc.).
/// Pure et déterministe.
String _normalizeBroadDestination(String s) {
  var n = s.toLowerCase().trim();
  const replacements = <String, String>{
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'î': 'i',
    'ï': 'i',
    'ô': 'o',
    'ö': 'o',
    'û': 'u',
    'ü': 'u',
    'ù': 'u',
    'ç': 'c',
    'ñ': 'n',
  };
  replacements.forEach((from, to) {
    n = n.replaceAll(from, to);
  });
  return n;
}

/// V8.10 — vrai si la destination est un pays / région large pour
/// laquelle le fallback `source=destination` est risqué (centre
/// géographique trop large = filler de mauvaise qualité). Faux pour
/// les villes (Paris, Tokyo, Bangkok, ...) où le fallback est
/// utilisable.
///
/// Heuristique : on prend le PREMIER token avant la virgule, normalisé.
/// « Paris, France » → first=paris → pas dans la liste → city → false.
/// « France » → first=france → broad → true.
/// « Bangkok, Thailand » → first=bangkok → city → false.
/// « Thailand » → broad → true.
@visibleForTesting
bool isBroadDestinationName(String? destination) {
  if (destination == null || destination.trim().isEmpty) {
    // Destination vide/inconnue = on ne peut pas affirmer city → safe
    // default = broad (préserve la protection anti-filler).
    return true;
  }
  final firstToken = destination.split(',').first;
  final norm = _normalizeBroadDestination(firstToken);
  return _qualityBroadDestinationNames.contains(norm);
}

/// V8.11 (Lalith 2026-05-10 — destination resolver V1) — résolution
/// du niveau de destination (ville vs pays/région) avec cache DB
/// `gemini_cache` action='destination_resolve'.
///
/// Architecture spec Lalith :
/// 1. Cache lookup par destination normalisée. Si hit → retourne.
/// 2. Cache miss → classification via `isBroadDestinationName` (liste
///    statique pays/régions). Save dans cache pour reuse cross-trip.
/// 3. V2 backlog : remplacer le miss-path par un vrai
///    `findPlaceFromText` Google Places qui renvoie les `types`
///    Geocoding (`country`/`administrative_area_level_1`/`locality`/...)
///    pour une classification authoritative. Aujourd'hui la liste
///    statique couvre les destinations communes (FR+EN ~150 noms).
///
/// Logs spec :
///   [places_center_resolve] destination="..." db=hit source=db level=...
///   [places_center_resolve] destination="..." db=miss action=heuristic_static
///   [places_center_resolve] destination="..." saved=true source=heuristic level=...
///
/// Retourne `'city'` ou `'broad'` (string pour debug-friendliness).
Future<String> resolveDestinationLevel({
  required String destination,
  required GeminiCacheService cache,
}) async {
  final normKey = _normalizeBroadDestination(destination.trim());
  if (normKey.isEmpty) {
    return 'broad';
  }
  // 1. Cache lookup.
  final cached = await cache.get('destination_resolve', normKey);
  if (cached != null && cached['level'] is String) {
    final level = cached['level'] as String;
    // ignore: avoid_print
    print(
      '[places_center_resolve] destination="$destination" '
      'db=hit source=db level=$level',
    );
    return level;
  }
  // 2. Cache miss → static heuristic (V2 = real Places lookup).
  // ignore: avoid_print
  print(
    '[places_center_resolve] destination="$destination" '
    'db=miss action=heuristic_static',
  );
  final isBroad = isBroadDestinationName(destination);
  final level = isBroad ? 'broad' : 'city';
  // 3. Save for reuse by future trips (best-effort, swallow errors).
  await cache.put('destination_resolve', normKey, {
    'level': level,
    'destination_norm': normKey,
    'classified_via': 'heuristic_static',
  });
  // ignore: avoid_print
  print(
    '[places_center_resolve] destination="$destination" '
    'saved=true source=heuristic level=$level',
  );
  return level;
}

/// V8.5 / V8.6 / V8.12 (Lalith 2026-05-10) — primaries d'« événement »
/// qui restent génériques sans une source d'événements datés
/// (PredictHQ Premium future). Rejetés sauf si pairés avec un signal
/// touristique fort (cf. `_qualityTravelSafeTypes`) ou volume d'avis
/// monument-tier (≥ 500 avis).
///
/// V8.12 (Quality-1C) — révisé après validation Paris : les vrais
/// lieux culturels statiques (Théâtre Mogador, Olympia, Grand Rex,
/// Théâtre du Châtelet, Salle Pleyel...) ne doivent plus être bloqués
/// uniquement parce qu'ils sont event_venue / performing_arts_theater.
/// Ils ont une vie touristique propre (visites guidées, architecture,
/// histoire) même sans show daté.
///
/// Restent rejetés (vraiment génériques sans date) :
///   convention_center, stadium, arena, sports_complex, event_venue,
///   wedding_venue, banquet_hall.
///
/// Réintégrés dans `_qualityTravelSafeTypes` :
///   performing_arts_theater, concert_hall, philharmonic_hall,
///   live_music_venue, comedy_club, opera_house, movie_theater
///   (cinémas iconiques Le Grand Rex / Le Champo).
const Set<String> _qualityWeakEventPrimaryTypes = <String>{
  'event_venue',
  'convention_center',
  'stadium',
  'arena',
  'sports_complex',
  'wedding_venue',
  'banquet_hall',
};

/// V8.4 — seuil de reviews qui « légitime » un religieux ou un
/// event_venue sans signal touristique secondaire.
///
/// V8.6 (Lalith 2026-05-10) — bumpé 200 → 500 sur retour test debug
/// Thaïlande. Constat : à 200 avis, des temples/églises de quartier
/// remontaient encore (ex: Igreja Adventista 298 avis, Festa de
/// San Gennaro 377 avis). À 500+, on cible les vraies étapes
/// touristiques (cathédrales connues, basiliques historiques,
/// monuments événementiels reconnus).
const int _qualityStrongLandmarkReviewsThreshold = 500;

/// V8.7 (Lalith 2026-05-10 — Quality-1A v4 final gate) — gate
/// strict appliqué AVANT chaque sélection dans
/// `selectVisitsDeterministic`. Complément du filtre gather-time
/// (`_isQualityRejected`) pour attraper les leaks observés sur run
/// debug Thaïlande : painter, medical_clinic, tire_shop,
/// noodle_shop sélectionné en Shopping, BITEC convention center,
/// supermarchés Makro, etc.
///
/// Différence avec `_isQualityRejected` :
/// - Vérifie `_qualityFinalBlockedTypes` sur **TOUS les types** (pas
///   juste primary). Couvre les places où un type rédhibitoire est
///   en secondaire (ex: Benjamin Moore primary=painter, secondary=
///   home_goods_store).
/// - Bloque les types food (`_qualityFinalFoodTypes` + suffixe
///   `_restaurant`) — cohérent avec la décision restos out-of-scope.
/// - Durcit les weak event venues : nécessite signal touristique fort
///   ET reviews ≥ 500 (avant : OR).
/// - Rejette point_of_interest seul (sans autre type qualifiant).
///
/// Retourne :
///   - 'blocked_type' : type bloqué dans n'importe quelle position.
///   - 'restaurant_out_of_scope' : type food sans contexte market.
///   - 'weak_event' : event venue sans signal touristique fort + reviews.
///   - 'low_reviews' : reviews < 10 et type non travel-safe.
///   - 'low_rating' : rating < 4.0 ou null.
///   - 'high_rating_few_reviews' : rating ≥ 4.5 mais reviews < 10.
///   - 'generic_poi' : point_of_interest seul.
///   - null si OK.
/// V8.28b1.3 (Lalith 2026-05-11) — true si le candidat est éligible à
/// la dédup trip-level pour les lieux iconiques (en plus de la dédup
/// per-cluster existante). Couvre les cas où Google retourne le même
/// placeId via 2 chemins de recherche différents (blueprint fetch
/// + per-day gather, fan-out d'ancre, etc.) et où le candidat se
/// retrouve dans des sub-clusters distincts → la dédup
/// `selectedDedupKeysBySegment` per-cluster ne propage pas
/// cross-cluster, et `useCountAcrossTrip` (name-based) rate quand
/// Google renvoie le même lieu avec un libellé légèrement différent.
///
/// Eligibilité (V8.28b1.4 — ordre revu, markers en premier) :
///   - marker `_BlueprintMustSee` / `_BlueprintExperience` : source
///     de vérité éditoriale Lunao. Couvre les lieux que Google
///     retourne sans type « canonique » tourisme (Buddha Tooth
///     Relic Temple = `buddhist_temple` SANS `tourist_attraction`,
///     Sentosa Island = `political`/`locality` selon contexte).
///     Ces lieux ratent isIconicTourist mais sont iconiques au
///     sens produit, donc dédupliqués trip-level.
///   - marker `_MetroAnchor` (V8.28d) : enrichissement contrôlé via
///     ancres tourisme curées — toutes éligibles à la dédup trip.
///   - isIconicMuseum  : reviews ≥ 200 ET type museum/art_museum/
///     art_gallery (cohérent avec la rule iconic cap existante).
///   - isIconicTourist : reviews ≥ 500 ET type tourist_attraction/
///     historical_landmark/monument/landmark.
///   - Exception nominale Singapour : `effectiveMetro.cityKey ==
///     'singapore'` ET le nom contient `orchard road`. Conservé en
///     filet de sécurité si l'utilisateur n'utilise pas le blueprint.
///
/// Préserve V8.16 (per-segment dedup) en n'incluant PAS les
/// candidats non-iconiques : Bangkok ne bloque pas un petit lieu
/// répété à Koh Samet, Hanoi ne bloque pas Hoi An, etc.
bool isCandidateTripLevelDedupEligible(
  NearbyCandidate c,
  List<String> matchedInterests,
  MetroProfile? effectiveMetro,
) => _isTripLevelDedupEligible(c, matchedInterests, effectiveMetro);

/// V8.28b1.3 (Lalith 2026-05-11) — caps de transition slot picker
/// pour les jours en mode fallback (sans Day Builder pack) sur
/// mégalopole. Stricter que V8.21 default :
///   - 5 km max single hop (au lieu de 10 km)
///   - 0 long hop autorisé (au lieu de 1)
/// Évite zigzags type Chinatown/CBD → Sentosa → Orchard Road
/// observé Singapour 22/05 (Sentosa↔Orchard = 6.1 km).
///
/// Hors mégalopole ou en mode pack curé → caps V8.21 default.
({double maxSingleTransitionKm, int maxLongTransitionsPerDay})
fallbackTransitionCapsForDay({
  required MetroProfile? clusterMetroProfile,
  required bool hasDayPack,
}) {
  final isMegaCityFallback =
      (clusterMetroProfile?.isMegaCity ?? false) && !hasDayPack;
  return (
    maxSingleTransitionKm: isMegaCityFallback ? 5.0 : 10.0,
    maxLongTransitionsPerDay: isMegaCityFallback ? 0 : 1,
  );
}

bool _isTripLevelDedupEligible(
  NearbyCandidate c,
  List<String> matchedInterests,
  MetroProfile? effectiveMetro,
) {
  // V8.28b1.4 (Lalith 2026-05-11) — markers curated en premier.
  // Root cause du bug V8.28b1.3 : Buddha Tooth Relic Temple
  // (Singapore blueprint mustSee) sortait avec primary type
  // `buddhist_temple` SANS `tourist_attraction` ni `historical_
  // landmark` → ratait isIconicTourist → ne s'ajoutait pas au set
  // iconicSelectedAcrossTrip → re-pick autorisé sur jour suivant.
  // Idem Sentosa Island (`political`/`locality` selon contexte
  // Google). Tous ces lieux sont CURATED dans le blueprint Lunao :
  // le marker `_BlueprintMustSee` est la source de vérité éditoriale.
  if (matchedInterests.contains(blueprintMustSeeMarker)) return true;
  if (matchedInterests.contains(blueprintExperienceMarker)) return true;
  if (matchedInterests.contains(metroAnchorMarker)) return true;
  final reviewN = c.userRatingCount ?? 0;
  final isIconicMuseum =
      reviewN >= 200 &&
      (c.types.contains('museum') ||
          c.types.contains('art_museum') ||
          c.types.contains('art_gallery'));
  final isIconicTourist =
      reviewN >= 500 &&
      (c.types.contains('tourist_attraction') ||
          c.types.contains('historical_landmark') ||
          c.types.contains('monument') ||
          c.types.contains('landmark'));
  if (isIconicMuseum || isIconicTourist) return true;
  if (effectiveMetro?.cityKey == 'singapore') {
    final n = c.name.toLowerCase();
    if (n.contains('orchard road')) return true;
  }
  return false;
}

/// V8.28b1 (Lalith 2026-05-11) — true si l'adresse du candidat match
/// l'un des patterns interdits (substring case-insensitive). Utilisé
/// pour le filter `out_of_country` quand le cluster MetroProfile
/// déclare `blockedAddressPatterns` (cas Singapour : adresse contient
/// `Malaysia` / `Johor` / `JBCC` / `KSL City` / `KOMTAR` →
/// candidat rejeté).
///
/// Retourne false si `blockedPatterns` est vide ou si l'address est
/// null/empty (rien à matcher, candidat passe).
bool isCandidateAddressBlocked(
  NearbyCandidate c,
  List<String> blockedPatterns,
) {
  if (blockedPatterns.isEmpty) return false;
  final addr = c.address;
  if (addr == null || addr.isEmpty) return false;
  final addrLower = addr.toLowerCase();
  for (final pattern in blockedPatterns) {
    if (addrLower.contains(pattern.toLowerCase())) return true;
  }
  return false;
}

/// V8.28b1 — true si le nom du candidat match l'un des patterns
/// interdits visit-slot (substring case-insensitive). Utilisé pour
/// rejeter les hawker centres Singapour des visit-slots (Lau Pa Sat,
/// Maxwell Food Centre, Hong Lim Market & Food Centre).
///
/// Le marker curated NE sauve PAS le candidat (contrairement à
/// `isRestaurantDisguisedForVisit`). Les hawker centres restent
/// dispo pour l'insertion repas (qui utilise un autre code path).
bool isCandidateNameVisitBlocked(
  NearbyCandidate c,
  List<String> blockedNamePatterns,
) {
  if (blockedNamePatterns.isEmpty) return false;
  final nameLower = c.name.toLowerCase();
  for (final pattern in blockedNamePatterns) {
    if (nameLower.contains(pattern.toLowerCase())) return true;
  }
  return false;
}

/// V8.28f2 (Lalith 2026-05-11) — détecte les restaurants/cafés/
/// boulangeries/pâtisseries déguisés en POIs touristiques. Bug
/// observé Florence : Antica Trattoria da Tito dal 1913 avec
/// types=[historical_landmark, night_club, italian_restaurant]
/// passait à travers `_isAllowedFinalVisitCandidate` car la
/// détection food n'examinait que `primary=historical_landmark`.
///
/// Règle : retourne true si UN DES types de `c.types` est food
/// (incluant le suffixe `*_restaurant`).
/// Exception 1 — marché emblématique : un type travel-safe (`tourist_
/// attraction` / `market` / `farmers_market` / `flea_market` /
/// `food_market`) co-tagué neutralise. Couvre Borough Market,
/// Smorgasburg, Pak Khlong Talat.
/// Exception 2 — marker curated : `_BlueprintMustSee` / `_BlueprintExperience`
/// / `_MetroAnchor`. Un lieu curé peut porter un type secondaire
/// food (Khaosan Road avec `bar`, food court must-see), on garde.
bool isRestaurantDisguisedForVisit(
  NearbyCandidate c,
  List<String> matchedInterests,
) {
  if (matchedInterests.contains(blueprintMustSeeMarker)) return false;
  if (matchedInterests.contains(blueprintExperienceMarker)) return false;
  if (matchedInterests.contains(metroAnchorMarker)) return false;
  final hasFoodTypeAnywhere = c.types.any(
    (t) => _qualityFinalFoodTypes.contains(t) || t.endsWith('_restaurant'),
  );
  if (!hasFoodTypeAnywhere) return false;
  final hasMarketContext = c.types.any(_qualityMarketTravelTypes.contains);
  if (hasMarketContext) return false;
  return true;
}

String? _isAllowedFinalVisitCandidate(
  NearbyCandidate c, {
  required Set<String> tripInterests,

  /// V8.28f2 — markers du candidat (`_BlueprintMustSee`,
  /// `_BlueprintExperience`, `_MetroAnchor`). Sert d'exception au
  /// rejet `restaurant_out_of_scope` quand un lieu curé porte un
  /// type secondaire food (ex: Khaosan Road avec `bar`, food market
  /// emblématique avec `food_court`).
  List<String> matchedInterests = const [],

  /// V8.28b1 — patterns d'adresses (case-insensitive substring) qui
  /// rejettent le candidat avec reason `out_of_country`. Vient du
  /// MetroProfile du cluster (cas Singapour ↔ Johor).
  List<String> blockedAddressPatterns = const [],

  /// V8.28b1 — patterns de noms (case-insensitive substring) qui
  /// rejettent le candidat des visit-slots avec reason
  /// `restaurant_out_of_scope`. Couvre les hawker centres
  /// curated-mais-non-visite (Lau Pa Sat, Maxwell, Hong Lim).
  /// Le marker curated NE sauve PAS le candidat ici.
  List<String> visitBlockedNamePatterns = const [],
}) {
  if (c.types.isEmpty) return 'generic_poi';
  final primary = c.types.first;
  final reviews = c.userRatingCount ?? 0;
  final rating = c.rating ?? 0;

  // V8.28b1 (Lalith 2026-05-11) — out-of-country filter. Cas
  // observé Singapour : cluster ~(1.43,103.78) rayon ~20 km tirait
  // Johor Bahru. MetroProfile Singapour déclare
  // `blockedAddressPatterns`.
  if (isCandidateAddressBlocked(c, blockedAddressPatterns)) {
    return 'out_of_country';
  }

  // V8.28b1 — hawker centres Singapour : Lau Pa Sat / Maxwell /
  // Hong Lim sont curated (blueprint experience) mais ne doivent
  // pas être visit-slot. Reuse reason `restaurant_out_of_scope`.
  if (isCandidateNameVisitBlocked(c, visitBlockedNamePatterns)) {
    return 'restaurant_out_of_scope';
  }

  // V8.9 (Lalith 2026-05-10 — Q1B) — wellness/nightlife mismatch :
  // un place avec primary spa/public_bath/massage/etc. ne doit
  // apparaître que si Wellness ∈ tripInterests. Idem pour
  // bar/pub/brewpub vs Nightlife. Sinon on tagge à tort en Activité
  // (cas Dorum Onsen&Sauna observé sur run debug Thaïlande v5).
  if (_wellnessPrimaryTypes.contains(primary) &&
      !tripInterests.contains('Wellness')) {
    return 'wellness_not_in_interests';
  }
  if (_strictBarPrimaryTypes.contains(primary) &&
      !tripInterests.contains('Nightlife')) {
    return 'nightlife_not_in_interests';
  }

  // V8.8 — Lodging block : si HOTEL/LODGING/MOTEL/HOSTEL/etc. apparaît
  // n'importe où dans `c.types`, on rejette. Couvre « Wellness Stay
  // & Hotel » (primary=spa, secondary=hotel,lodging) qui leakait via
  // le primary spa au gather.
  if (c.types.any(_qualityFinalLodgingTypes.contains)) {
    return 'blocked_lodging';
  }

  // V8.8 — Blocklist par nom et adresse (regex). Couvre les cas où
  // les types Google sont innocuous mais le titre/adresse révèle un
  // lieu non-touristique (cannabis, paint store, mécanique, BITEC...).
  // Match sur name OU address pour attraper « Space Journey
  // Exhibition » dont l'adresse commence par « BITEC Bang Na ».
  if (_qualityFinalBlockedNamePattern.hasMatch(c.name)) {
    return 'blocked_title';
  }
  final addr = c.address;
  if (addr != null && _qualityFinalBlockedNamePattern.hasMatch(addr)) {
    return 'blocked_address';
  }

  // Hard blocked sur TOUS les types (primary OR secondary).
  if (c.types.any(_qualityFinalBlockedTypes.contains)) {
    return 'blocked_type';
  }

  // V8.28f2 (Lalith 2026-05-11) — restaurants déguisés.
  // Cas observé Florence : Antica Trattoria da Tito dal 1913
  // sortait à 09:30 comme « Culture » car types=[historical_landmark,
  // night_club, italian_restaurant] et le primary=historical_landmark
  // passait. `isRestaurantDisguisedForVisit` check ANY position +
  // exception curated (blueprint/metroAnchor) + exception market.
  if (isRestaurantDisguisedForVisit(c, matchedInterests)) {
    return 'restaurant_out_of_scope';
  }

  // Rating < 4.0 toujours rejeté.
  if (rating < 4.0) {
    return 'low_rating';
  }

  // Rating ≥ 4.5 + reviews < 10 = bruit (anti review-stuffing).
  if (rating >= 4.5 && reviews < 10) {
    return 'high_rating_few_reviews';
  }

  // V8.9 (Lalith 2026-05-10 — Q1B) — low-confidence durci.
  // Cas observés à corriger : `ป่าสงวนแห่งชาติ ★4.0 (10 avis)`,
  // `Entrance to National Park ★4.1 (7 avis)`. Acceptables
  // techniquement mais signal trop faible.
  //
  // Nouvelle règle :
  //   - reviews < 30 → reject SAUF si type dans `_qualityStrongTravelTypesStrict`
  //     (liste réduite : tourist_attraction, museum, art_museum,
  //     historical_landmark, beach, national_park, scenic_spot, etc.).
  //   - Même les strong types nécessitent ≥ 5 avis (le seuil minimal
  //     v5 reste, anti `Chợ Chiều ★4.0 (1 avis)`).
  if (reviews < _qualityFinalMinReviewsTravelSafe) {
    return 'low_reviews';
  }
  if (reviews < 30) {
    final hasStrongTravel = c.types.any(
      _qualityStrongTravelTypesStrict.contains,
    );
    if (!hasStrongTravel) {
      return 'low_reviews';
    }
  }

  // Weak event venues (event_venue, convention_center, stadium, etc.)
  // doivent avoir UN signal cultural fort ET ≥ 500 avis. Plus strict
  // que `_isQualityRejected` qui acceptait OR.
  if (_qualityWeakEventPrimaryTypes.contains(primary)) {
    final hasStrongCulturalSignal = c.types.any(
      (t) =>
          t == 'tourist_attraction' ||
          t == 'historical_landmark' ||
          t == 'historical_place' ||
          t == 'museum' ||
          t == 'art_museum' ||
          t == 'history_museum' ||
          t == 'cultural_center' ||
          t == 'live_music_venue' ||
          t == 'monument',
    );
    if (!hasStrongCulturalSignal ||
        reviews < _qualityStrongLandmarkReviewsThreshold) {
      return 'weak_event';
    }
  }

  // Generic POI : `point_of_interest` seul ou avec types trop
  // génériques (`establishment`, `place_of_worship` sans signal
  // touristique). Couvre les data-bugs Google.
  if (c.types.length == 1 && primary == 'point_of_interest') {
    return 'generic_poi';
  }

  return null;
}

/// V8.4 — règle de qualité voyage. Retourne le nom du motif de rejet
/// (string court, machine-friendly pour les logs `[places_quality_*]`)
/// ou null si le candidat passe.
///
/// Appliqué APRÈS `_isExcludedPlace` (qui couvre les exclusions
/// historiques). Filtre supplémentaire centré sur la pertinence
/// **touristique** d'un lieu : éviter pharmacies, jewelry stores,
/// salles de sport, lieux à 1-9 avis, etc., qui passent les autres
/// filtres mais polluent les pools observés sur trips réels (Brésil,
/// USA, Floride 2026-05-10).
String? _isQualityRejected(NearbyCandidate c) {
  if (c.types.isEmpty) return null;
  final primary = c.types.first;
  final reviews = c.userRatingCount ?? 0;
  final rating = c.rating ?? 0;

  // Rule 1a — hard blocklist primary, pas d'exception.
  if (_qualityHardBlocklistPrimaryTypes.contains(primary)) {
    return 'hard_blocklist_primary';
  }

  // Rule 1b — soft blocklist : primary commercial générique sans
  // signal touristique sur un autre type → rejet.
  if (_qualitySoftBlocklistPrimaryTypes.contains(primary) &&
      !c.types.any(_touristicSignals.contains)) {
    return 'soft_blocklist_no_touristic_signal';
  }

  // Rule 2 — high rating + low reviews = bruit (★5.0 1-5 avis = poubelle).
  if (rating >= 4.5 && reviews < 10) {
    return 'high_rating_too_few_reviews';
  }

  // Rule 3 — < 20 reviews sauf si type strongly travel-safe.
  if (reviews < 20) {
    final hasTravelSafe = c.types.any(_qualityTravelSafeTypes.contains);
    if (!hasTravelSafe) {
      return 'low_reviews_not_travel_safe';
    }
  }

  // Rule 5 — religieux : doit avoir signal touristique OU ≥ 200 avis.
  if (c.types.any(_qualityReligiousTypes.contains)) {
    final hasTourSignal = c.types.any(_touristicSignals.contains);
    if (!hasTourSignal && reviews < _qualityStrongLandmarkReviewsThreshold) {
      return 'weak_religious_no_touristic_signal';
    }
  }

  // Rule 4 — primaries « événement » (event_venue, movie_theater,
  // concert_hall) sans signal touristique fort → rejet. Sans source
  // événements datés (PredictHQ Premium future, cf.
  // project_predicthq_premium), ces venues sont juste des bâtiments.
  // On garde uniquement ceux qui sont aussi des lieux culturels
  // reconnus (cf. `_qualityTravelSafeTypes`, qui contient déjà
  // `cultural_center`, `performing_arts_theater`, `philharmonic_hall`,
  // `tourist_attraction`, etc.) OU qui ont un volume d'avis « monument-
  // tier » (`_qualityStrongLandmarkReviewsThreshold` = 200).
  //
  // V8.5 (Lalith 2026-05-10) — `movie_theater` et `concert_hall`
  // étendent la rule ; un cinéma de quartier ou une salle de concert
  // sans signal touristique = pas une activité touristique.
  if (_qualityWeakEventPrimaryTypes.contains(primary)) {
    final hasStrongSignal = c.types.any(_qualityTravelSafeTypes.contains);
    if (!hasStrongSignal && reviews < _qualityStrongLandmarkReviewsThreshold) {
      return 'weak_event_venue_no_dated_source';
    }
  }

  return null;
}

/// Vrai si le lieu doit être exclu de la pool. 3 niveaux :
/// - Hard ANY : N'IMPORTE QUEL type matche `_hardExcludedAnyTypes` → rejet
///   (body_art_service, karaoke en secondaire ne sont pas sauvés).
/// - Hard PRIMARY : primary dans `_hardExcludedPrimaryTypes` → rejet absolu
///   (bars, salons, stades).
/// - Soft : primary dans `_excludedPlaceTypes` MAIS aucun signal touristique
///   secondaire → exclure (mairie sans signal historique = bureau, mairie
///   avec `historical_landmark` secondaire = monument, on garde).
/// Blacklist statique de placeIds connus pour avoir des données erronées chez
/// Google (mismatch name/coords/types confirmé manuellement). À enrichir
/// quand on identifie des nouveaux cas via les logs `[places_first_pick]`.
const Set<String> _blacklistedPlaceIds = <String>{
  // "Parc du château" Épinal — 1 seul placeId chez Google qui mélange le
  // Château d'Épinal (26 rue Saint-Michel, primary type=castle) et le Parc
  // du Château voisin. Le name affiché est "Parc du château" mais les coords
  // pointent sur le château. Identifié 2026-04-27 via logs places_first_pick.
  'ChIJD9gWgomgk0cRCSmE3pSQ7nc',
};

/// Mots-clés "espace vert" qui suggèrent un parc/jardin dans le name.
/// Utilisés pour l'heuristique de cohérence name vs primary type.
const Set<String> _greenspaceNameKeywords = <String>{
  'parc',
  'park',
  'jardin',
  'garden',
  'square',
};

/// Primary types compatibles avec un nom contenant "parc/park/jardin/garden".
/// Si le name suggère un espace vert mais que le primary est hors de cette
/// liste, c'est probablement un mismatch data Google.
const Set<String> _greenspacePrimaryTypes = <String>{
  'park',
  'city_park',
  'national_park',
  'state_park',
  'garden',
  'botanical_garden',
  'plaza',
  'wildlife_park',
  'amusement_park',
  'tourist_attraction',
  'point_of_interest',
  'natural_feature',
};

/// Mots dans le nom qui signalent une excursion organisée (typiquement une
/// agence touristique avec un point d'embarquement). Ces "lieux" sont en
/// fait des journées entières hors de la ville — ils ne doivent pas être
/// insérés dans un créneau local court (ex: 16:30 à Marrakech alors que
/// "Setti Fadma Ourika Valley & 7 Cascades" implique 6-8h aller-retour).
///
/// Bug observé Lalith 2026-05-08 : Setti Fadma planifié à 16:30 entre 2
/// activités du centre-ville Marrakech.
const Set<String> _excursionNameKeywords = <String>{
  'valley',
  'vallée',
  'cascades',
  'waterfall',
  'cascade',
  'desert tour',
  'sahara',
  'sahara tour',
  'merzouga',
  'erg chebbi',
  'day trip',
  'daytrip',
  'day-trip',
  'excursion',
  'guided tour',
  'shore excursion',
  'atlas mountains',
  'atlas tour',
  'haut atlas',
  '4x4 tour',
  'quad tour',
  'quad bike',
  'road trip',
};

/// Vrai si le candidat ressemble à une excursion organisée (journée entière
/// hors ville). Détecté via :
/// - primary ou secondary type = `tour_agency`
/// - ou nom contenant un mot signal (cf. [_excursionNameKeywords])
///
/// Les excursions ne sont pas des visites locales — on les exclut du
/// planning automatique. À traiter plus tard via un mode "excursion
/// demi-journée/journée" dédié.
bool _isExcursionLike(NearbyCandidate c) {
  if (c.types.contains('tour_agency')) return true;
  final nameNorm = _normalizeForMatch(c.name);
  for (final kw in _excursionNameKeywords) {
    final kwNorm = _normalizeForMatch(kw);
    if (nameNorm.contains(kwNorm)) return true;
  }
  return false;
}

/// Noms de Places trop génériques pour être de vrais POIs : Google Places
/// expose parfois des entrées dont le `displayName` est juste "Ville",
/// "City", "Medina" — généralement des points administratifs ou des
/// pages génériques sans intérêt touristique. Test Lalith 2026-05-08
/// (Senior Essaouira) : pick "Ville" en Culture, douteux.
///
/// Match EXACT (après `_normalizeForMatch` qui strip diacritiques + lower-
/// case). On ne filtre PAS "Médina de Marrakech", "Old City Tour Co",
/// "Marrakech Medina Tours" — seulement le nom littéral.
///
/// Hard reject (toujours filtrés) :
const Set<String> _genericPlaceNamesHardReject = <String>{
  'ville',
  'city',
  'centre ville',
  'centre-ville',
  'downtown',
  'la ville',
  'the city',
};

/// Soft reject — filtrés UNIQUEMENT si le primary type est faible
/// (tourist_attraction générique, neighborhood…). Si Google les classe
/// `historical_landmark`/`museum`/`monument`, on les garde car probable
/// que le Place pointe sur un vrai monument/site historique.
const Set<String> _genericPlaceNamesSoftReject = <String>{
  'medina',
  'old city',
  'old town',
  'new city',
};

/// Types qui sauvent un soft-reject : si le primary est dans cette set,
/// on garde même quand le name est `medina`/`old city`/etc.
const Set<String> _strongTypesSavingGenericName = <String>{
  'historical_landmark',
  'historical_place',
  'museum',
  'art_gallery',
  'monument',
};

bool _isGenericPlaceName(NearbyCandidate c) {
  final norm = _normalizeForMatch(c.name);
  if (_genericPlaceNamesHardReject.contains(norm)) {
    debugPrint(
      '[places_first_excluded] generic_place_name (hard) : "${c.name}" '
      'placeId=${c.placeId} types=${c.types.take(3).join(",")}',
    );
    return true;
  }
  if (_genericPlaceNamesSoftReject.contains(norm)) {
    final primary = c.types.isNotEmpty ? c.types.first : '';
    if (_strongTypesSavingGenericName.contains(primary)) return false;
    debugPrint(
      '[places_first_excluded] generic_place_name (soft) : "${c.name}" '
      'primary=$primary placeId=${c.placeId} '
      '— pas de type fort qui le sauve',
    );
    return true;
  }
  return false;
}

bool _isExcludedPlace(NearbyCandidate c) {
  if (c.types.isEmpty) return false;
  if (_blacklistedPlaceIds.contains(c.placeId)) return true;
  if (c.types.any(_hardExcludedAnyTypes.contains)) return true;
  if (_isGenericPlaceName(c)) return true;
  final primary = c.types.first;
  if (_hardExcludedPrimaryTypes.contains(primary)) return true;
  // Excursions organisées : exclues du planning local. Le primary peut
  // être `tourist_attraction` (signal touristique fort), donc on filtre
  // AVANT de checker `_excludedPlaceTypes` pour ne pas être sauvé par
  // ce signal.
  if (_isExcursionLike(c)) {
    debugPrint(
      '[places_first_excluded] excursion détectée : "${c.name}" '
      'types=${c.types.take(3).join(",")} placeId=${c.placeId} — '
      'exclu du planning local (à traiter en mode excursion future)',
    );
    return true;
  }
  if (_excludedPlaceTypes.contains(primary)) {
    return !c.types.any(_touristicSignals.contains);
  }
  // Heuristique de cohérence : si le name suggère un espace vert (parc/jardin)
  // mais que le primary type ne l'est pas (ex: castle, church, restaurant),
  // c'est très probablement un mismatch Google. Catégorie ouverte mais on
  // la garde tolérante via `_greenspacePrimaryTypes` qui inclut tourist_attraction
  // et point_of_interest pour ne pas rejeter des cas légitimes.
  final nameNorm = _normalizeForMatch(c.name);
  final hasGreenspaceWord = _greenspaceNameKeywords.any(
    (kw) => RegExp('\\b$kw\\b').hasMatch(nameNorm),
  );
  if (hasGreenspaceWord && !_greenspacePrimaryTypes.contains(primary)) {
    debugPrint(
      '[places_first_excluded] mismatch name/primary : "${c.name}" '
      'primary=$primary placeId=${c.placeId} — exclu (probable data-bug Google)',
    );
    return true;
  }
  return false;
}

/// Pool de candidats Places pour UN jour du voyage.
/// Une journée = un centre géographique (lat/lng calculé via day_center_service)
/// + une liste de candidats par intérêt voyageur.
///
/// La même `NearbyCandidate` peut apparaître dans plusieurs intérêts (ex: la
/// Place Stanislas matche à la fois "Culture" et "Spots populaires"). Le caller
/// est libre de dédupliquer pour la sélection finale.
class DayCandidates {
  final DateTime day;
  final DayCenter center;

  /// Clé = libellé d'intérêt voyageur ("Culture", "Gastronomie", ...).
  /// Valeur = candidats Places retenus pour cet intérêt après filtres.
  final Map<String, List<NearbyCandidate>> byInterest;

  const DayCandidates({
    required this.day,
    required this.center,
    required this.byInterest,
  });

  /// Tous les candidats du jour, dédupliqués par place_id, conservant pour
  /// chaque candidat la liste des intérêts qui l'ont matché (utile pour le
  /// prompt Gemini : "ce lieu peut servir Gastronomie ET Bons plans").
  Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})>
  get allUnique {
    final out =
        <
          String,
          ({NearbyCandidate candidate, List<String> matchedInterests})
        >{};
    byInterest.forEach((interest, list) {
      for (final c in list) {
        final existing = out[c.placeId];
        if (existing == null) {
          out[c.placeId] = (candidate: c, matchedInterests: [interest]);
        } else {
          out[c.placeId] = (
            candidate: existing.candidate,
            matchedInterests: [...existing.matchedInterests, interest],
          );
        }
      }
    });
    return out;
  }

  int get totalCandidates =>
      byInterest.values.fold(0, (sum, list) => sum + list.length);
  int get uniqueCandidates => allUnique.length;
}

// ─── POI-2.5 : POI-first candidate gather (before any external API) ───────

/// Tente de construire un pool de candidats 100 % POI (sans appel Google
/// Places ni géocodage) quand la destination est couverte par la base POI
/// et que le nombre de POI est suffisant.
///
/// Contrairement à POI-2.4, cette version est auto-contenue :
/// - elle ne dépend pas de `centerForDay` / geocodage
/// - elle construit un centre synthétique à partir du centroïde des POIs
/// - elle est appelée AVANT toute API externe dans `gatherCandidatesForTrip`
///
/// Retourne `null` si :
/// - la destination n'est pas couverte (`destinationKey == null`)
/// - le repository POI n'est pas disponible
/// - le nombre de POI est inférieur au seuil (minimum 5 total ET au
///   moins 1 POI par jour calendaire)
///
/// Dans tous les cas `null`, le caller doit tomber en fallback sur le
/// flux Google Places + géocodage existant.
Future<List<DayCandidates>?> _tryGatherPoiOnlyCandidates({
  required Trip trip,
  required List<DateTime> days,
  required List<String> interests,
  required PoiRepository? poiRepository,
  required int walkRadius,
  String? languageCode,
}) async {
  final destinationKey = DestinationKeyMapper.map(trip.destination);
  if (destinationKey == null) {
    // ignore: avoid_print
    print(
      '[suggestion_source] destination="${trip.destination}" '
      'destinationKey=null source=places_fallback reason=not_covered',
    );
    return null;
  }
  if (poiRepository == null) {
    // ignore: avoid_print
    print(
      '[suggestion_source] destination="${trip.destination}" '
      'destinationKey=$destinationKey source=places_fallback reason=no_repository',
    );
    return null;
  }

  final poiAdapter = PoiCandidateAdapter(poiRepository);
  final poiCandidates = await poiAdapter.adaptForDestination(destinationKey);

  // Seuil déterministe : minimum 5 total ET au moins 1 par jour calendaire.
  const minTotalThreshold = 5;
  final minPerDayThreshold = days.length;
  final insufficient = poiCandidates.length < minTotalThreshold ||
      poiCandidates.length < minPerDayThreshold;

  if (insufficient) {
    // ignore: avoid_print
    print(
      '[suggestion_source] destination="${trip.destination}" '
      'destinationKey=$destinationKey source=places_fallback reason=insufficient_poi '
      'poiCandidates=${poiCandidates.length} '
      'thresholdTotal=$minTotalThreshold thresholdPerDay=$minPerDayThreshold',
    );
    return null;
  }

  // Centre synthétique = centroïde des POIs. Pas besoin de géocodage.
  var latSum = 0.0;
  var lngSum = 0.0;
  for (final c in poiCandidates) {
    latSum += c.latitude;
    lngSum += c.longitude;
  }
  final center = DayCenter(
    latitude: latSum / poiCandidates.length,
    longitude: lngSum / poiCandidates.length,
    source: 'poi_centroid',
  );

  // Construit le pool : chaque intérêt reçoit tous les POIs.
  final travelerProfile = trip.travelerType != null
      ? travelerPlacesProfiles[trip.travelerType]
      : null;
  final byInterest = <String, List<NearbyCandidate>>{};
  for (final interest in interests) {
    final query = interestPlacesQueries[interest];
    if (query == null) continue;
    if (travelerProfile != null &&
        travelerProfile.excludedInterests.contains(interest)) {
      continue;
    }
    byInterest[interest] = poiCandidates;
  }

  // Assemble List<DayCandidates> — un par jour, même centre pour tous.
  final pool = <DayCandidates>[];
  for (final day in days) {
    pool.add(
      DayCandidates(day: day, center: center, byInterest: byInterest),
    );
  }

  // ignore: avoid_print
  print(
    '[suggestion_source] destination="${trip.destination}" '
    'destinationKey=$destinationKey poiCandidates=${poiCandidates.length} '
    'source=poi_only days=${days.length} google_places_called=false gemini_called=false',
  );
  return pool;
}

/// Récolte les candidats Places pour CHAQUE jour du voyage. Brique de base
/// du flow Places-first (refonte du suggesteur 2026-04-25). Le pipeline
/// complet enchaîne ici puis :
/// 1. construit un prompt Gemini avec les pools de candidats par jour
/// 2. demande à Gemini d'organiser/sélectionner parmi cette liste
/// 3. construit les ActivitySuggestion finales depuis les place_id retournés
///
/// Logique par jour :
/// - Centre = `centerForDay()` (hôtel actif → ville segment → destination).
/// - Pour chaque intérêt du voyageur :
///   - Skip si exclu par le profil voyageur (ex: Famille → Nightlife).
///   - Merge types et textQueries (intérêt + profil).
///   - Fetch Nearby (par types) + Text Search (par mots-clés) en parallèle.
///   - Dédup par place_id, applique les filtres (rating ≥ global + spécifiques).
///
/// Latence : N jours × M intérêts × ≤5 calls Places, mais cache `places_search`
/// (gemini_cache) hit dès qu'un centre × types est répété (cas typique : mono-ville
/// long séjour, tous les jours partagent le même centre → 1er jour paie, suivants
/// gratuits). Centre arrondi à 3 décimales (~110 m) dans le cache key.
Future<List<DayCandidates>> gatherCandidatesForTrip({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,

  /// Si null, on prend `trip.interests`. Sinon on override (utile pour les
  /// tests ciblés ou un Suggérer "Restaurants uniquement").
  List<String>? interestsOverride,

  /// Langue dans laquelle Places doit retourner les noms (BCP-47 : "fr",
  /// "en"...). Critique pour les destinations non-anglophones (Maroc → noms
  /// en arabe sinon). Default null = langue Places par défaut.
  String? languageCode,

  /// POI-2.0 — Repository POI pour enrichir le pool avec des candidats curatés.
  /// Si null, le comportement existant (100% Google Places) est préservé.
  PoiRepository? poiRepository,
}) async {
  final interests = interestsOverride ?? trip.interests ?? const <String>[];
  if (interests.isEmpty) {
    debugPrint('[places_first] Aucun intérêt sur ce voyage — pool vide');
    return [];
  }

  final travelerProfile = trip.travelerType != null
      ? travelerPlacesProfiles[trip.travelerType]
      : null;
  // Cascade walk → transit (validée Lalith 2026-04-26).
  // 1. `walkRadius` est le rayon principal — zone de marche (Senior 600m).
  // 2. Si la pool walking est trop maigre (<minPoolForCascade), on étend à
  //    `transitRadius` (zone accessible en transport public/taxi). Lieux dans
  //    walkRadius restent dans la pool — on AJOUTE seulement les supplémentaires.
  // 3. Sans transit défini, comportement classique : un seul radius.
  final walkRadius =
      travelerProfile?.searchRadiusMeters ?? defaultSearchRadiusMeters;
  final transitRadius = travelerProfile?.transitRadiusMeters;
  final minPoolCascade = travelerProfile?.minPoolForCascade ?? 0;

  // Itère sur les jours du voyage (inclus startDate, inclus endDate).
  final days = <DateTime>[];
  final start = DateTime(
    trip.startDate.year,
    trip.startDate.month,
    trip.startDate.day,
  );
  final end = DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day);
  for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    days.add(d);
  }
  debugPrint(
    '[places_first] Trip "${trip.title}" : ${days.length} jours, ${interests.length} intérêts, '
    'profil=${trip.travelerType ?? "default"}, walk=${walkRadius}m'
    '${transitRadius != null ? ", transit=${transitRadius}m (cascade si pool<$minPoolCascade)" : ""}',
  );

  // V8.4 (Lalith 2026-05-10 — Phase Quality-1A) — compteurs trackés
  // pendant tout le gather pour alimenter `[places_quality_filter]`
  // en fin de run. 3 axes :
  //   - rejectedByType : `_isQualityRejected` retourne un motif type
  //     (hard_blocklist, soft_blocklist, religious, event_venue).
  //   - rejectedByReviews : `_isQualityRejected` retourne un motif
  //     reviews (high_rating_too_few, low_reviews_not_travel_safe).
  //   - rejectedByLowRating : `c.rating < placesGlobalMinRating` ou
  //     null (filtré en amont des autres règles).
  // V8.5 — restructuré du `[places_quality_summary]` initial pour
  // faciliter le scan : raw + kept + 3 axes agrégés + breakdown
  // détaillé.
  final qualityRejectCounts = <String, int>{};
  var qualityRawCount = 0;
  var qualityKeptCount = 0;
  var qualityRejectedByLowRating = 0;
  var qualityRejectedByOtherFilter = 0;

  // Récolte par intérêt avec un radius donné. Factorisé pour la cascade
  // walk→transit : on appelle d'abord avec walkRadius, et si la pool d'un jour
  // est trop maigre, on rappelle avec transitRadius en mergant les nouveaux
  // place_id (les lieux walking restent — priorité forte selon Lalith 26/04).
  Future<Map<String, List<NearbyCandidate>>> collectByInterest(
    DayCenter center,
    int radius,
  ) async {
    final byInterest = <String, List<NearbyCandidate>>{};
    for (final interest in interests) {
      final query = interestPlacesQueries[interest];
      if (query == null) continue;
      if (travelerProfile != null &&
          travelerProfile.excludedInterests.contains(interest)) {
        continue;
      }
      final mergedTypes = <String>{
        ...query.includedTypes,
        if (travelerProfile != null) ...travelerProfile.additionalTypes,
      }.toList();
      // Les additionalTextQueries du profil voyageur (Grand luxe → "luxury
      // spa"/"fine dining"/"Michelin"/"rooftop bar"/"boutique hotel" ;
      // Couple → "romantic restaurant"/"sunset spot" ; etc.) sont FILTRÉES
      // par compatibilité avec l'intérêt courant. Évite que "luxury spa"
      // remonte dans la pool Événements ou que "fine dining" pollue
      // Wellness (logs Lalith 2026-05-08, test budget élevé).
      final profileQueries = travelerProfile == null
          ? const <String>[]
          : travelerProfile.additionalTextQueries
                .where((q) => isProfileQueryCompatibleWithInterest(q, interest))
                .toList();
      final mergedTextQueries = <String>[
        ...query.textQueries,
        ...profileQueries,
      ];

      // Diagnostic : combien de calls par intérêt (Nearby + N × searchText).
      // Sert à comprendre quand le filtre `_filterByQueryNameMatch` ne tourne
      // pas — souvent parce que `mergedTextQueries` est vide pour cet intérêt.
      debugPrint(
        '[places_first_match] interest=$interest types=${mergedTypes.length} '
        'textQueries=${mergedTextQueries.length} '
        '${mergedTextQueries.isEmpty ? "" : "(${mergedTextQueries.join(", ")})"}',
      );
      final calls = <Future<List<NearbyCandidate>>>[];
      if (mergedTypes.isNotEmpty) {
        calls.add(
          nearbyService.searchNearby(
            latitude: center.latitude,
            longitude: center.longitude,
            includedTypes: mergedTypes,
            radius: radius,
            languageCode: languageCode,
          ),
        );
      }
      // Pour chaque searchText, on filtre à la source : si la query a au moins
      // 1 mot signif (>4 chars hors stopwords) ET aucun de ces mots n'est dans
      // le `name` du Place retourné, on rejette + log. Évite les cas où Google
      // remonte un homonyme distant (ex: query "hiking trail" → name "Restaurant
      // Le Sentier"). NB : ne fixe pas les data-bugs Google (ex: Place "Parc du
      // Château" Épinal qui pointe en fait sur le Château d'Épinal voisin —
      // dans ce cas le name matche, le bug est côté Google) : pour ces cas le
      // logging C ci-dessous donne la visibilité pour blacklister manuellement.
      for (final tq in mergedTextQueries) {
        // V8.12 (Lalith 2026-05-10 — Quality-1C language fix) — les
        // textQueries de `interestPlacesQueries` sont toutes en
        // français. Forcer `lang='fr'` pour searchText évite les
        // résultats incohérents (q="rue commerçante" lang=en
        // observé sur trip Paris). `searchNearby` (type-based)
        // garde le `languageCode` user pour les noms localisés.
        calls.add(
          nearbyService
              .searchText(
                textQuery: tq,
                latitude: center.latitude,
                longitude: center.longitude,
                radius: radius,
                languageCode: 'fr',
              )
              .then(
                (results) => _filterByQueryNameMatch(results, tq, interest),
              ),
        );
      }
      final fetched = await Future.wait(calls);
      final merged = <String, NearbyCandidate>{};
      for (final list in fetched) {
        for (final c in list) {
          merged[c.placeId] = c;
        }
      }
      final filtered = merged.values.where((c) {
        qualityRawCount++;
        final r = c.rating;
        if (r == null || r < placesGlobalMinRating) {
          qualityRejectedByLowRating++;
          return false;
        }
        if (!query.matchesFilters(c)) {
          qualityRejectedByOtherFilter++;
          return false;
        }
        if (_isExcludedPlace(c)) {
          qualityRejectedByOtherFilter++;
          return false;
        }
        // V8.4 (Phase Quality-1A) — filtre travel-quality post
        // exclusions historiques. Tracker les rejets par motif pour
        // alimenter `[places_quality_filter]`.
        final qReason = _isQualityRejected(c);
        if (qReason != null) {
          qualityRejectCounts[qReason] =
              (qualityRejectCounts[qReason] ?? 0) + 1;
          return false;
        }
        qualityKeptCount++;
        return true;
      }).toList();
      byInterest[interest] = filtered;
    }
    return byInterest;
  }

  // V8 (Lalith 2026-05-10 — Phase Cost-2) — pool par centre, plus par jour.
  // Stratégie : un voyage 8 jours avec 2 villes (4 + 4 jours) faisait 8
  // récoltes complètes (8 × M intérêts × ~1+T calls). Désormais on groupe
  // les jours par signature de centre (lat_3dec, lng_3dec, walkRadius,
  // langue) et on construit la pool UNE seule fois par groupe. Les jours
  // d'un même centre réutilisent le pool. Économie attendue : ~75% des
  // searchText et nearby sur cold cache (vs Cost-1 seul).
  //
  // Ordre :
  // 1. Boucle 1 (sans API) : calcul du `DayCenter` pour chaque jour.
  // 2. Groupement par signature pure → 1 groupe par centre distinct.
  // 3. Boucle 2 séquentielle : pour chaque groupe, on collecte la pool
  //    (walk + cascade transit) UNE SEULE FOIS. Logue `[places_pool_build]`.
  // 4. Boucle 3 : on assemble le `List<DayCandidates>` final en
  //    réplicant la pool du groupe sur chaque jour qu'il couvre.
  //    Logue `[places_pool_reuse]`.
  //
  // La séquentialité (vs `Future.wait(days.map…)` avant) réduit aussi
  // la race per-kind du budget Cost-1 : moins d'appels concurrents
  // qui passent simultanément `shouldSkip` avant que l'un ait incrémenté.

  // ─── POI-2.5 : tentative POI-first AVANT toute API externe ───────────────
  // Si la destination est couverte et a assez de POIs, on construit le pool
  // 100 % POI sans appeler ni géocodage ni Google Places.
  final poiOnlyResult = await _tryGatherPoiOnlyCandidates(
    trip: trip,
    days: days,
    interests: interests,
    poiRepository: poiRepository,
    walkRadius: walkRadius,
    languageCode: languageCode,
  );
  if (poiOnlyResult != null) {
    return poiOnlyResult;
  }
  // ─── Fin POI-2.5 — fallback géocodage + Google Places ci-dessous ─────────

  // Étape 1 : centres par jour, sans API Places.
  final dayCenters = await Future.wait(
    days.map(
      (day) async => (
        day: day,
        center: await centerForDay(
          trip: trip,
          day: day,
          hotels: hotels,
          geocoder: geocoder,
        ),
      ),
    ),
  );
  // V8.4 (Lalith 2026-05-10 — Phase Quality-1A, rule 6) — skip les
  // jours orphelins.
  //
  // V8.10 (Lalith 2026-05-10 — fix Paris) — règle nuancée :
  // - Si destination est un pays/région large (Brésil, Thaïlande,
  //   Asie du Sud-Est, etc.), `source=destination` = centre géo trop
  //   large → skip pour éviter le filler.
  // - Si destination est UNE VILLE (Paris, Tokyo, Bangkok, …), le
  //   fallback destination EST un centre de recherche utile → on
  //   garde, même quand des segments sont définis (cas trip Paris
  //   4j où segments mal alignés faisaient retomber tous les jours
  //   en orphan → 0 suggestion).
  // - Détection via `isBroadDestinationName` (liste pays/région
  //   FR+EN). Default safe = broad si destination vide/inconnue.
  final tripHasSegments = trip.itinerarySegments.isNotEmpty;
  // V8.11 (Lalith 2026-05-10 — destination resolver V1) — résolution
  // via cache DB (`gemini_cache` action='destination_resolve') avec
  // fallback static `isBroadDestinationName`. Réutilisable cross-trips.
  // Si pas de cache disponible (test offline, harness), retombe sur
  // la heuristique seule.
  String destinationLevel;
  if (nearbyService.cacheService != null) {
    destinationLevel = await resolveDestinationLevel(
      destination: trip.destination,
      cache: nearbyService.cacheService!,
    );
  } else {
    destinationLevel = isBroadDestinationName(trip.destination)
        ? 'broad'
        : 'city';
  }
  final destinationIsBroad = destinationLevel == 'broad';
  var orphanDaysSkipped = 0;
  final validDayCenters = dayCenters
      .where((dc) {
        if (dc.center == null) {
          debugPrint('Jour ${_iso(dc.day)} : centre non géocodable, skip');
          return false;
        }
        if (tripHasSegments && dc.center!.source == 'destination') {
          if (destinationIsBroad) {
            debugPrint(
              '[places_quality] ${_iso(dc.day)} orphan skipped '
              'reason=broad_destination_fallback_blocked '
              '(destination="${trip.destination}")',
            );
            orphanDaysSkipped++;
            return false;
          } else {
            // Destination = ville → fallback OK, on log pour visibilité.
            // ignore: avoid_print
            print(
              '[places_center] date=${_iso(dc.day)} '
              'source=destination_city '
              'city="${trip.destination}" '
              'reason=city_destination_fallback',
            );
          }
        }
        return true;
      })
      .map((dc) => (day: dc.day, center: dc.center!))
      .toList();

  // Étape 2 : groupement par signature (lat_3dec, lng_3dec, walkRadius, lang).
  // Le rayon transit n'entre PAS dans la signature : il dérive du profil et
  // s'applique uniformément à un même `walkRadius`. Pas besoin de séparer.
  final groups = <String, ({DayCenter center, List<DateTime> days})>{};
  for (final dc in validDayCenters) {
    final sig = placesPoolSignature(
      center: dc.center,
      radius: walkRadius,
      languageCode: languageCode,
    );
    final existing = groups[sig];
    if (existing == null) {
      groups[sig] = (center: dc.center, days: [dc.day]);
    } else {
      existing.days.add(dc.day);
    }
  }

  // V8.15 (Lalith 2026-05-10 — Quality-1D budget priority fix) —
  // blueprint fetch DÉPLACÉ AVANT l'étape 3. Sans ce déplacement,
  // l'étape 3 (per-group interest fetch) brûle les 80 calls du
  // budget Cost-1 sur les voyages multi-villes (8 groupes Bangkok
  // hotel + Rayong + Koh Samet + Phu Quoc + Tam Coc + Hanoi + Hoi
  // An + destination = ~100+ tentatives). Les blueprint queries
  // qui suivaient retombaient sur `shouldSkip=true` (skip=545
  // observé sur Bangkok 46j) → pool sans must-sees → selector pick
  // nearby filler.
  //
  // Maintenant : ~17 blueprint calls réservés en priorité, ~63
  // calls restants pour gather. Sur cold cache long trip, gather
  // peut hit le cap mais blueprint a son budget garanti.
  final blueprint = getBlueprintForDestination(trip.destination);
  final blueprintMustSees = <NearbyCandidate>[];
  final blueprintExperiences = <NearbyCandidate>[];
  if (blueprint != null) {
    // ignore: avoid_print
    print(
      '[destination_blueprint] destination="${trip.destination}" '
      'found=true kind=${blueprint.kind.name} '
      'mustSee=${blueprint.mustSeeQueries.length} '
      'experience=${blueprint.experienceQueries.length}',
    );
    if (validDayCenters.isNotEmpty) {
      final biasCenter = validDayCenters.first.center;
      Future<void> resolveBlueprintQuery(
        String query,
        String tier,
        List<NearbyCandidate> destination,
      ) async {
        final results = await nearbyService.searchText(
          textQuery: query,
          latitude: biasCenter.latitude,
          longitude: biasCenter.longitude,
          // Rayon généreux : les blueprint queries sont city-wide
          // (« Grand Palace Bangkok » résout à n'importe quel
          // hotel Bangkok via geo-bias Google). 50km couvre métro
          // + day-trips proches.
          radius: 50000,
          languageCode: 'fr',
        );
        if (results.isEmpty) {
          // ignore: avoid_print
          print('[blueprint_resolve] query="$query" status=miss tier=$tier');
          return;
        }
        final topPick = results.firstWhere(
          (c) => (c.rating ?? 0) >= 4.0,
          orElse: () => results.first,
        );
        destination.add(topPick);
        // ignore: avoid_print
        print(
          '[blueprint_resolve] query="$query" status=hit '
          'place="${topPick.name}" rating=${topPick.rating ?? "?"} '
          'tier=$tier',
        );
      }

      for (final query in blueprint.mustSeeQueries) {
        await resolveBlueprintQuery(query, 'must_see', blueprintMustSees);
      }
      for (final query in blueprint.experienceQueries) {
        await resolveBlueprintQuery(query, 'experience', blueprintExperiences);
      }
    }
  } else if (trip.destination.trim().isNotEmpty) {
    // ignore: avoid_print
    print(
      '[destination_blueprint] destination="${trip.destination}" found=false',
    );
  }

  // Étape 3 : pool unique par groupe (séquentiel pour limiter la race
  // per-kind du budget Cost-1). Map sig → byInterest mergé walk+transit.
  final poolBySig = <String, Map<String, List<NearbyCandidate>>>{};
  for (final entry in groups.entries) {
    final sig = entry.key;
    final group = entry.value;
    final byInterest = await collectByInterest(group.center, walkRadius);
    if (transitRadius != null) {
      final walkUniqueCount = byInterest.values
          .expand((l) => l)
          .map((c) => c.placeId)
          .toSet()
          .length;
      final byInterestTransit = await collectByInterest(
        group.center,
        transitRadius,
      );
      for (final tEntry in byInterestTransit.entries) {
        final walkList = byInterest[tEntry.key] ?? const <NearbyCandidate>[];
        final walkIds = walkList.map((c) => c.placeId).toSet();
        final added = tEntry.value
            .where((c) => !walkIds.contains(c.placeId))
            .toList();
        if (added.isNotEmpty) {
          byInterest[tEntry.key] = [...walkList, ...added];
        }
      }
      final totalAfter = byInterest.values
          .expand((l) => l)
          .map((c) => c.placeId)
          .toSet()
          .length;
      // V8.1 (Lalith 2026-05-10) — `print` plutôt que `debugPrint` :
      // sur cold cache, la pipeline emet des milliers de
      // `[places_first_match]` qui saturent le throttle de `debugPrint`
      // et masquent ces logs critiques pour la validation Cost-2.
      // Volume = 1 ligne par groupe de centres distincts (typiquement
      // 1-3 par voyage), pas de risque de spam.
      // ignore: avoid_print
      print(
        '[places_pool_build] sig=$sig source=${group.center.source} '
        'days=${group.days.length} walk=$walkUniqueCount '
        'transit=+${totalAfter - walkUniqueCount} (${transitRadius}m)',
      );
    } else {
      final unique = byInterest.values
          .expand((l) => l)
          .map((c) => c.placeId)
          .toSet()
          .length;
      // ignore: avoid_print
      print(
        '[places_pool_build] sig=$sig source=${group.center.source} '
        'days=${group.days.length} walk=$unique (${walkRadius}m)',
      );
    }
    poolBySig[sig] = byInterest;
  }

  // V8.16 (Lalith 2026-05-10 — Quality-1D city-scoped fanout) —
  // injection blueprint LIMITÉE aux groupes géographiquement proches
  // de la `biasCenter` (1ʳᵉ jour, qui définit la ville du blueprint).
  //
  // Bug observé multi-villes Thaïlande+Vietnam : les blueprints
  // Bangkok (Grand Palace, Wat Pho...) étaient injectés dans TOUS
  // les `poolBySig` y compris Hanoi (~1500km), Phu Quoc (~700km),
  // Hoi An (~700km). K-means partitionnait ensuite ces pools mixés
  // → cluster avec centroïde (13.1489, 101.3990) et radius=428km
  // qui agrège Bangkok must-sees + Vietnam nearby.
  //
  // Fix : seuil 50km (haversine) entre biasCenter et group.center.
  // Au-delà → skip injection. Bangkok blueprint reste dans les
  // groupes Bangkok area (hôtel Bang Na, hotel central, segment
  // Bangkok Pattaya day-trip jusqu'à 150km est rejeté — mais c'est
  // acceptable car les must-sees Bangkok ne sont pas relevant pour
  // une journée Pattaya).
  if (blueprintMustSees.isNotEmpty || blueprintExperiences.isNotEmpty) {
    const blueprintFanoutMaxKm = 50.0;
    final biasCenter = validDayCenters.first.center;
    var injectedClusters = 0;
    var skippedClusters = 0;
    for (final entry in groups.entries) {
      final sig = entry.key;
      final groupCenter = entry.value.center;
      final byInterest = poolBySig[sig];
      if (byInterest == null) continue;
      // Haversine inline (small).
      final distKm = _haversineKmBetween(
        biasCenter.latitude,
        biasCenter.longitude,
        groupCenter.latitude,
        groupCenter.longitude,
      );
      if (distKm > blueprintFanoutMaxKm) {
        skippedClusters++;
        // ignore: avoid_print
        print(
          '[blueprint_fanout_skip] '
          'clusterCenter=${groupCenter.latitude.toStringAsFixed(3)},'
          '${groupCenter.longitude.toStringAsFixed(3)} '
          'distKm=${distKm.toStringAsFixed(1)} '
          'reason=city_mismatch (>${blueprintFanoutMaxKm.toInt()}km from biasCenter)',
        );
        continue;
      }
      if (blueprintMustSees.isNotEmpty) {
        byInterest[blueprintMustSeeMarker] = blueprintMustSees;
      }
      if (blueprintExperiences.isNotEmpty) {
        byInterest[blueprintExperienceMarker] = blueprintExperiences;
      }
      injectedClusters++;
    }
    final nearbyTotal = poolBySig.values.fold<int>(
      0,
      (sum, byInt) => sum + byInt.values.fold(0, (s, list) => s + list.length),
    );
    // ignore: avoid_print
    print(
      '[blueprint_fanout] city=${blueprint?.destinationKey ?? "?"} '
      'injectedClusters=$injectedClusters skippedClusters=$skippedClusters '
      '(maxKm=${blueprintFanoutMaxKm.toInt()})',
    );
    // ignore: avoid_print
    print(
      '[places_pool] blueprintMustSee=${blueprintMustSees.length} '
      'blueprintExperience=${blueprintExperiences.length} '
      'nearbyAfterInject=$nearbyTotal',
    );
  }

  // V8.28d (Lalith 2026-05-10 — tourist anchor fan-out pour
  // MetroProfile mégalopoles) — le geocoder "Tokyo, Japan" tombe
  // parfois sur Setagaya/Yoyogi-Hachiman (35.676/139.650), loin
  // des hotspots Shibuya/Asakusa/Ginza. Sans ce fan-out, le
  // per-day searchNearby autour de ce centre résidentiel récolte
  // du local non-touristique (Shimotakaido Park, Sasazuka Bowl,
  // etc.). On lance un `searchNearby` autour de chaque
  // `TouristAnchor` du MetroProfile avec types tourisme stricts.
  // Les résultats sont dédupliqués par placeId et injectés dans
  // tous les `poolBySig` à <= 50km du biasCenter (même critère que
  // le blueprint fanout V8.16).
  if (validDayCenters.isNotEmpty) {
    final biasCenter = validDayCenters.first.center;
    final metroProfile = getMetroProfileForCluster(
      biasCenter.latitude,
      biasCenter.longitude,
    );
    if (metroProfile != null &&
        metroProfile.isMegaCity &&
        metroProfile.touristAnchors.isNotEmpty) {
      // V8.28d-fix (Lalith 2026-05-11) — `place_of_worship` retiré :
      // Google Places API (New) `searchNearby` rejette ce type avec
      // HTTP 400 "Unsupported types". Symptôme observé simu Tokyo
      // 2026-05-11 : tous les anchors retournaient results=0, le
      // `metro_anchor_fanout` était neutralisé silencieusement
      // (wrapper retourne [] sur 400, logs `[places_nearby] HTTP 400`
      // visibles mais pas surfacés ici). Les temples/sanctuaires
      // (Senso-ji, Meiji-jingū, etc.) restent capturés via les types
      // génériques `tourist_attraction` / `historical_landmark` qui
      // les remontent côté Places API. Types conservés = sous-ensemble
      // strictement validé par l'API New.
      const anchorIncludedTypes = <String>[
        'tourist_attraction',
        'museum',
        'historical_landmark',
        'monument',
        'park',
        'art_gallery',
      ];
      final anchorResults = <String, NearbyCandidate>{};
      var anchorErrors = 0;
      for (final anchor in metroProfile.touristAnchors) {
        try {
          final results = await nearbyService.searchNearby(
            latitude: anchor.lat,
            longitude: anchor.lng,
            includedTypes: anchorIncludedTypes,
            radius: anchor.radiusMeters,
            languageCode: languageCode,
          );
          for (final c in results) {
            anchorResults[c.placeId] ??= c;
          }
          // ignore: avoid_print
          print(
            '[metro_anchor_fetch] city=${metroProfile.cityKey} '
            'anchor="${anchor.label}" '
            'lat=${anchor.lat.toStringAsFixed(4)},'
            'lng=${anchor.lng.toStringAsFixed(4)} '
            'radius=${anchor.radiusMeters}m '
            'results=${results.length}',
          );
        } catch (e) {
          // V8.28d-fix — log explicite. Exception ici = signal d'un
          // problème côté wrapper (HTTP 400 retourne [] sans throw).
          // Sans log, un type invalide partagé fait silently échouer
          // les 9 anchors d'affilée.
          anchorErrors++;
          // ignore: avoid_print
          print(
            '[metro_anchor_fetch] city=${metroProfile.cityKey} '
            'anchor="${anchor.label}" EXCEPTION error="$e"',
          );
        }
      }
      if (anchorErrors > 0) {
        // ignore: avoid_print
        print(
          '[metro_anchor_fanout] city=${metroProfile.cityKey} '
          'anchorErrors=$anchorErrors '
          '(check includedTypes vs Places API New supported list)',
        );
      }
      if (anchorResults.isNotEmpty) {
        const anchorFanoutMaxKm = 50.0;
        final anchorList = anchorResults.values.toList();
        var injectedClusters = 0;
        var skippedClusters = 0;
        for (final entry in groups.entries) {
          final sig = entry.key;
          final groupCenter = entry.value.center;
          final byInterest = poolBySig[sig];
          if (byInterest == null) continue;
          final distKm = _haversineKmBetween(
            biasCenter.latitude,
            biasCenter.longitude,
            groupCenter.latitude,
            groupCenter.longitude,
          );
          if (distKm > anchorFanoutMaxKm) {
            skippedClusters++;
            continue;
          }
          byInterest[metroAnchorMarker] = anchorList;
          injectedClusters++;
        }
        // ignore: avoid_print
        print(
          '[metro_anchor_fanout] city=${metroProfile.cityKey} '
          'totalUnique=${anchorResults.length} '
          'anchorsLaunched=${metroProfile.touristAnchors.length} '
          'injectedClusters=$injectedClusters '
          'skippedClusters=$skippedClusters '
          '(maxKm=${anchorFanoutMaxKm.toInt()})',
        );
      } else {
        // ignore: avoid_print
        print(
          '[metro_anchor_fanout] city=${metroProfile.cityKey} '
          'totalUnique=0 reason=all_anchors_empty_or_budget_skip',
        );
      }
    }
  }

  // V8.19 (Lalith 2026-05-10 — Q1D segment pool guard) — fallback
  // fetch pour les groupes segment_city dont le pool reste quasi
  // vide après gather étape 3 + blueprint injection. Cas observé :
  // « Hoi An » résolu canonical à 15.88,108.34 (commit 61f2fdb)
  // mais étape 3 ne trouve rien (cache miss + budget cramé sur trip
  // 46j multi-segments). Résultat : Hoi An days raw=0.
  //
  // Le guard : pour chaque group avec poolSize < 3 ET segment_city
  // source ET canonical avec queryHints, fetch les hints autour du
  // canonical center avec cascade radius 3km/8km/15km. Tag les
  // résultats `_BlueprintMustSee` (boost +100 — hints curated par
  // Lalith = iconiques segment).
  const segmentPoolGuardThreshold = 3;
  const segmentPoolGuardRadiiCascade = [3000, 8000, 15000];
  for (final entry in groups.entries) {
    final sig = entry.key;
    final groupCenter = entry.value.center;
    if (groupCenter.source != 'segment_city') continue;
    final byInterest = poolBySig[sig];
    if (byInterest == null) continue;
    final poolSize = byInterest.values.fold<int>(0, (s, l) => s + l.length);
    if (poolSize >= segmentPoolGuardThreshold) continue;

    // Trouver le canonical correspondant à ce group via les segments
    // du voyage. On match par distance haversine entre canonical
    // center et group center (< 5 km tolérance).
    SegmentCanonicalCity? canonical;
    String? matchedCity;
    for (final seg in trip.itinerarySegments) {
      final c = getCanonicalSegmentCity(seg.city, country: seg.country);
      if (c == null || c.queryHints.isEmpty) continue;
      final dKm = _haversineKmBetween(
        c.expectedLat,
        c.expectedLng,
        groupCenter.latitude,
        groupCenter.longitude,
      );
      if (dKm < 5.0) {
        canonical = c;
        matchedCity = seg.city;
        break;
      }
    }
    if (canonical == null) continue;

    // ignore: avoid_print
    print(
      '[segment_pool_guard] city="$matchedCity" '
      'center=${groupCenter.latitude.toStringAsFixed(4)},'
      '${groupCenter.longitude.toStringAsFixed(4)} '
      'pool=$poolSize action=fallback_fetch',
    );

    // Cascade radius : commence petit (3km), élargit si pool < 5.
    final fallbackResults = <NearbyCandidate>[];
    final seenIds = <String>{};
    var radiusUsed = 0;
    for (final radius in segmentPoolGuardRadiiCascade) {
      radiusUsed = radius;
      for (final hint in canonical.queryHints) {
        final results = await nearbyService.searchText(
          textQuery: hint,
          latitude: canonical.expectedLat,
          longitude: canonical.expectedLng,
          radius: radius,
          languageCode: 'fr',
        );
        for (final c in results.take(2)) {
          if (seenIds.contains(c.placeId)) continue;
          if ((c.rating ?? 0) < 4.0) continue;
          fallbackResults.add(c);
          seenIds.add(c.placeId);
        }
      }
      if (fallbackResults.length >= 5) break;
    }

    // ignore: avoid_print
    print(
      '[segment_pool_guard_result] city="$matchedCity" '
      'fetched=${fallbackResults.length} radius=$radiusUsed',
    );

    if (fallbackResults.isNotEmpty) {
      // Tag must-see (boost +100 dans le selector). Merge avec
      // blueprint must-sees existants si déjà présents.
      final existing =
          byInterest[blueprintMustSeeMarker] ?? <NearbyCandidate>[];
      byInterest[blueprintMustSeeMarker] = [...existing, ...fallbackResults];
    }
  }

  // ─── POI-2.0 : enrichir avec les POIs curatés ───
  final destinationKey = DestinationKeyMapper.map(trip.destination);
  if (destinationKey != null && poiRepository != null) {
    final poiAdapter = PoiCandidateAdapter(poiRepository);
    final poiCandidates = await poiAdapter.adaptForDestination(destinationKey);

    if (poiCandidates.isNotEmpty) {
      final poiByPlaceId = <String, NearbyCandidate>{
        for (final c in poiCandidates) c.placeId: c,
      };

      for (final byInterest in poolBySig.values) {
        // .keys.toList() car on mute la map pendant l'itération
        for (final interest in byInterest.keys.toList()) {
          final existing = byInterest[interest]!;
          final merged = <NearbyCandidate>[];

          // 1. Remplacer les Google Places par le POI curaté quand googlePlaceId match
          for (final gPlace in existing) {
            final poiMatch = poiByPlaceId[gPlace.placeId];
            merged.add(poiMatch ?? gPlace);
          }

          // 2. Ajouter les POIs sans match Google (IDs synthétiques poi:<id>)
          final seenInMerged = merged.map((c) => c.placeId).toSet();
          for (final poi in poiCandidates) {
            if (!seenInMerged.contains(poi.placeId)) {
              merged.add(poi);
            }
          }

          byInterest[interest] = merged;
        }
      }

      // ignore: avoid_print
      print(
        '[poi_first] destination=$destinationKey '
        'pois=${poiCandidates.length} merged into ${poolBySig.length} pool(s)',
      );
    }
  }
  // ─── Fin POI-2.0 ───

  // Étape 4 : assemblage `List<DayCandidates>`. Chaque jour récupère la
  // pool de son groupe — partage de référence, lecture seule en aval
  // (`selectVisitsDeterministic` / `partitionByQuartier` ne mutent pas).
  final pool = <DayCandidates>[];
  for (final dc in validDayCenters) {
    final sig = placesPoolSignature(
      center: dc.center,
      radius: walkRadius,
      languageCode: languageCode,
    );
    final byInterest = poolBySig[sig];
    if (byInterest == null) continue;
    pool.add(
      DayCandidates(day: dc.day, center: dc.center, byInterest: byInterest),
    );
    final unique = byInterest.values
        .expand((l) => l)
        .map((c) => c.placeId)
        .toSet()
        .length;
    // V8.1 — `print` même raison que `[places_pool_build]` ci-dessus.
    // Volume = 1 ligne par jour du voyage (max ~50 sur Thaïlande 46j).
    // ignore: avoid_print
    print(
      '[places_pool_reuse] sig=$sig day=${_iso(dc.day)} → $unique candidats',
    );
  }

  final totalUnique = pool.fold<int>(0, (sum, d) => sum + d.uniqueCandidates);
  debugPrint(
    '[places_first] Récolte terminée : ${pool.length} jours, '
    '${groups.length} groupe(s) de centres, '
    '$totalUnique lieux uniques cumulés',
  );

  // V8.5 (Lalith 2026-05-10 — Phase Quality-1A refinement) — log
  // structuré du filtrage qualité. `print` (pas debugPrint) pour
  // échapper au throttle qui ferait disparaître la ligne sur cold
  // cache verbeux. Format demandé Lalith :
  //
  //   [places_quality_filter]
  //   raw=N kept=M
  //   rejectedByType=A rejectedByReviews=B rejectedByLowRating=C
  //   breakdown={hard_blocklist_primary:X,...}
  //
  // 3 axes agrégés depuis `qualityRejectCounts` :
  //   - byType : motifs liés au type Places (hard/soft blocklist,
  //     event venue sans signal, religieux sans signal).
  //   - byReviews : motifs liés au volume d'avis (rating ≥ 4.5 mais
  //     trop peu d'avis, reviews < 20 sur type non travel-safe).
  //   - byLowRating : `c.rating == null` ou `< placesGlobalMinRating`
  //     (filtre amont, tracké séparément).
  // L'axe « otherFilter » regroupe `query.matchesFilters` et
  // `_isExcludedPlace` (filtres historiques V4-V7) — pas exposé en
  // log car la rotation a stabilisé ce périmètre.
  const byTypeKeys = <String>{
    'hard_blocklist_primary',
    'soft_blocklist_no_touristic_signal',
    'weak_event_venue_no_dated_source',
    'weak_religious_no_touristic_signal',
  };
  const byReviewsKeys = <String>{
    'high_rating_too_few_reviews',
    'low_reviews_not_travel_safe',
  };
  var qualityRejectedByType = 0;
  var qualityRejectedByReviews = 0;
  // V8.6 — exposer event_venue séparément pour faciliter le scan
  // des logs : c'est le motif sous lequel on rejette les BITEC,
  // halls de convention, stadiums, etc.
  final qualityRejectedByEventVenue =
      qualityRejectCounts['weak_event_venue_no_dated_source'] ?? 0;
  qualityRejectCounts.forEach((k, v) {
    if (byTypeKeys.contains(k)) {
      qualityRejectedByType += v;
    } else if (byReviewsKeys.contains(k)) {
      qualityRejectedByReviews += v;
    }
  });

  if (qualityRawCount > 0 || orphanDaysSkipped > 0) {
    final breakdown = qualityRejectCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // ignore: avoid_print
    print(
      '[places_quality_filter] tripId=${trip.id} '
      'raw=$qualityRawCount kept=$qualityKeptCount '
      'rejectedByType=$qualityRejectedByType '
      'rejectedByReviews=$qualityRejectedByReviews '
      'rejectedByRating=$qualityRejectedByLowRating '
      'rejectedByEventVenue=$qualityRejectedByEventVenue '
      'rejectedByOtherFilter=$qualityRejectedByOtherFilter '
      'orphanDaysSkipped=$orphanDaysSkipped '
      'breakdown={${breakdown.map((e) => "${e.key}:${e.value}").join(",")}}',
    );
  }
  return pool;
}

/// V8 (Lalith 2026-05-10 — Phase Cost-2) — signature pure d'un centre
/// pour grouper les jours qui partageront la même pool Places.
///
/// Format : `lat_3dec,lng_3dec|r=<radius>|l=<lang>`. Lat/lng arrondis à
/// 3 décimales (~110m) pour collapse les jitters d'hôtels proches. Le
/// rayon de marche entre dans la signature parce que deux centres très
/// proches mais avec des rayons différents (changement de profil voyageur
/// mid-trip — théorique, mais défensif) ne peuvent PAS partager la pool.
/// La langue Places idem (résultats `name` localisés).
///
/// Pure et testable. Pas de side-effect, pas d'I/O.
@visibleForTesting
String placesPoolSignature({
  required DayCenter center,
  required int radius,
  required String? languageCode,
}) {
  return '${center.latitude.toStringAsFixed(3)},'
      '${center.longitude.toStringAsFixed(3)}'
      '|r=$radius|l=${languageCode ?? "_"}';
}

String _iso(DateTime d) => d.toIso8601String().split('T').first;

/// V8.16 (Lalith 2026-05-10 — Q1D city-scoped fanout) — haversine
/// km entre 2 points lat/lng. Utilisé pour décider si un blueprint
/// candidate doit être injecté dans un cluster (selon distance au
/// biasCenter de la ville). Pas de précision inférieure au km
/// nécessaire pour ce cas — conversion entière OK.
double _haversineKmBetween(double lat1, double lng1, double lat2, double lng2) {
  const earthKm = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return earthKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Groupe de jours partageant le même centre (= mono-ville complète, ou un
/// segment d'une multi-villes). Un même `PlacesPromptInput` permet d'envoyer
/// UN SEUL prompt Gemini pour tous les jours du groupe au lieu de N prompts —
/// économie tokens × N et cohérence des choix entre jours.
class PlacesPromptInput {
  final DayCenter center;
  final List<DateTime> days;

  /// Pool de candidats agrégés sur tous les jours du groupe (en mono-ville la
  /// pool est identique tous les jours, donc fusionner ne change rien). Indexé
  /// par place_id, conserve la liste des intérêts qui matchent chaque candidat.
  final Map<
    String,
    ({NearbyCandidate candidate, List<String> matchedInterests})
  >
  pool;

  const PlacesPromptInput({
    required this.center,
    required this.days,
    required this.pool,
  });

  int get poolSize => pool.length;
}

/// Regroupe les jours du voyage par centre géographique (lat/lng arrondi
/// 3 décimales = ~110m). En mono-ville → 1 seul groupe. En multi-villes
/// (Nancy/Épinal) → 2 groupes. Économise les calls Gemini : 1 prompt par
/// groupe au lieu de 1 par jour.
List<PlacesPromptInput> groupDaysByCenter(List<DayCandidates> dayPool) {
  final groups =
      <
        String,
        ({
          DayCenter center,
          List<DateTime> days,
          Map<
            String,
            ({NearbyCandidate candidate, List<String> matchedInterests})
          >
          pool,
        })
      >{};

  for (final day in dayPool) {
    final key =
        '${day.center.latitude.toStringAsFixed(3)},${day.center.longitude.toStringAsFixed(3)}';
    final dayUnique = day.allUnique;
    final existing = groups[key];
    if (existing == null) {
      groups[key] = (
        center: day.center,
        days: [day.day],
        pool: Map.from(dayUnique),
      );
    } else {
      existing.days.add(day.day);
      // Fusion : si un nouveau candidat apparaît pour ce centre on l'ajoute,
      // si un existant a de nouveaux intérêts matchés on les fusionne.
      dayUnique.forEach((placeId, entry) {
        final ex = existing.pool[placeId];
        if (ex == null) {
          existing.pool[placeId] = entry;
        } else {
          final mergedInterests = {
            ...ex.matchedInterests,
            ...entry.matchedInterests,
          }.toList();
          existing.pool[placeId] = (
            candidate: ex.candidate,
            matchedInterests: mergedInterests,
          );
        }
      });
    }
  }
  return groups.values
      .map(
        (g) => PlacesPromptInput(center: g.center, days: g.days, pool: g.pool),
      )
      .toList();
}

/// K-means basique sur des points lat/lng. Retourne, pour chaque cluster non
/// vide, la liste des indices de points qui lui appartiennent.
///
/// Distance utilisée : approximation degrés → mètres (1° lat ≈ 111km, 1° lng
/// ≈ 73km à 48° de latitude — France métropolitaine). Pour des distances
/// intra-ville (<5 km), c'est largement suffisant pour clustering. La
/// dépendance à la latitude est négligeable sur cette échelle (la pool d'un
/// même groupe est de toute façon dans une seule ville).
///
/// Initialisation K-means++ simplifiée : le premier centroïde est un point
/// aléatoire (seed fixe pour reproductibilité), les suivants sont les points
/// les plus éloignés des centroïdes déjà choisis. Évite les initialisations
/// pathologiques (tous les centroïdes au même endroit).
///
/// Convergence : on arrête dès qu'aucun point ne change de cluster, ou après
/// `maxIterations` (20 par défaut, largement suffisant pour <100 points).
List<List<int>> _kMeansClusters({
  required List<({double lat, double lng})> points,
  required int k,
  int maxIterations = 20,
}) {
  if (points.isEmpty || k <= 0) return [];
  if (k >= points.length) {
    // Plus de clusters demandés que de points → 1 cluster par point.
    return List.generate(points.length, (i) => [i]);
  }
  if (k == 1) {
    return [List.generate(points.length, (i) => i)];
  }

  // Init K-means++ simplifiée
  final rand = math.Random(42); // seed fixe → résultats stables
  final centroidsIdx = <int>[rand.nextInt(points.length)];
  while (centroidsIdx.length < k) {
    var maxMinDist = -1.0;
    var pickedIdx = 0;
    for (var i = 0; i < points.length; i++) {
      if (centroidsIdx.contains(i)) continue;
      var minToCentroid = double.infinity;
      for (final c in centroidsIdx) {
        final d = _distSqMeters(points[i], points[c]);
        if (d < minToCentroid) minToCentroid = d;
      }
      if (minToCentroid > maxMinDist) {
        maxMinDist = minToCentroid;
        pickedIdx = i;
      }
    }
    centroidsIdx.add(pickedIdx);
  }
  var centroids = centroidsIdx.map((i) => points[i]).toList();

  // Itérations
  final labels = List<int>.filled(points.length, 0);
  for (var iter = 0; iter < maxIterations; iter++) {
    var changed = false;
    for (var i = 0; i < points.length; i++) {
      var bestIdx = 0;
      var bestDist = double.infinity;
      for (var c = 0; c < k; c++) {
        final d = _distSqMeters(points[i], centroids[c]);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = c;
        }
      }
      if (labels[i] != bestIdx) {
        labels[i] = bestIdx;
        changed = true;
      }
    }
    if (!changed && iter > 0) break;

    // Recalcul centroïdes
    final sumLat = List<double>.filled(k, 0);
    final sumLng = List<double>.filled(k, 0);
    final counts = List<int>.filled(k, 0);
    for (var i = 0; i < points.length; i++) {
      final l = labels[i];
      sumLat[l] += points[i].lat;
      sumLng[l] += points[i].lng;
      counts[l]++;
    }
    for (var c = 0; c < k; c++) {
      if (counts[c] > 0) {
        centroids[c] = (lat: sumLat[c] / counts[c], lng: sumLng[c] / counts[c]);
      }
    }
  }

  // Groupe les indices par cluster, retire les clusters vides
  final clusters = List.generate(k, (_) => <int>[]);
  for (var i = 0; i < points.length; i++) {
    clusters[labels[i]].add(i);
  }
  return clusters.where((c) => c.isNotEmpty).toList();
}

/// Distance au carré en mètres² entre 2 points lat/lng (approximation France
/// métropolitaine). Utilisée par K-means — racine carrée inutile pour
/// comparaison de distances.
double _distSqMeters(
  ({double lat, double lng}) a,
  ({double lat, double lng}) b,
) {
  final dLatM = (a.lat - b.lat) * 111000.0;
  final dLngM = (a.lng - b.lng) * 73000.0;
  return dLatM * dLatM + dLngM * dLngM;
}

/// Partitionne chaque groupe géographique en sous-groupes "quartier" via
/// K-means sur les coordonnées de la pool. Chaque sous-groupe a sa pool
/// restreinte aux lieux du cluster + un sous-ensemble des jours du groupe
/// d'origine (round-robin).
///
/// Pourquoi : sans clustering, Gemini reçoit une pool de 40 lieux étalés sur
/// 4 km autour du centre du jour et propose des activités successives à
/// 1-2 km l'une de l'autre — incompatible avec les profils Senior/Famille
/// (max 300m / 1000m). Avec clustering, la pool d'un jour est concentrée
/// dans un seul quartier (~10-15 lieux) → Gemini ne PEUT PLUS proposer de
/// lieux distants par construction.
///
/// Round-robin pour assigner les jours aux clusters : varie les quartiers
/// entre les jours du voyage (jour 1 → quartier A, jour 2 → quartier B,
/// jour 3 → quartier C, jour 4 → quartier A à nouveau, etc.). Le voyageur
/// découvre des zones différentes au fil du voyage.
///
/// Pas de clustering pour les petits groupes (pool < 12 lieux ou groupe à
/// 1 seul jour) : pas de gain, juste du bruit. Un PlacesPromptInput unique
/// est conservé tel quel dans ce cas.
///
/// `coPilotMode` : en mode CoPilot on demande 3 options par créneau, donc
/// la pool d'un cluster doit rester un peu plus grande (mini ~12 lieux pour
/// avoir 3 alternatives × matin/déj/aprem/soir). On baisse K en conséquence.
List<PlacesPromptInput> partitionByQuartier(
  List<PlacesPromptInput> groups, {
  bool coPilotMode = false,
}) {
  final out = <PlacesPromptInput>[];
  for (final group in groups) {
    out.addAll(_splitGroupByQuartier(group, coPilotMode: coPilotMode));
  }
  return out;
}

List<PlacesPromptInput> _splitGroupByQuartier(
  PlacesPromptInput group, {
  required bool coPilotMode,
}) {
  final entries = group.pool.entries.toList();

  // V8.14 (Lalith 2026-05-10 — Quality-1D fix critique) — détection
  // des candidats blueprint (must-see / experience) dans la pool du
  // groupe. Ils seront fan-out à TOUS les sub-clusters après le
  // k-means, peu importe leur position géographique.
  //
  // Pourquoi : les must-sees iconiques (Grand Palace 13.75,100.49)
  // sont géo-distants de l'hôtel Bang Na (13.67,100.60). Le k-means
  // les met dans un sub-cluster « Old City », différent du sub-
  // cluster « Bang Na » où sont assignés les jours hôtel-centric.
  // Round-robin → jours Bang Na → ne voient jamais Grand Palace.
  // Le voyageur prend un taxi pour Grand Palace peu importe le
  // quartier de sa journée — must-sees doivent être dans CHAQUE
  // sub-cluster pool.
  final blueprintIndices = <int>[];
  for (var i = 0; i < entries.length; i++) {
    final mi = entries[i].value.matchedInterests;
    if (mi.contains(blueprintMustSeeMarker) ||
        mi.contains(blueprintExperienceMarker)) {
      blueprintIndices.add(i);
    }
  }

  // Pool trop petite → pas de clustering (peu de gain, risque de cluster vide).
  final minPoolForCluster = coPilotMode ? 18 : 12;
  if (entries.length < minPoolForCluster) {
    return [group];
  }

  // K = nombre de clusters cible. En mode multi-jours : 1 cluster/jour
  // (round-robin pour varier les quartiers). En jour isolé : K basé sur la
  // taille pool, on choisira ensuite le cluster le plus pertinent.
  final perCluster = coPilotMode ? 18 : 12;
  final byPool = (entries.length / perCluster).floor();
  final byDays = group.days.length;
  final k = group.days.length >= 2
      ? math.max(2, math.min(byDays, byPool)).clamp(2, 5)
      : math.max(2, byPool).clamp(2, 5);
  if (k < 2) return [group];

  final points = entries
      .map(
        (e) =>
            (lat: e.value.candidate.latitude, lng: e.value.candidate.longitude),
      )
      .toList();
  final clusterIndices = _kMeansClusters(points: points, k: k);
  if (clusterIndices.length < 2) return [group];

  // ─── Cas jour isolé : on choisit LE cluster le plus pertinent ──────
  // Pertinence = centroïde du cluster le plus proche du centre du groupe
  // (= hôtel ou centre-ville géocodé). Évite de proposer un quartier
  // périphérique pour un voyageur ancré sur un hôtel central.
  if (group.days.length == 1) {
    // Trie tous les clusters par distance centroïde-au-centre-du-groupe.
    final clustersByDist = <({int idx, double distSq})>[];
    for (var i = 0; i < clusterIndices.length; i++) {
      final cluster = clusterIndices[i];
      var sumLat = 0.0;
      var sumLng = 0.0;
      for (final j in cluster) {
        sumLat += entries[j].value.candidate.latitude;
        sumLng += entries[j].value.candidate.longitude;
      }
      final cLat = sumLat / cluster.length;
      final cLng = sumLng / cluster.length;
      final d = _distSqMeters(
        (lat: cLat, lng: cLng),
        (lat: group.center.latitude, lng: group.center.longitude),
      );
      clustersByDist.add((idx: i, distSq: d));
    }
    clustersByDist.sort((a, b) => a.distSq.compareTo(b.distSq));

    // Agrège les clusters dans l'ordre de proximité jusqu'à atteindre le
    // seuil de pool minimum (10 lieux). Sans ce seuil, un cluster trop
    // étroit (4-5 lieux) force Gemini à répéter le même resto en déjeuner
    // ET dîner — vu sur Épinal J8 le 26/04. Le critère "proximité au centre"
    // est conservé : on prend les clusters proches d'abord, donc la pool
    // résultante reste compacte.
    const minPool = 10;
    final indices = <int>[];
    for (final c in clustersByDist) {
      indices.addAll(clusterIndices[c.idx]);
      if (indices.length >= minPool) break;
    }
    // V8.14 (Q1D fan-out) — blueprint candidates ajoutés au cluster
    // sélectionné pour qu'un jour isolé puisse aussi proposer des
    // must-sees iconiques (peu importe le quartier choisi).
    final indicesSet = indices.toSet();
    for (final bIdx in blueprintIndices) {
      if (!indicesSet.contains(bIdx)) {
        indices.add(bIdx);
      }
    }
    final clusterPool = Map.fromEntries(indices.map((i) => entries[i]));
    return [
      PlacesPromptInput(
        center: group.center,
        days: group.days,
        pool: clusterPool,
      ),
    ];
  }

  // ─── Cas multi-jours : fusionne les petits clusters puis round-robin ──
  // Avant d'assigner les jours, on absorbe les clusters trop petits dans
  // leur voisin le plus proche (par centroïde). Sans ça, un cluster avec 2
  // lieux peut être assigné à un jour qui doit alors caser 5 activités dans
  // 2 lieux — Gemini répète forcément. Vu le 26/04 sur Épinal J7+J8 où J8
  // recevait un cluster pool=2 via round-robin.
  const minPoolMulti = 10;
  final mergedClusters = _mergeSmallClusters(
    clusterIndices: clusterIndices,
    entries: entries,
    minPool: minPoolMulti,
  );

  // V8.14 (Q1D fan-out) — blueprint candidates ajoutés à TOUS les
  // sub-clusters mergés. Sinon round-robin → jours assignés à un
  // sub-cluster « Bang Na » ne voient jamais Grand Palace (qui est
  // dans le sub-cluster « Old City »). Les must-sees doivent être
  // disponibles partout — voyageur prend taxi peu importe quartier.
  if (blueprintIndices.isNotEmpty) {
    for (var c = 0; c < mergedClusters.length; c++) {
      final existingSet = mergedClusters[c].toSet();
      for (final bIdx in blueprintIndices) {
        if (!existingSet.contains(bIdx)) {
          mergedClusters[c].add(bIdx);
        }
      }
    }
    // ignore: avoid_print
    print(
      '[blueprint_fanout] candidates=${blueprintIndices.length} '
      'clusters=${mergedClusters.length} '
      '(must-sees added to all sub-clusters)',
    );
  }

  final byClusterIdx = <int, List<DateTime>>{};
  for (var dayIdx = 0; dayIdx < group.days.length; dayIdx++) {
    final cIdx = dayIdx % mergedClusters.length;
    byClusterIdx.putIfAbsent(cIdx, () => []).add(group.days[dayIdx]);
  }

  final result = <PlacesPromptInput>[];
  for (final entry in byClusterIdx.entries) {
    final clusterPool = Map.fromEntries(
      mergedClusters[entry.key].map((i) => entries[i]),
    );
    result.add(
      PlacesPromptInput(
        center: group.center,
        days: entry.value,
        pool: clusterPool,
      ),
    );
  }
  return result;
}

/// Fusionne les clusters dont la pool fait moins de `minPool` lieux dans le
/// cluster voisin le plus proche (centroïde le plus proche). Itère jusqu'à ce
/// que tous les clusters atteignent `minPool` ou qu'il n'en reste qu'un. Évite
/// que round-robin attribue à un jour un cluster trop maigre (< 5 activités
/// possibles).
List<List<int>> _mergeSmallClusters({
  required List<List<int>> clusterIndices,
  required List<
    MapEntry<
      String,
      ({NearbyCandidate candidate, List<String> matchedInterests})
    >
  >
  entries,
  required int minPool,
}) {
  final clusters = clusterIndices.map((c) => List<int>.from(c)).toList();

  ({double lat, double lng}) centroidOf(List<int> cluster) {
    var sumLat = 0.0;
    var sumLng = 0.0;
    for (final i in cluster) {
      sumLat += entries[i].value.candidate.latitude;
      sumLng += entries[i].value.candidate.longitude;
    }
    return (lat: sumLat / cluster.length, lng: sumLng / cluster.length);
  }

  while (clusters.length > 1) {
    // Trouve le plus petit cluster
    var smallestIdx = 0;
    for (var i = 1; i < clusters.length; i++) {
      if (clusters[i].length < clusters[smallestIdx].length) smallestIdx = i;
    }
    if (clusters[smallestIdx].length >= minPool) break; // tous OK

    // Trouve son voisin le plus proche
    final smallCentroid = centroidOf(clusters[smallestIdx]);
    var nearestIdx = -1;
    var nearestDistSq = double.infinity;
    for (var i = 0; i < clusters.length; i++) {
      if (i == smallestIdx) continue;
      final d = _distSqMeters(smallCentroid, centroidOf(clusters[i]));
      if (d < nearestDistSq) {
        nearestDistSq = d;
        nearestIdx = i;
      }
    }
    if (nearestIdx < 0) break;

    // Fusion : tout absorbé dans le voisin
    clusters[nearestIdx].addAll(clusters[smallestIdx]);
    clusters.removeAt(smallestIdx);
  }
  return clusters;
}

/// Retire les lieux de type repas (restaurant/cafe/bar/...) d'une pool.
/// Utilisé en mode Auto category=all : Gemini ne propose plus de repas, le
/// code les insère par scoring déterministe (cf. `insertDeterministicMeals`).
PlacesPromptInput _filterOutMealTypes(PlacesPromptInput input) {
  final filteredPool = Map.fromEntries(
    input.pool.entries.where((e) => !_isMealPrimaryType(e.value.candidate)),
  );
  return PlacesPromptInput(
    center: input.center,
    days: input.days,
    pool: filteredPool,
  );
}

/// Types de restos à exclure systématiquement de l'insertion déterministe.
/// Fast food et takeaway : aucun voyageur n'a coché "Gastronomie" pour avoir
/// du Burger King. Ils restent dans la pool générale (filtre _isExcludedPlace
/// les laisse passer car ce sont quand même des restaurants), mais
/// `_findBestRestoNear` les rejette pour les insertions automatiques.
const Set<String> _fastFoodPrimaryTypes = <String>{
  'fast_food_restaurant',
  'meal_takeaway',
  'meal_delivery',
  'food_court',
  'american_restaurant', // souvent McDonald's/Burger King/KFC tagués ainsi
  'hamburger_restaurant',
};

/// V8 (Lalith 2026-05-10 — Phase Cost-2) — rayon de fetch de la pool
/// restaurant, partagée par tous les jours d'un même centre. Plus large
/// que la cascade `_pickRestoFromPool` (max 1500m du **anchor**, qui peut
/// être à walkRadius du centre) pour que la pool couvre toutes les
/// distances atteignables. 2500m couvre activité-à-walkRadius (~1km) +
/// cascade 1500m. Au-delà = profil très transit-friendly, accepté que
/// quelques restos au bord soient hors pool (slot laissé vide alors).
const int _restaurantPoolFetchRadiusMeters = 2500;

/// V8 (Lalith 2026-05-10 — Phase Cost-2) — fetch unique de la pool
/// restaurants pour un centre. UNE searchNearby (types meal) par
/// centre, à utiliser pour TOUS les jours du groupe via
/// `_pickRestoFromPool`. Remplace l'ancienne cascade
/// `_findBestRestoNear` qui faisait 1-3 appels API par meal × par jour.
Future<List<NearbyCandidate>> _buildRestaurantPoolForCenter({
  required PlacesNearbyService nearbyService,
  required DayCenter center,
  required String? languageCode,
  int radius = _restaurantPoolFetchRadiusMeters,
}) async {
  return nearbyService.searchNearby(
    latitude: center.latitude,
    longitude: center.longitude,
    includedTypes: const ['restaurant', 'cafe', 'bakery'],
    radius: radius,
    maxResults: 20,
    languageCode: languageCode,
  );
}

/// V8 (Lalith 2026-05-10 — Phase Cost-2) — sélection in-memory du
/// meilleur resto depuis une pool pré-fetchée. Reproduit la cascade
/// distance de l'ancien `_findBestRestoNear` (préfère ≤ `mealRadius`,
/// élargit à 1000m, 1500m max) sans aucun appel API. Toutes les autres
/// règles (rating, fastfood, cuisine dedup, soft use count) sont
/// identiques à l'ancienne implémentation — c'est le même filtrage,
/// juste appliqué localement au lieu d'être délégué à Places.
///
/// Retourne `(candidate, distM)` ou null. `distM` remplace le
/// `radiusUsed` historique pour annoter le matchReason ("un peu plus
/// loin car peu d'options proches" si distM > mealRadius).
(NearbyCandidate, int)? _pickRestoFromPool({
  required List<NearbyCandidate> pool,
  required double anchorLatitude,
  required double anchorLongitude,
  required int mealRadius,
  required TravelerPlacesProfile? travelerProfile,
  required List<String> tripInterests,
  Set<String> excludeTitlesNorm = const {},
  Set<String> excludePrimaryTypes = const {},
  Map<String, int> softExcludeTitlesUseCount = const {},
  int? budgetPriceCap,
  String? logContext,
}) {
  if (pool.isEmpty) {
    debugPrint(
      '[places_first_skip_meal] ${logContext ?? "(no_context)"} '
      'reason=empty_pool raw=0',
    );
    return null;
  }

  // Seuils effectifs : profil voyageur + boost Gastronomie + plancher 4.0.
  // Logique copiée 1:1 de l'ancien `_findBestRestoNear` pour préserver
  // strictement le comportement (rating/reviews/priceLevel).
  final hasGastronomieInterest = tripInterests.contains('Gastronomie');
  final profileMinRating = travelerProfile?.minRating ?? 4.0;
  final effectiveMinRating = math.max(
    4.0,
    hasGastronomieInterest ? profileMinRating + 0.2 : profileMinRating,
  );
  final baseMinReviews = travelerProfile?.minUserRatingCount ?? 30;
  final effectiveMinReviews = hasGastronomieInterest
      ? baseMinReviews * 2
      : baseMinReviews;
  final profileMinPrice = travelerProfile?.minPriceLevel;
  final profileMaxPrice = travelerProfile?.maxPriceLevel;
  final maxPrice = (profileMaxPrice == null)
      ? budgetPriceCap
      : (budgetPriceCap == null
            ? profileMaxPrice
            : (profileMaxPrice < budgetPriceCap
                  ? profileMaxPrice
                  : budgetPriceCap));
  final minPrice = hasGastronomieInterest && (maxPrice == null || maxPrice >= 2)
      ? math.max(profileMinPrice ?? 2, 2)
      : profileMinPrice;

  String norm(String s) => s.toLowerCase().trim();
  // Chaînes de fast food / restos médiocres à blacklister par nom. Regex
  // insensible casse, vérifie nom du candidat. Couvre les cas où le primary
  // type Places ne révèle pas le caractère fast food (ex: "Chine Express"
  // tagué `chinese_restaurant` est un fast food, mais bloquer tout le type
  // serait trop strict).
  // Regex chaînes fast food / restos médiocres. Couvre les cas où le primary
  // type Places n'est pas révélateur. Variante : "Chinexpress" sans espace +
  // patterns "kebab"/"tacos" génériques (chaînes locales souvent priceLevel 1
  // mais rating gonflé > 4.5). Filtre minPriceLevel ≥ 2 attrape la majorité,
  // cette regex couvre les exceptions.
  final fastFoodChainRegex = RegExp(
    r"\b(burger\s*king|mc\s*donald|kfc|subway|quick|domino|pizza\s*hut|speed\s*burger|chin\w*\s*express|chinexpress|wok\s*to\s*walk|nooi|prêt\s*à\s*manger|pret\s*a\s*manger|brioche\s*dor[ée]e|paul|five\s*guys|five\s*tacos|o.?tacos|tacos\s*avenue|pomme\s*de\s*pain|harlem\s*smash|istanbul\s*kebab|kebab|berliner|baguette\s*&\s*baguette)\b",
    caseSensitive: false,
  );
  int distMeters(double lat1, double lng1, double lat2, double lng2) {
    final dLat = (lat1 - lat2) * 111000;
    final dLng = (lng1 - lng2) * 73000;
    return math.sqrt(dLat * dLat + dLng * dLng).round();
  }

  // Filtrage + comptage par catégorie de rejet pour diagnostiquer pourquoi
  // un slot repas peut être skippé (cf. logs `[places_first_skip_meal]`).
  // Les compteurs sont mutuellement exclusifs : 1 candidat n'est compté
  // que dans la 1re catégorie qui le rejette.
  var rejByRating = 0;
  var rejByReviews = 0;
  var rejByExcluded = 0;
  var rejByNotMealPrimary = 0;
  var rejByFastfoodType = 0;
  var rejByFastfoodChain = 0;
  var rejByExcludeTitle = 0;
  var rejByCuisineExcl = 0;
  var rejByMinPrice = 0;
  var rejByMaxPrice = 0;
  var rejByTooFar = 0;
  // V8 Cost-2 : la cascade distance s'applique APRÈS les filtres qualité
  // (haversine in-memory). On garde les candidats jusqu'à 1500m du anchor
  // — au-delà = équivalent de l'ancienne cascade qui s'arrêtait à 1500.
  const cascadeMaxDist = 1500;
  final filtered = <(NearbyCandidate, int)>[];
  for (final c in pool) {
    if (c.rating == null || c.rating! < effectiveMinRating) {
      rejByRating++;
      continue;
    }
    if ((c.userRatingCount ?? 0) < effectiveMinReviews) {
      rejByReviews++;
      continue;
    }
    if (_isExcludedPlace(c)) {
      rejByExcluded++;
      continue;
    }
    // Strict primary meal : élimine les faux positifs Places (Marché Central
    // tagué `florist` primary mais retourné par searchNearby car `bakery` en
    // secondaire). Un vrai resto a un primary `restaurant`/`cafe`/`bakery`.
    if (!_isMealPrimaryType(c)) {
      rejByNotMealPrimary++;
      continue;
    }
    if (c.types.isNotEmpty && _fastFoodPrimaryTypes.contains(c.types.first)) {
      rejByFastfoodType++;
      continue;
    }
    if (fastFoodChainRegex.hasMatch(c.name)) {
      rejByFastfoodChain++;
      continue;
    }
    if (excludeTitlesNorm.contains(norm(c.name))) {
      rejByExcludeTitle++;
      continue;
    }
    // Diversité : exclut le style cuisine du déjeuner pour ne pas re-proposer
    // le même type au dîner (ex: japanese_restaurant midi → exclut au soir).
    if (c.types.isNotEmpty && excludePrimaryTypes.contains(c.types.first)) {
      rejByCuisineExcl++;
      continue;
    }
    if (minPrice != null && c.priceLevel != null && c.priceLevel! < minPrice) {
      rejByMinPrice++;
      continue;
    }
    if (maxPrice != null && c.priceLevel != null && c.priceLevel! > maxPrice) {
      rejByMaxPrice++;
      continue;
    }
    final distM = distMeters(
      anchorLatitude,
      anchorLongitude,
      c.latitude,
      c.longitude,
    );
    if (distM > cascadeMaxDist) {
      rejByTooFar++;
      continue;
    }
    filtered.add((c, distM));
  }
  if (filtered.isEmpty) {
    final breakdown = <String, int>{
      'rating': rejByRating,
      'reviews': rejByReviews,
      'excluded_type': rejByExcluded,
      'not_meal_primary': rejByNotMealPrimary,
      'fastfood_type': rejByFastfoodType,
      'fastfood_chain': rejByFastfoodChain,
      'exclude_title_dedup': rejByExcludeTitle,
      'cuisine_excl_diversity': rejByCuisineExcl,
      'min_price': rejByMinPrice,
      'max_price_budget': rejByMaxPrice,
      'too_far_from_anchor': rejByTooFar,
    };
    final sorted = breakdown.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final primaryReason = sorted.isEmpty
        ? 'all_candidates_rejected'
        : 'rejected_by_${sorted.first.key}';
    debugPrint(
      '[places_first_skip_meal] ${logContext ?? "(no_context)"} '
      'reason=$primaryReason '
      'raw=${pool.length} filtered=0 cascade_max=${cascadeMaxDist}m '
      'breakdown={${sorted.map((e) => "${e.key}:${e.value}").join(",")}}',
    );
    return null;
  }

  String norm2(String s) => s.toLowerCase().trim();
  double score(NearbyCandidate c) {
    final r = c.rating ?? 0;
    final n = c.userRatingCount ?? 0;
    final base = r * (n <= 1 ? 1 : math.log(n));
    // Pénalité soft pour les restos déjà utilisés sur le voyage : -50 par
    // usage. Force la diversification : un resto à score 35 jamais utilisé
    // bat un resto à score 40 utilisé 1× (40 - 50 = -10). Mais si la pool
    // est petite, le moins pire reste éligible (cap dur à 2 via excludeTitles).
    final softUseCount = softExcludeTitlesUseCount[norm2(c.name)] ?? 0;
    final softPenalty = softUseCount * 50.0;
    return base - softPenalty;
  }

  // Cascade in-memory : préfère candidats ≤ mealRadius, puis 1000m, puis
  // 1500m max. Reproduit le comportement « rester près du anchor sauf si
  // pool indigente » de l'ancien `_findBestRestoNear`. Le distM réel du
  // pick est retourné pour annoter le matchReason côté caller.
  final cascade = <int>{mealRadius, 1000, cascadeMaxDist}.toList()..sort();
  for (final r in cascade) {
    final inRadius = filtered.where((e) => e.$2 <= r).toList()
      ..sort((a, b) => score(b.$1).compareTo(score(a.$1)));
    if (inRadius.isNotEmpty) {
      return inRadius.first;
    }
  }
  // Inatteignable : `filtered` est non-vide et `cascade` se termine à
  // `cascadeMaxDist` ≥ tous les `distM` (filtre `rejByTooFar`).
  return null;
}

/// Slots de visite pour la journée selon le volume cible (= maxActivitiesPerDay
/// du profil, ou 4 par défaut). Évite les heures de repas (12:00-13:30 et
/// 18:30-21:00) qui sont gérées par l'insertion déterministe restos.
///
/// Validé Lalith 26/04 : Senior=3 slots, Chill=2, default=4. Pas plus de 5
/// pour ne pas saturer la journée.
List<String> _visitSlotsForCount(int count) {
  switch (count) {
    case 1:
      return const ['14:30'];
    case 2:
      return const ['10:00', '15:00'];
    case 3:
      return const ['10:00', '14:30', '16:30'];
    case 4:
      return const ['09:30', '11:00', '14:30', '16:30'];
    case 5:
      return const ['09:30', '11:00', '14:30', '16:00', '17:30'];
    default:
      return count <= 0
          ? const <String>[]
          : const ['09:30', '11:00', '14:30', '16:00', '17:30'];
  }
}

/// Sélectionne déterministiquement les activités-visites pour chaque jour de
/// chaque cluster, sans appeler Gemini. Pipeline (Lalith 26/04) :
///
/// Pour chaque cluster :
///   Pour chaque jour du cluster :
///     Pour chaque slot horaire (selon `maxActivitiesPerDay` du profil) :
///       1. Filtrer la pool : type approprié à l'horaire (cf. `_isAppropriateForTime`),
///          non-repas, hors blacklist, hors titres déjà choisis (intra-cluster +
///          existants au planning).
///       2. Filtrer par DISTANCE depuis l'activité précédente (≤ maxConsec).
///          Premier slot = ancrage centre du cluster.
///       3. Scorer : rating × log(reviews) + bonus intérêts matchés - pénalité
///          distance.
///       4. Prendre le top.
///       5. Si pool vide pour ce slot → skip (mieux que de mettre une aberration).
///
/// 0 appel Gemini. 0 hallucination. Distances respectées par construction.
List<ActivitySuggestion> selectVisitsDeterministic({
  required List<PlacesPromptInput> clusters,
  required Trip trip,
  required TravelerPlacesProfile? travelerProfile,
  Set<String> existingTitlesNormalized = const {},
  // Phase 2 / Tâche 2.4 — dédup `SameComplexGroup` derrière flag.
  // Default OFF par construction : si l'appelant ne passe rien, le
  // comportement reste strictement identique à pré-2.4.
  bool useSameComplexDedup = false,
  List<SameComplexGroup> complexGroups = const <SameComplexGroup>[],

  /// Journal optionnel de rejets `same_complex_cap` (pour tests).
  /// Si non null, **chaque rejet** y est appendé. Production passe
  /// `null` → aucune allocation, aucun overhead.
  List<SameComplexRejection>? sameComplexRejectionsOut,
  // Phase 3 / Tâche 3.2 — scope validation derrière flag.
  // Default OFF par construction : si l'appelant ne passe rien,
  // le comportement reste strictement identique à pré-3.2.
  bool useDestinationScope = false,
  DestinationIntelligence? destinationIntelligence,

  /// Journal optionnel de rejets `destination_scope` (pour tests).
  /// Si non null, **chaque rejet** y est appendé. Production passe
  /// `null` → aucune allocation, aucun overhead.
  List<DestinationScopeRejection>? destinationScopeRejectionsOut,
}) {
  // Phase 2 / Tâche 2.4 — la dédup complexe est active uniquement
  // quand le flag ET la liste sont non vides. Une de ces 2
  // conditions seule = no-op (cas destination sans groupes connus).
  final complexDedupActive = useSameComplexDedup && complexGroups.isNotEmpty;

  // Phase 3 / Tâche 3.2 — scope validation active uniquement
  // quand le flag ET la DI sont fournis. Une de ces 2 conditions
  // seule = no-op (cas destination sans DI connue → fallback au
  // filtre legacy `blockedAddressPatterns`).
  final destinationScopeActive =
      useDestinationScope && destinationIntelligence != null;

  // Compteurs trip-wide par `complex_key` (init une seule fois pour
  // tout le voyage, indépendant du cluster).
  final complexCountAcrossTrip = <String, int>{};
  // V8.7 (Lalith 2026-05-10 — Quality-1A v4 final gate) — pré-filtre
  // strict des candidats AVANT toute logique de sélection. Couvre les
  // leaks observés sur run debug Thaïlande (painter, medical_clinic,
  // tire_shop, noodle_shop, BITEC, supermarchés, etc.) qui passaient
  // le gather mais pollutaient les visites finales. Tracking par
  // catégorie de rejet pour le `[places_selector_summary]`.
  final finalGateCounts = <String, int>{};
  // Cap log volume : on logue uniquement les N premières rejections
  // par catégorie, sinon les pools cold cache de 700+ candidats noient
  // les autres logs.
  const finalGateLogPerCategory = 5;
  final finalGateLogged = <String, int>{};
  // V8.9 — tripInterests pré-calculé pour le wellness/nightlife
  // mismatch dans `_isAllowedFinalVisitCandidate`.
  final finalGateTripInterests = (trip.interests ?? const <String>[]).toSet();
  // V8.28b1.2 (Lalith 2026-05-11) — fallback MetroProfile au niveau
  // trip-destination quand un sous-cluster n'a pas de match géo.
  // Cas observé Singapour : sous-cluster centré (1.14, 104.43) (~75
  // km du centre Singapour, soit Bintan en Indonésie) avait
  // `clusterMetroProfile=null` → aucun filter Johor/Indonesia ne
  // s'appliquait, candidats hors-pays leakaient en pool. La trip
  // destination "Singapore" résout vers le blueprint Singapore →
  // MetroProfile Singapore via le registre. On l'utilise comme
  // fallback uniquement quand `clusterMetro == null`.
  MetroProfile? tripDestinationMetro;
  final tripBlueprint = getBlueprintForDestination(trip.destination);
  if (tripBlueprint != null) {
    for (final p in metroProfiles) {
      if (p.cityKey == tripBlueprint.destinationKey) {
        tripDestinationMetro = p;
        break;
      }
    }
  }

  final filteredClusters = clusters.map((cluster) {
    final newPool =
        <
          String,
          ({NearbyCandidate candidate, List<String> matchedInterests})
        >{};
    // V8.28b1 — MetroProfile du cluster utilisé pour 2 filtres :
    // 1. `blockedAddressPatterns` : rejet `out_of_country` quand
    //    l'adresse contient un pattern interdit (Singapour vs Johor).
    // 2. `visitBlockedNamePatterns` : rejet `restaurant_out_of_scope`
    //    quand le nom match un hawker centre (Lau Pa Sat, Maxwell...).
    //    Le marker curated NE sauve PAS ces lieux (réservés aux repas).
    //
    // V8.28b1.2 — fallback `tripDestinationMetro` quand le cluster
    // n'a pas de match (sous-cluster drift géo). Évite que les
    // candidats hors-pays leakent sur les sous-clusters frontière
    // (Singapour ↔ Bintan/Batam, etc.).
    final clusterMetro = getMetroProfileForCluster(
      cluster.center.latitude,
      cluster.center.longitude,
    );
    final effectiveMetro = clusterMetro ?? tripDestinationMetro;
    final blockedAddrPatterns =
        effectiveMetro?.blockedAddressPatterns ?? const <String>[];
    final visitBlockedNamePatterns =
        effectiveMetro?.visitBlockedNamePatterns ?? const <String>[];
    for (final entry in cluster.pool.entries) {
      final candidate = entry.value.candidate;
      final reason = _isAllowedFinalVisitCandidate(
        candidate,
        tripInterests: finalGateTripInterests,
        matchedInterests: entry.value.matchedInterests,
        blockedAddressPatterns: blockedAddrPatterns,
        visitBlockedNamePatterns: visitBlockedNamePatterns,
      );
      if (reason == null) {
        // Phase 3 / Tâche 3.2 — scope validation (flag-gated).
        // Strictement court-circuité quand `destinationScopeActive
        // == false` → comportement pré-3.2 préservé. Quand
        // actif, applique le validator en ADDITION du filtre
        // legacy (AND logique) : un candidat doit passer les
        // deux. Le filtre legacy reste actif en flag OFF pour
        // les destinations sans DI dans la registry.
        if (destinationScopeActive) {
          final scopeResult = validatePlaceInScope(
            ScopeValidationPlace(
              name: candidate.name,
              address: candidate.address,
              // `NearbyCandidate` n'expose pas de countryCode
              // côté Google Places New v1 → toujours null.
              // Validator tombera sur l'étape 2/3 (regions /
              // hints adresse).
              countryCode: null,
              lat: candidate.latitude,
              lng: candidate.longitude,
            ),
            destinationIntelligence,
          );
          if (!scopeResult.isInScope) {
            final rej = DestinationScopeRejection(
              candidateTitle: candidate.name,
              candidateAddress: candidate.address,
              reason: scopeResult.rejectionReason!,
              confidence: scopeResult.confidence,
              matchedEvidence: scopeResult.matchedEvidence,
            );
            destinationScopeRejectionsOut?.add(rej);
            final scopeReason = rej.pipelineReason;
            finalGateCounts[scopeReason] =
                (finalGateCounts[scopeReason] ?? 0) + 1;
            final loggedSoFar = finalGateLogged[scopeReason] ?? 0;
            if (loggedSoFar < finalGateLogPerCategory) {
              finalGateLogged[scopeReason] = loggedSoFar + 1;
              // ignore: avoid_print
              print(
                '[places_destination_scope_reject] '
                'name="${candidate.name}" '
                'addr="${candidate.address}" '
                'reason=$scopeReason '
                'confidence=${scopeResult.confidence.name} '
                'evidence=${scopeResult.matchedEvidence}',
              );
            }
            continue;
          }
        }
        newPool[entry.key] = entry.value;
        continue;
      }
      finalGateCounts[reason] = (finalGateCounts[reason] ?? 0) + 1;
      final loggedSoFar = finalGateLogged[reason] ?? 0;
      if (loggedSoFar < finalGateLogPerCategory) {
        finalGateLogged[reason] = loggedSoFar + 1;
        // ignore: avoid_print
        print(
          '[places_final_quality_reject] '
          'name="${candidate.name}" '
          'types=${candidate.types.take(3).join(",")} '
          'rating=${candidate.rating ?? "?"} '
          'reviews=${candidate.userRatingCount ?? 0} '
          'reason=$reason',
        );
      }
    }
    return PlacesPromptInput(
      center: cluster.center,
      days: cluster.days,
      pool: newPool,
    );
  }).toList();

  // POI-2.5 diagnostic : log quand un cluster a un pool vide après le final gate.
  for (var i = 0; i < filteredClusters.length; i++) {
    if (filteredClusters[i].pool.isEmpty) {
      // ignore: avoid_print
      print(
        '[places_selector_pool_empty] cluster=$i/${filteredClusters.length} '
        'center=${filteredClusters[i].center.latitude.toStringAsFixed(3)},'
        '${filteredClusters[i].center.longitude.toStringAsFixed(3)} '
        'days=${filteredClusters[i].days.length} reason=final_gate_filtered_all',
      );
    }
  }

  final maxPerDay = travelerProfile?.maxActivitiesPerDay ?? 4;
  final slots = _visitSlotsForCount(maxPerDay);
  // Distance max entre 2 activités successives. Croise profil voyageur ET
  // préférence transport local de l'utilisateur (walk → ×0.7, taxi → ×1.5,
  // etc.). Si profil sans contrainte explicite, fallback 1500m.
  final maxConsec = effectiveMaxConsecutiveDistance(
    travelerProfile: travelerProfile,
    localTransportMode: trip.localTransportMode,
  );
  // 2026-05-08 calibrage #3 : multiplicateur distance penalty inversé
  // au transportDistanceFactor. Pour profil walk (factor=0.7) on durcit
  // ×8 → ~×11, pour taxi (1.5) on relâche à ~×5. Évite les long hops
  // 2.8km observés sur Backpack walk : le pick à 2.8km est encore +
  // pénalisé par rapport au pick proche, même mediocre.
  // Base = 8.0 (validée Lalith 26/04 sur Senior). Le diviseur clamp
  // pour éviter sur-pénalisation extrême avec d'éventuels factors < 0.5.
  final transportFactor = transportDistanceFactor(trip.localTransportMode);
  final distancePenaltyMultiplier = 8.0 / math.max(0.6, transportFactor);
  // Cap priceLevel calculé depuis le budget par personne. Évince les lieux
  // dont le priceLevel Places est manifestement incompatible. Lieux sans
  // priceLevel (souvent absent côté Google) toujours conservés.
  final budgetPriceCap = priceLevelCapForBudget(
    budgetPerPersonEur: trip.budgetPerPersonEur,
    durationDays: trip.durationDays,
  );
  final tripInterests = (trip.interests ?? const <String>[]).toSet();

  String norm(String s) => s.toLowerCase().trim();

  // Noms de villes/segments du voyage à exclure : Places renvoie parfois une
  // entrée "tourist_attraction" qui s'appelle juste "Épinal" (page touristique
  // générique du nom de la ville). Filtre par nom = nom de destination ou de
  // segment, insensible casse. Cf. fix 26/04 J7 14:30 "Épinal" comme activité.
  final cityNamesNorm = <String>{
    norm(trip.destination.split(',').first.trim()),
    for (final seg in trip.itinerarySegments)
      norm(seg.city.split(',').first.trim()),
  }..removeWhere((s) => s.isEmpty);

  final out = <ActivitySuggestion>[];

  // V8.17 (Lalith 2026-05-10 — Quality-1D segment isolation) —
  // dédup par SEGMENT au lieu de trip-wide. Avant : un place pické
  // à Bangkok bloquait sa réapparition à Koh Samet (même si pool
  // disjoint, défensif). Cas observé Bangkok+Koh Samet : day 2
  // Koh Samet trouvait raw=12 mais filtered=0 reason=rejected_by_dedup
  // car des Bangkok blueprints étaient encore dans le pool Koh Samet
  // (pré-fix 2ad1144) ET déjà iconic-capped depuis Bangkok days.
  //
  // Maintenant : la clé segmentaire est dérivée du cluster.center
  // arrondi à 2 décimales (~10-100km résolution selon latitude).
  // Bangkok hotel area (~13.6, 100.5-100.6) → tous mêmes segment.
  // Koh Samet (12.5, 101.4) → segment distinct. Hanoi (21.0, 105.8)
  // → segment distinct.
  //
  // Mêmes règles intra-segment qu'avant (1 place / 1 fois max). Les
  // clusters d'un même segment partagent le set, ceux de segments
  // différents ne se voient pas.
  final selectedDedupKeysBySegment = <String, Set<String>>{};

  // V8.20 (Lalith 2026-05-10 — Day Builder pré-slot) — placeIds réservés
  // par les packs déjà construits dans des sub-clusters du même segment.
  // Cas Bangkok : k-means split en 2 sub-clusters, chacun avec Grand
  // Palace dans son pool (post-fanout). Sans réservation, les 2
  // sub-clusters tagueraient Grand Palace, le selector dédup le bloque
  // sur le 2ᵉ → slot vide. Avec réservation, le 2ᵉ sub-cluster ne le
  // voit plus comme disponible et compose un autre archétype.
  final dayBuilderReservedBySegment = <String, Set<String>>{};

  // 3 niveaux de cap : par jour (max 1×, strict), par cluster (max 2×),
  // ET par voyage (compteur global pour pénaliser dans le scoring).
  // Le compteur global évite J6 = J1/J3 quand 2 clusters proches ont des
  // lieux communs (Place Stanislas dans cluster hôtel ET cluster segment).
  const maxReusePerCluster = 2;
  final useCountAcrossTrip = <String, int>{};

  // V8.28b1.3 (Lalith 2026-05-11) — dédup trip-level placeId-based
  // pour les lieux iconiques. Complète `useCountAcrossTrip`
  // (name-based, qui rate quand Google renvoie le même placeId avec
  // 2 libellés légèrement différents — ex: "Buddha Tooth Relic
  // Temple" vs "Buddha Tooth Relic Temple & Museum") ET
  // `selectedDedupKeysBySegment` (per-cluster, qui ne propage pas
  // cross-cluster Bintan/Singapour). Set keyé par
  // `_dedupKeyForCandidate(c)` qui priorise placeId.
  //
  // Éligibilité limitée aux iconiques curés (cf.
  // `_isTripLevelDedupEligible`) → préserve V8.16 (Bangkok ne
  // bloque pas Koh Samet pour les non-iconiques).
  final iconicSelectedAcrossTrip = <String>{};

  // V8.6 (Lalith 2026-05-10 — Phase Quality-1A v3) — wellness cap
  // durci suite retour debug Thaïlande 45j. Spec Lalith :
  //   - max 1 wellness par jour (jamais 2, même profil tolérant).
  //   - max 1 wellness par 7 jours de voyage.
  //   - hard cap 3 wellness pour tout voyage (long trip ne dépasse pas).
  //
  // Formule trip-wide : `min(3, max(1, durationDays/7))`. Donne :
  //   - 5j → 1, 7j → 1, 14j → 2, 21j → 3, 30j+ → 3 (capped).
  //
  // Le profil tolérant (Wellness ∈ interests) NE bypass plus le cap :
  // cohérent avec « mieux vaut vide que mauvais ». Le voyageur peut
  // ajouter manuellement plus de spas s'il le veut.
  final wellnessIsStrongInterest = tripInterests.contains('Wellness');
  const maxWellnessPerDay = 1;
  final tripWideWellnessCap = math.min(
    3,
    math.max(1, (trip.durationDays / 7).floor()),
  );
  var wellnessCountTripWide = 0;
  // Compteur des rejets cap pour `[places_selector_summary]` final.
  var rejectedByWellnessCap = 0;
  // V8.9 (Q1B volume cap) — compteur global rejets cap majors.
  var rejectedByMajorsCap = 0;

  // 2026-05-08 calibrage #4 : cap densité Événements (miroir Wellness).
  // Profil non-tolérant : max 1/jour, 2/cluster.
  // Profil tolérant (Événements ∈ interests) : max 3/jour pour laisser
  // la marge à des journées événementielles riches (Grand luxe pouvait
  // remplir une journée 4× Événements quand pool dense ; cap=2 a tué
  // 13 visites sur le voyage car combo avec cap Wellness=2 ne laissait
  // plus assez de slots pour les autres tags). 3 = cap raisonnable
  // sans ré-introduire la concentration 4× consécutifs.
  final eventsIsStrongInterest = tripInterests.contains('Événements');
  const maxEventsPerDayLight = 1;
  const maxEventsPerDayTolerant = 3;
  const maxEventsPerClusterLight = 2;

  for (final cluster in filteredClusters) {
    final useCountThisCluster = <String, int>{};
    final entries = cluster.pool.entries.toList();
    // V8.6 — wellness cap est désormais trip-wide, plus per-cluster.
    var eventsCountThisCluster = 0;

    // V8.17 (Q1D segment isolation) — clé segmentaire du cluster.
    // Précision 2 décimales (~10-100km selon latitude). Bangkok area
    // ≈ 13.7,100.5 / Koh Samet ≈ 12.6,101.4 / Hanoi ≈ 21.0,105.8.
    // Le set de dédup pour ce segment est materialisé à la demande.
    final segmentKey =
        '${cluster.center.latitude.toStringAsFixed(2)},'
        '${cluster.center.longitude.toStringAsFixed(2)}';
    final selectedDedupKeys = selectedDedupKeysBySegment.putIfAbsent(
      segmentKey,
      () => <String>{},
    );

    // V8.17 — guard radius cluster. Si la spread du pool dépasse 50km,
    // on log un warning : signal de mix cross-segment. La récolte
    // gather + city-scoped fanout (commit 2ad1144) doit normalement
    // empêcher ça, mais le warning permet de détecter les régressions.
    if (entries.isNotEmpty) {
      var maxDistKm = 0.0;
      for (final e in entries) {
        final d = _haversineKmBetween(
          cluster.center.latitude,
          cluster.center.longitude,
          e.value.candidate.latitude,
          e.value.candidate.longitude,
        );
        if (d > maxDistKm) maxDistKm = d;
      }
      if (maxDistKm > 50.0) {
        // ignore: avoid_print
        print(
          '[cluster_guard] radiusTooLarge=${maxDistKm.toStringAsFixed(0)}km '
          'segmentKey=$segmentKey poolSize=${entries.length} '
          'reason=cross_segment_or_cross_country_mix',
        );
      }
    }

    // V8.20 (Day Builder) — pré-build des day packs thématiques pour
    // les clusters dans des grandes villes (Bangkok, Paris). Disabled
    // pour les clusters non-éligibles (islandBeach, no blueprint, etc.).
    // Les `reservedPlaceIds` viennent des sub-clusters précédents du
    // même segment pour éviter le double-pick cross-cluster.
    final segmentReserved = dayBuilderReservedBySegment.putIfAbsent(
      segmentKey,
      () => <String>{},
    );
    final dayBuilder = buildDayPacksForCluster(
      clusterCenterLat: cluster.center.latitude,
      clusterCenterLng: cluster.center.longitude,
      clusterDays: cluster.days,
      clusterPool: cluster.pool,
      trip: trip,
      maxPerDay: maxPerDay,
      reservedPlaceIds: segmentReserved,
    );
    if (dayBuilder.enabled) {
      for (final pack in dayBuilder.dayPackByDate.values) {
        segmentReserved.addAll(pack.placeIds);
      }
    }

    // V8.28f (Lalith 2026-05-11) — quality floor fallback. Calcule
    // le MetroProfile du cluster une fois pour tous les jours. Sera
    // utilisé dans le slot picker en mode fallback (sans day pack)
    // pour rejeter les candidats non-qualifiés (sans marker blueprint,
    // sans marker metro anchor, sans pattern match). Effet : Kimono
    // Hazuki / Private Thai Massage / yuenbettei daita / fillers
    // Bang Na n'apparaissent plus dans les picks fallback Bangkok ou
    // Tokyo. Hors mégalopole (Phu Quoc/Hoi An/Hanoi/Koh Samet),
    // `clusterMetroProfile == null` → pas de floor (pas de curation
    // pour comparer).
    final clusterMetroProfile = getMetroProfileForCluster(
      cluster.center.latitude,
      cluster.center.longitude,
    );
    // V8.28b1.3 — effective MetroProfile pour ce cluster : tombe en
    // fallback sur trip destination si le cluster n'a pas de match
    // (sub-cluster drift). Utilisé pour l'exception nominale
    // Singapore/Orchard Road dans `_isTripLevelDedupEligible`.
    final effectiveMetroForCluster =
        clusterMetroProfile ?? tripDestinationMetro;

    for (final day in cluster.days) {
      // V8.20 (Day Builder) — pack thématique éventuel pour ce jour.
      // Si non null, restreint le pool slot picker aux placeIds du pack.
      final dayPack = dayBuilder.dayPackByDate[day];
      final dayPackPlaceIds = dayPack?.placeIds;
      // V8.21 (anti-zigzag slot-level) — compteur de transitions longues
      // depuis lastActivity. Hard cap 1 par jour (>5 km) + cap dur 10 km
      // sur un seul hop (Chatuchak↔Srinagarindra à 16 km bloqué).
      // S'applique TOUJOURS, même quand Day Builder n'a pas assigné de
      // pack (cas central cluster Bangkok où archétypes rejetés). Ne
      // s'active qu'après la 1ʳᵉ activité du jour (lastActivity != null).
      var longTransitionsThisDay = 0;
      // V8.28b1.3 (Lalith 2026-05-11) — caps fallback mégalopole
      // (5 km / 0 long hop) via helper publique testable. Évite
      // zigzags type Chinatown → Sentosa → Orchard (Singapour
      // 22/05). En mode pack curé OU hors mégalopole : V8.21 default
      // (10 km / 1 long hop). Cf. `fallbackTransitionCapsForDay`.
      final transitionCaps = fallbackTransitionCapsForDay(
        clusterMetroProfile: clusterMetroProfile,
        hasDayPack: dayPackPlaceIds != null,
      );
      final maxSingleTransitionKm = transitionCaps.maxSingleTransitionKm;
      final maxLongTransitionsPerDay = transitionCaps.maxLongTransitionsPerDay;
      const longTransitionThresholdKm = 5.0;
      // V8.23 (Lalith 2026-05-10 — coherence guard slot-level) — après
      // 2 picks, le barycentre des picks du jour définit la zone du
      // jour. Les picks suivants doivent rester dans un rayon 5 km de
      // ce barycentre. Évite le 4ᵉ pick « rempli pour remplir » qui
      // casse la cohérence éditoriale (cas observé Bangkok 06-28 :
      // Chinatown + ICONSIAM + Asiatique + Wat Bang Na Nok à 9.6 km
      // hors zone). 5 km aligne avec le seuil long-transition.
      // Le 1er et 2ᵉ pick ne sont pas contraints par centroid (le
      // hard cap distance 10 km de l'anti-zigzag s'applique).
      final dayPickLats = <double>[];
      final dayPickLngs = <double>[];
      const dayCoherenceRadiusKm = 5.0;
      // V8.26 (Lalith 2026-05-10 — second-pick guard fallback) — quand
      // aucun pack n'est assigné (slot picker libre), cap 5 km entre
      // 1ᵉʳ et 2ᵉ pick. Empêche les duos incohérents type Chatuchak +
      // Khaosan (6 km) ou Asiatique + Train Night Market Ratchada
      // (8.4 km). En mode pack, la restriction au pack suffit (pack
      // est déjà curé géo + archétype).
      const secondPickRadiusFallbackKm = 5.0;
      final usedThisDay = <String>{};
      var wellnessCountThisDay = 0;
      var eventsCountThisDay = 0;
      // V8.9 (Q1B) — cap 2 « majors » par jour. Évite la journée
      // bourrée de must-see (Statue Liberty + Empire State + 9/11
      // Memorial + Brooklyn Bridge à enchaîner = irréaliste).
      var majorCountThisDay = 0;
      // Phase 2 / Tâche 2.4 — compteur `same_complex` par jour
      // (reset à chaque nouveau jour). Trip-wide compteur initialisé
      // en haut de fonction (`complexCountAcrossTrip`).
      final complexCountThisDay = <String, int>{};
      // Indique si la demi-journée précédente du même jour a déjà un
      // wellness pick (sert au soft penalty quand Wellness est intérêt fort).
      var lastHalfDayHadWellness = false;
      // 2026-05-08 calibrage #1 : compteur par TAG dans la journée (Culture,
      // Activité, Nature, Visite…). Sert à appliquer une soft penalty -10 ×
      // count dans le scoring → casse les enchaînements 4× Culture observés
      // sur Meilleur prix / Couple. Diff avec `usedThisDay` (par-lieu) :
      // ce compteur est PAR TAG et autorise diversité même quand le pool
      // est riche en lieux du même type.
      final tagCountThisDay = <String, int>{};
      ActivitySuggestion? lastActivity;

      for (final slot in slots) {
        // Ancrage : activité précédente du jour, ou centre du cluster pour le 1er slot.
        final anchorLat = lastActivity?.latitude ?? cluster.center.latitude;
        final anchorLng = lastActivity?.longitude ?? cluster.center.longitude;

        // Filtres durs (sans distance pour le moment)
        final baseCandidates = entries.where((e) {
          final c = e.value.candidate;
          // V8.20 (Day Builder) — restreint au pack thématique du jour
          // si un pack est assigné. Le slot picker continue d'appliquer
          // sa logique de scoring/dedup à l'intérieur du pack restreint.
          if (dayPackPlaceIds != null && !dayPackPlaceIds.contains(c.placeId)) {
            return false;
          }
          // V8.28f (Lalith 2026-05-11) — quality floor fallback. En
          // mode fallback (pas de day pack), sur mégalopole avec
          // MetroProfile curated, exige qu'un candidat soit
          // « qualifié » : marker blueprint (must-see/experience) OU
          // marker metro anchor OU pattern match d'une zone du
          // MetroProfile. Sinon → reject. Empêche fillers Bang Na
          // (Imperial World, Ton Sai Market, Wat Bang Na Nok),
          // Tokyo locaux (Kimono Hazuki, Private Thai Massage,
          // yuenbettei daita, petits parcs) de remonter dans les
          // jours sans pack. User explicit : « journée libre plutôt
          // qu'incohérente ».
          if (dayPackPlaceIds == null && clusterMetroProfile != null) {
            if (!isMetroQualifiedCandidate(
              c,
              clusterMetroProfile,
              e.value.matchedInterests,
            )) {
              return false;
            }
          }
          // V8.28b1.3 (Lalith 2026-05-11) — dédup trip-level pour
          // les iconiques. Évite Buddha Tooth Relic Temple /
          // Sentosa / Orchard Road picked sur 2 jours différents
          // dans le même voyage Singapour. Le check est placeId-
          // based (via `_dedupKeyForCandidate`) et seulement actif
          // pour les candidats éligibles (cf.
          // `_isTripLevelDedupEligible` : iconic museum/tourist,
          // metro anchor, exception Singapore/Orchard Road).
          if (_isTripLevelDedupEligible(
                c,
                e.value.matchedInterests,
                effectiveMetroForCluster,
              ) &&
              iconicSelectedAcrossTrip.contains(_dedupKeyForCandidate(c))) {
            return false;
          }
          // V8.21 (anti-zigzag slot-level) — hard cap depuis la dernière
          // activité du jour. Empêche Chatuchak (13.80, 100.55) suivi
          // de Train Night Market Srinagarindra (13.69, 100.65) à 16 km.
          // Et empêche un 2ᵉ long hop si le 1er a déjà eu lieu.
          final lastLat = lastActivity?.latitude;
          final lastLng = lastActivity?.longitude;
          if (lastLat != null && lastLng != null) {
            final dKm = _haversineKmBetween(
              lastLat,
              lastLng,
              c.latitude,
              c.longitude,
            );
            if (dKm > maxSingleTransitionKm) return false;
            if (longTransitionsThisDay >= maxLongTransitionsPerDay &&
                dKm > longTransitionThresholdKm) {
              return false;
            }
          }
          // V8.23 (coherence guard) — après 2 picks, le candidat doit
          // rester dans 5 km du barycentre du jour. Évite Wat Bang Na
          // Nok à 9.6 km de la zone Chinatown/ICONSIAM/Asiatique.
          if (dayPickLats.length >= 2) {
            final centroidLat =
                dayPickLats.reduce((a, b) => a + b) / dayPickLats.length;
            final centroidLng =
                dayPickLngs.reduce((a, b) => a + b) / dayPickLngs.length;
            final dCentroidKm = _haversineKmBetween(
              centroidLat,
              centroidLng,
              c.latitude,
              c.longitude,
            );
            if (dCentroidKm > dayCoherenceRadiusKm) return false;
          }
          // V8.26 (second-pick guard fallback) — cap 5 km depuis le
          // 1ᵉʳ pick quand aucun pack n'est assigné. Empêche Chatuchak +
          // Khaosan (6 km) ou Asiatique + Ratchada Train Night Market
          // (8.4 km). En mode pack, le pack lui-même garantit la
          // cohérence zone.
          if (dayPickLats.length == 1 && dayPackPlaceIds == null) {
            final dFirstKm = _haversineKmBetween(
              dayPickLats[0],
              dayPickLngs[0],
              c.latitude,
              c.longitude,
            );
            if (dFirstKm > secondPickRadiusFallbackKm) return false;
          }
          if (!_isAppropriateForTime(
            c,
            slot,
            matchedInterests: e.value.matchedInterests.toSet(),
          )) {
            return false;
          }
          if (_isMealPrimaryType(c)) return false;
          // Cap budget : lieu trop cher par rapport au budget user.
          // Garde les lieux sans priceLevel (Google le manque souvent).
          if (budgetPriceCap != null &&
              c.priceLevel != null &&
              c.priceLevel! > budgetPriceCap) {
            return false;
          }
          final n = norm(c.name);
          if (existingTitlesNormalized.contains(n)) return false;
          // Rejet "nom = ville segment" : élimine les pages touristiques
          // génériques qui ont le nom de la ville (ex: "Épinal" tagué
          // tourist_attraction).
          if (cityNamesNorm.contains(n)) return false;
          // Cap dur global : un même lieu ne peut apparaître qu'une seule
          // fois dans tout le voyage. Évite "Plage d'Essaouira" pickée le
          // 15/05 ET le 17/05 (cas observé Lalith 2026-05-08). Clé =
          // placeId si présent, sinon fallback name+coords arrondies.
          if (selectedDedupKeys.contains(_dedupKeyForCandidate(c))) {
            return false;
          }
          // Cap par jour : interdiction stricte de prendre le même lieu 2 fois
          // sur la même journée. Évite Bergeret Building 10:00 ET 14:30.
          if (usedThisDay.contains(n)) return false;
          // Cap par cluster : autorise jusqu'à `maxReusePerCluster` fois le
          // même lieu sur l'ensemble du cluster (jours différents).
          if ((useCountThisCluster[n] ?? 0) >= maxReusePerCluster) return false;
          // Hard cap voyage = 1× pour les lieux iconiques (musées ≥200 avis,
          // monuments ≥500 avis). Le scoring -50/usage trip ne suffisait pas
          // (Muséum-Aquarium qualité 37 + bonus +6 vs alternatives <25 →
          // toujours repris en J6 après J1). Lalith 26/04 : iconic = 1×/voyage.
          final reviewN = c.userRatingCount ?? 0;
          final isIconicMuseum =
              reviewN >= 200 &&
              (c.types.contains('museum') ||
                  c.types.contains('art_museum') ||
                  c.types.contains('art_gallery'));
          final isIconicTourist =
              reviewN >= 500 &&
              (c.types.contains('tourist_attraction') ||
                  c.types.contains('historical_landmark') ||
                  c.types.contains('monument') ||
                  c.types.contains('landmark'));
          if ((isIconicMuseum || isIconicTourist) &&
              (useCountAcrossTrip[n] ?? 0) >= 1) {
            return false;
          }
          // V8.6 — Cap densité Wellness durci :
          //   - 1/jour (jamais 2, même profil tolérant).
          //   - max 1 wellness par 7 jours de voyage.
          //   - hard cap 3 trip-wide.
          // Cf. `tripWideWellnessCap` calculé en début de fonction.
          if (_isWellnessPrimaryType(c)) {
            if (wellnessCountThisDay >= maxWellnessPerDay) {
              rejectedByWellnessCap++;
              return false;
            }
            if (wellnessCountTripWide >= tripWideWellnessCap) {
              rejectedByWellnessCap++;
              return false;
            }
          }
          // V8.9 (Q1B) — cap 2 majors par jour.
          if (_isMajorTouristPlace(c) &&
              majorCountThisDay >= _qualityMaxMajorsPerDay) {
            rejectedByMajorsCap++;
            return false;
          }
          // Cap densité Événements (miroir Wellness, 2026-05-08 #4).
          if (_isEventsPrimaryType(c)) {
            final dayCap = eventsIsStrongInterest
                ? maxEventsPerDayTolerant
                : maxEventsPerDayLight;
            if (eventsCountThisDay >= dayCap) return false;
            if (!eventsIsStrongInterest &&
                eventsCountThisCluster >= maxEventsPerClusterLight) {
              return false;
            }
          }
          // Phase 2 / Tâche 2.4 — cap `SameComplexGroup` (flag-gated).
          // Quand le flag est OFF ou que la liste est vide, ce bloc
          // est totalement court-circuité (`complexDedupActive ==
          // false`) → comportement identique au pré-2.4.
          if (complexDedupActive) {
            final complexMatch = matchComplexDetailed(
              name: c.name,
              placeId: c.placeId,
              groups: complexGroups,
            );
            if (complexMatch != null) {
              final groupForCandidate = complexGroups.firstWhere(
                (g) => g.complexKey == complexMatch.complexKey,
              );
              final currentDayCount =
                  complexCountThisDay[complexMatch.complexKey] ?? 0;
              if (currentDayCount >= groupForCandidate.maxPerDay) {
                final rej = SameComplexRejection(
                  candidateTitle: c.name,
                  complexKey: complexMatch.complexKey,
                  reason: SameComplexRejection.reasonCapDay,
                  dayDate: day,
                  currentCount: currentDayCount,
                  maxAllowed: groupForCandidate.maxPerDay,
                );
                sameComplexRejectionsOut?.add(rej);
                // ignore: avoid_print
                print(
                  '[places_complex_dedup_reject] '
                  'name="${c.name}" '
                  'complex=${complexMatch.complexKey} '
                  'strategy=${complexMatch.strategy.name} '
                  'reason=${rej.reason} '
                  'day=${day.toIso8601String().split("T").first} '
                  'count=$currentDayCount/${groupForCandidate.maxPerDay}',
                );
                return false;
              }
              final currentTripCount =
                  complexCountAcrossTrip[complexMatch.complexKey] ?? 0;
              if (currentTripCount >= groupForCandidate.maxPerTrip) {
                final rej = SameComplexRejection(
                  candidateTitle: c.name,
                  complexKey: complexMatch.complexKey,
                  reason: SameComplexRejection.reasonCapTrip,
                  dayDate: day,
                  currentCount: currentTripCount,
                  maxAllowed: groupForCandidate.maxPerTrip,
                );
                sameComplexRejectionsOut?.add(rej);
                // ignore: avoid_print
                print(
                  '[places_complex_dedup_reject] '
                  'name="${c.name}" '
                  'complex=${complexMatch.complexKey} '
                  'strategy=${complexMatch.strategy.name} '
                  'reason=${rej.reason} '
                  'day=${day.toIso8601String().split("T").first} '
                  'count=$currentTripCount/${groupForCandidate.maxPerTrip}',
                );
                return false;
              }
            }
          }
          return true;
        }).toList();

        if (baseCandidates.isEmpty) {
          // Diagnostic : pourquoi aucun candidat ne passe les filtres durs ?
          var rejectTime = 0, rejectMeal = 0, rejectExisting = 0;
          var rejectCity = 0, rejectDay = 0, rejectReuse = 0, rejectIconic = 0;
          var rejectDup = 0, rejectWellness = 0, rejectEvents = 0;
          var rejectDayPack = 0;
          var rejectAntiZigzag = 0;
          var rejectCoherenceGuard = 0;
          var rejectSecondPickGuard = 0;
          var rejectQualityFloor = 0;
          var rejectIconicTripDedup = 0;
          var rejectSameComplexCap = 0;
          for (final e in entries) {
            final c = e.value.candidate;
            // V8.20 (Day Builder) — comptabilise les rejets par filtre pack.
            if (dayPackPlaceIds != null &&
                !dayPackPlaceIds.contains(c.placeId)) {
              rejectDayPack++;
              continue;
            }
            // V8.28f (quality floor fallback) — miroir du filtre.
            if (dayPackPlaceIds == null && clusterMetroProfile != null) {
              if (!isMetroQualifiedCandidate(
                c,
                clusterMetroProfile,
                e.value.matchedInterests,
              )) {
                rejectQualityFloor++;
                continue;
              }
            }
            // V8.28b1.3 — dédup trip-level iconique : miroir du filtre.
            if (_isTripLevelDedupEligible(
                  c,
                  e.value.matchedInterests,
                  effectiveMetroForCluster,
                ) &&
                iconicSelectedAcrossTrip.contains(_dedupKeyForCandidate(c))) {
              rejectIconicTripDedup++;
              continue;
            }
            // V8.21 (anti-zigzag slot-level) — miroir du filtre.
            final lastLat = lastActivity?.latitude;
            final lastLng = lastActivity?.longitude;
            if (lastLat != null && lastLng != null) {
              final dKm = _haversineKmBetween(
                lastLat,
                lastLng,
                c.latitude,
                c.longitude,
              );
              if (dKm > maxSingleTransitionKm ||
                  (longTransitionsThisDay >= maxLongTransitionsPerDay &&
                      dKm > longTransitionThresholdKm)) {
                rejectAntiZigzag++;
                continue;
              }
            }
            // V8.23 (coherence guard) — miroir du filtre.
            if (dayPickLats.length >= 2) {
              final centroidLat =
                  dayPickLats.reduce((a, b) => a + b) / dayPickLats.length;
              final centroidLng =
                  dayPickLngs.reduce((a, b) => a + b) / dayPickLngs.length;
              final dCentroidKm = _haversineKmBetween(
                centroidLat,
                centroidLng,
                c.latitude,
                c.longitude,
              );
              if (dCentroidKm > dayCoherenceRadiusKm) {
                rejectCoherenceGuard++;
                continue;
              }
            }
            // V8.26 (second-pick guard fallback) — miroir du filtre.
            if (dayPickLats.length == 1 && dayPackPlaceIds == null) {
              final dFirstKm = _haversineKmBetween(
                dayPickLats[0],
                dayPickLngs[0],
                c.latitude,
                c.longitude,
              );
              if (dFirstKm > secondPickRadiusFallbackKm) {
                rejectSecondPickGuard++;
                continue;
              }
            }
            if (!_isAppropriateForTime(
              c,
              slot,
              matchedInterests: e.value.matchedInterests.toSet(),
            )) {
              rejectTime++;
              continue;
            }
            if (_isMealPrimaryType(c)) {
              rejectMeal++;
              continue;
            }
            final n = norm(c.name);
            if (existingTitlesNormalized.contains(n)) {
              rejectExisting++;
              continue;
            }
            if (cityNamesNorm.contains(n)) {
              rejectCity++;
              continue;
            }
            if (selectedDedupKeys.contains(_dedupKeyForCandidate(c))) {
              rejectDup++;
              continue;
            }
            if (usedThisDay.contains(n)) {
              rejectDay++;
              continue;
            }
            if ((useCountThisCluster[n] ?? 0) >= maxReusePerCluster) {
              rejectReuse++;
              continue;
            }
            final reviewN = c.userRatingCount ?? 0;
            final isIconicMuseum =
                reviewN >= 200 &&
                (c.types.contains('museum') ||
                    c.types.contains('art_museum') ||
                    c.types.contains('art_gallery'));
            final isIconicTourist =
                reviewN >= 500 &&
                (c.types.contains('tourist_attraction') ||
                    c.types.contains('historical_landmark') ||
                    c.types.contains('monument') ||
                    c.types.contains('landmark'));
            if ((isIconicMuseum || isIconicTourist) &&
                (useCountAcrossTrip[n] ?? 0) >= 1) {
              rejectIconic++;
              continue;
            }
            if (_isWellnessPrimaryType(c)) {
              // V8.6 — diagnostic miroir du cap durci ci-dessus.
              if (wellnessCountThisDay >= maxWellnessPerDay ||
                  wellnessCountTripWide >= tripWideWellnessCap) {
                rejectWellness++;
                continue;
              }
            }
            if (_isEventsPrimaryType(c)) {
              final dayCap = eventsIsStrongInterest
                  ? maxEventsPerDayTolerant
                  : maxEventsPerDayLight;
              final clusterExceeded =
                  !eventsIsStrongInterest &&
                  eventsCountThisCluster >= maxEventsPerClusterLight;
              if (eventsCountThisDay >= dayCap || clusterExceeded) {
                rejectEvents++;
                continue;
              }
            }
            // Phase 2 / Tâche 2.4 — miroir du cap SameComplexGroup.
            if (complexDedupActive) {
              final complexMatch = matchComplexDetailed(
                name: c.name,
                placeId: c.placeId,
                groups: complexGroups,
              );
              if (complexMatch != null) {
                final groupForCandidate = complexGroups.firstWhere(
                  (g) => g.complexKey == complexMatch.complexKey,
                );
                final dayCount =
                    complexCountThisDay[complexMatch.complexKey] ?? 0;
                final tripCount =
                    complexCountAcrossTrip[complexMatch.complexKey] ?? 0;
                if (dayCount >= groupForCandidate.maxPerDay ||
                    tripCount >= groupForCandidate.maxPerTrip) {
                  rejectSameComplexCap++;
                  continue;
                }
              }
            }
          }
          // Identifie la raison principale (= catégorie qui a le compteur le
          // plus élevé). Sert au debug rapide depuis le harness/logs.
          final rejects = <String, int>{
            'no_candidates_in_pool': entries.isEmpty ? 1 : 0,
            'rejected_by_time': rejectTime,
            'rejected_by_type_meal': rejectMeal,
            'rejected_by_existing': rejectExisting,
            'rejected_by_city_name': rejectCity,
            'rejected_by_dedup': rejectDup,
            'rejected_by_day_dup': rejectDay,
            'rejected_by_reuse_cap': rejectReuse,
            'rejected_by_iconic_cap': rejectIconic,
            'rejected_by_wellness_cap': rejectWellness,
            'rejected_by_events_cap': rejectEvents,
            'rejected_by_day_pack': rejectDayPack,
            'rejected_by_anti_zigzag': rejectAntiZigzag,
            'rejected_by_coherence_guard': rejectCoherenceGuard,
            'rejected_by_second_pick_guard': rejectSecondPickGuard,
            'rejected_by_quality_floor': rejectQualityFloor,
            'rejected_by_iconic_trip_dedup': rejectIconicTripDedup,
            'rejected_by_same_complex_cap': rejectSameComplexCap,
          };
          final sortedRejects =
              rejects.entries.where((e) => e.value > 0).toList()
                ..sort((a, b) => b.value.compareTo(a.value));
          final primaryReason = sortedRejects.isEmpty
              ? 'unknown'
              : sortedRejects.first.key;
          final centerLat = cluster.center.latitude.toStringAsFixed(2);
          final centerLng = cluster.center.longitude.toStringAsFixed(2);
          debugPrint(
            '[places_first_skip_visit] date=${day.toIso8601String().split("T").first} '
            'slot=$slot center=${cluster.center.source}@$centerLat,$centerLng '
            'raw=${entries.length} filtered=0 '
            'reason=$primaryReason '
            'breakdown={${sortedRejects.map((e) => "${e.key}:${e.value}").join(",")}}',
          );
          continue;
        }

        // Cascade unconstrained (Lalith 26/04) : pas de filtre dur sur la
        // distance, le scoring fait le tri. Sinon on rate Saint Mary Park
        // (★4.6, 3857 avis) à 800m parce que strict 300m s'arrête au 1er
        // candidat trouvé (Bergeret à 200m). Avec scoring, Saint Mary Park
        // (qualité 38 - distancePenalty 13) bat Bergeret (qualité 21).
        // Le tier réel est calculé après le pick pour annoter match_reason.
        final candidates = baseCandidates;

        // Scoring : qualité + intérêt matché - distance - diversité.
        // La pénalité diversité (Lalith 26/04) est CRITIQUE : sans elle, le
        // 2e jour d'un cluster reprend les top du 1er jour (cap=2 le permet)
        // → J1=J3, J7=J8 vu en test. Avec un malus -30 pour chaque utilisation
        // déjà faite, le 2e usage d'un lieu chute en dessous des autres top
        // qui sont eux à useCount=0. Force la variation jour-à-jour naturelle.
        double score(
          MapEntry<
            String,
            ({NearbyCandidate candidate, List<String> matchedInterests})
          >
          e,
        ) {
          final c = e.value.candidate;
          final r = c.rating ?? 0;
          final reviews = c.userRatingCount ?? 0;
          final qualityScore = r * (reviews <= 1 ? 1 : math.log(reviews));
          final matchSet = e.value.matchedInterests.toSet();
          final intersectionCount = matchSet.intersection(tripInterests).length;
          final interestBonus = intersectionCount * 3.0;
          final d = math.sqrt(
            _distSqMeters(
              (lat: c.latitude, lng: c.longitude),
              (lat: anchorLat, lng: anchorLng),
            ),
          );
          // V8.13 (Quality-1D) — détection blueprint must-see/experience
          // depuis les markers synthétiques injectés en gather (réutilise
          // `matchSet` calculé au-dessus pour `interestBonus`). Sert au
          // score boost ET à plafonner la distance penalty (sinon un
          // must-see iconique à 4 km perdrait vs un filler à 200 m).
          final isBlueprintMustSee = matchSet.contains(blueprintMustSeeMarker);
          final isBlueprintExperience = matchSet.contains(
            blueprintExperienceMarker,
          );
          // Distance penalty renforcée — décourage les transitions longues.
          // 2026-05-08 calibrage #3 : multiplicateur dérivé du
          // transportDistanceFactor (walk ≈ ×11.4, taxi ≈ ×5.3, etc.).
          // V8.13 — must-sees iconiques cappées à 30 (ne peuvent pas
          // être éliminés par la seule distance). Experiences gardent
          // 50% de la pénalité (priorisées mais sensibles à la distance
          // pour un meilleur clustering géo).
          var distancePenalty = (d / maxConsec) * distancePenaltyMultiplier;
          if (isBlueprintMustSee) {
            distancePenalty = math.min(distancePenalty, 30.0);
          } else if (isBlueprintExperience) {
            distancePenalty = distancePenalty * 0.5;
          }
          final keyN = norm(c.name);
          final clusterUseCount = useCountThisCluster[keyN] ?? 0;
          final tripUseCount = useCountAcrossTrip[keyN] ?? 0;
          // -50 par usage voyage (boost Lalith 26/04) : évite J6 reprenant
          // Muséum-Aquarium (qualité 37, déjà 1× en J1) parce que les lieux
          // jamais utilisés du cluster avaient un score < 25 = -25 + 0
          // (penalty trip insuffisante). Avec -50, Muséum chute à -13 et
          // laisse la place aux nouveaux lieux.
          final diversityPenalty = clusterUseCount * 30.0 + tripUseCount * 50.0;
          // Bonus musée iconique : museum/art_museum/art_gallery + ≥200 avis.
          final hasMuseumType =
              c.types.contains('museum') ||
              c.types.contains('art_museum') ||
              c.types.contains('art_gallery');
          final reviewCount = c.userRatingCount ?? 0;
          final iconicMuseumBonus = (hasMuseumType && reviewCount >= 200)
              ? 10.0
              : 0.0;
          // Bonus monument touristique populaire : tourist_attraction,
          // historical_landmark ou monument avec ≥500 avis. Couvre Place
          // Stanislas (36899 avis), Bahia Palace, Brasserie Excelsior, etc.
          final hasIconicTouristType =
              c.types.contains('tourist_attraction') ||
              c.types.contains('historical_landmark') ||
              c.types.contains('monument') ||
              c.types.contains('landmark');
          final iconicTouristBonus =
              (hasIconicTouristType && reviewCount >= 500) ? 6.0 : 0.0;
          // Soft penalty wellness consécutif (même demi-journée). Actif
          // uniquement quand Wellness est intérêt fort (sinon le hard cap
          // ci-dessus a déjà filtré). -25 pousse vers une autre activité
          // sans bloquer dur si la pool n'a rien d'autre.
          final wellnessConsecutivePenalty =
              (wellnessIsStrongInterest &&
                  lastHalfDayHadWellness &&
                  _isWellnessPrimaryType(c))
              ? 25.0
              : 0.0;
          // 2026-05-08 calibrage #1 : pénalité diversité PAR TAG dans la
          // journée. -10 par occurrence du même tag déjà pické. Casse les
          // 4× Culture consécutifs observés sur Meilleur prix / Couple.
          // Force la rotation tags sans bloquer dur (un tag dominant peut
          // toujours gagner si l'écart de qualité > 10 × count).
          final candidateTag = _tagFromPrimaryType(
            c.types.isNotEmpty ? c.types.first : '',
          );
          final sameTagCountInDay = tagCountThisDay[candidateTag] ?? 0;
          final tagDiversityPenalty = sameTagCountInDay * 10.0;
          // V8.13 (Quality-1D) — bonus blueprint must-see/experience.
          // Échelle pensée pour DOMINER les autres signaux :
          //   +100 must-see > tout filler nearby (un must-see à
          //   rating 4 / 1000 reviews fait ~28 base score → avec +100
          //   = 128 vs un filler à rating 4.5 / 5000 reviews ~38).
          //   +70 experience reste largement au-dessus mais cède
          //   place aux must-sees iconiques de la même journée.
          final blueprintBonus = isBlueprintMustSee
              ? 100.0
              : (isBlueprintExperience ? 70.0 : 0.0);
          return qualityScore +
              interestBonus +
              iconicMuseumBonus +
              iconicTouristBonus +
              blueprintBonus -
              distancePenalty -
              diversityPenalty -
              wellnessConsecutivePenalty -
              tagDiversityPenalty;
        }

        candidates.sort((a, b) => score(b).compareTo(score(a)));
        final pick = candidates.first.value.candidate;
        final matched = candidates.first.value.matchedInterests;
        final pickName = norm(pick.name);

        // Construction de l'activité.
        // Le `tag` (affiché à l'user) est dérivé du primary Place type, pas
        // de l'intérêt matché — pour éviter "Pâtisserie Driss [Shopping]
        // Matche 'Culture'" (incohérent). Le tag reflète CE QU'EST le lieu,
        // l'intérêt matché reflète POURQUOI on l'a remonté.
        final tag = _tagFromPrimaryType(
          pick.types.isNotEmpty ? pick.types.first : '',
        );
        // Durée selon type : musée 90, monument 60, parc 60, par défaut 75.
        final duration = _defaultDurationForType(
          pick.types.isNotEmpty ? pick.types.first : '',
        );
        final dM = math
            .sqrt(
              _distSqMeters(
                (lat: pick.latitude, lng: pick.longitude),
                (lat: anchorLat, lng: anchorLng),
              ),
            )
            .round();
        final priceLabel = _priceLabelFromLevel(pick.priceLevel);
        // match_reason par template — pas Gemini. Format : intérêt matché +
        // qualité + distance depuis l'activité précédente.
        // On ne mentionne l'intérêt matché que s'il est COHÉRENT avec le tag
        // (ex: tag=Wellness + Matche 'Wellness' OK ; tag=Shopping + Matche
        // 'Culture' incohérent, on omet). Évite les "Pâtisserie [Shopping]
        // Matche 'Culture'" surprenants pour l'user.
        final reasonParts = <String>[];
        final matchedTrip = matched.toSet().intersection(tripInterests);
        final coherentInterest = matchedTrip.firstWhere(
          (i) => _isInterestCoherentWithTag(i, tag),
          orElse: () => '',
        );
        if (coherentInterest.isNotEmpty) {
          reasonParts.add("Matche '$coherentInterest'");
        }
        reasonParts.add('★${pick.rating} (${pick.userRatingCount ?? 0} avis)');
        if (lastActivity != null) {
          // Annotation mode transport selon distance vs maxConsec profil :
          // ≤ 1× : marche normale, juste la distance.
          // 1× - 1.5× : marche un peu plus longue, signalée.
          // 1.5× - 2.5× : transport public conseillé (bus, tram).
          // > 2.5× : taxi/voiture conseillé (Senior fatigué, distance trop).
          final ratio = dM / maxConsec;
          final distLabel = ratio <= 1.0
              ? '${dM}m'
              : ratio <= 1.5
              ? '${dM}m (un peu loin)'
              : ratio <= 2.5
              ? '🚌 ${dM}m · transport public conseillé'
              : '🚕 ${dM}m · taxi/voiture conseillé';
          reasonParts.add('$distLabel depuis "${lastActivity.title}"');
        }
        // Log diagnostique de chaque pick final : permet d'identifier les Places
        // mal géocodés par Google (ex: "Parc du Château" Épinal qui pointe sur
        // 26 rue Saint Michel = adresse du Château d'Épinal voisin). Sortie
        // ciblée (40 picks max par voyage), le placeId permettra de blacklister
        // manuellement via `_blacklistedPlaceIds` si besoin.
        debugPrint(
          '[places_first_pick] ${day.toIso8601String().split("T").first} $slot '
          'tag=$tag → "${pick.name}" placeId=${pick.placeId} '
          'addr="${pick.address}" types=[${pick.types.take(3).join(",")}] '
          '@${pick.latitude.toStringAsFixed(4)},${pick.longitude.toStringAsFixed(4)}',
        );
        out.add(
          ActivitySuggestion(
            dayDate: day,
            startTime: slot,
            title: pick.name,
            detail: pick.address,
            tag: tag,
            durationMinutes: duration,
            priceEstimate: priceLabel,
            matchReason: reasonParts.join(' · '),
            latitude: pick.latitude,
            longitude: pick.longitude,
          ),
        );
        useCountThisCluster[pickName] =
            (useCountThisCluster[pickName] ?? 0) + 1;
        useCountAcrossTrip[pickName] = (useCountAcrossTrip[pickName] ?? 0) + 1;
        usedThisDay.add(pickName);
        selectedDedupKeys.add(_dedupKeyForCandidate(pick));
        // V8.28b1.3 — enregistre placeId du pick dans le set
        // trip-level si éligible iconique (cf. helper). Bloque le
        // re-pick cross-cluster (Buddha Tooth Relic Temple / Sentosa /
        // Orchard Road dupliqués observés Singapour).
        if (_isTripLevelDedupEligible(
          pick,
          matched,
          effectiveMetroForCluster,
        )) {
          iconicSelectedAcrossTrip.add(_dedupKeyForCandidate(pick));
        }
        tagCountThisDay[tag] = (tagCountThisDay[tag] ?? 0) + 1;
        if (_isEventsPrimaryType(pick)) {
          eventsCountThisDay += 1;
          eventsCountThisCluster += 1;
        }
        // V8.9 (Q1B) — increment majors count si pick = major tourist.
        if (_isMajorTouristPlace(pick)) {
          majorCountThisDay += 1;
        }
        if (_isWellnessPrimaryType(pick)) {
          wellnessCountThisDay += 1;
          wellnessCountTripWide += 1;
          // Demi-journée matin = avant 13h, aprem = après. On marque le
          // flag actif si le pick courant est wellness pour pénaliser le
          // pick suivant *du même jour* (le flag est reset à chaque jour
          // via la déclaration `var lastHalfDayHadWellness = false`).
          lastHalfDayHadWellness = true;
        } else {
          // Pick non-wellness : on relâche le flag pour laisser le
          // prochain wellness éventuel passer sans pénalité dans la
          // demi-journée suivante.
          lastHalfDayHadWellness = false;
        }
        // V8.21 (anti-zigzag) — incrémente le compteur du jour si le hop
        // depuis l'activité précédente dépasse le seuil long. Compteur
        // strictement croissant, jamais reset intra-jour.
        final lastLatBefore = lastActivity?.latitude;
        final lastLngBefore = lastActivity?.longitude;
        if (lastLatBefore != null && lastLngBefore != null) {
          final hopKm = _haversineKmBetween(
            lastLatBefore,
            lastLngBefore,
            pick.latitude,
            pick.longitude,
          );
          if (hopKm > longTransitionThresholdKm) {
            longTransitionsThisDay += 1;
          }
        }
        // V8.23 (coherence guard) — append coords pour recalculer le
        // barycentre du jour à la prochaine itération du slot loop.
        dayPickLats.add(pick.latitude);
        dayPickLngs.add(pick.longitude);
        lastActivity = out.last;
        // Phase 2 / Tâche 2.4 — incrément compteurs same-complex.
        // Strictement no-op quand le flag est OFF (court-circuit via
        // `complexDedupActive`).
        if (complexDedupActive) {
          final pickComplexKey = matchComplex(
            name: pick.name,
            placeId: pick.placeId,
            groups: complexGroups,
          );
          if (pickComplexKey != null) {
            complexCountThisDay[pickComplexKey] =
                (complexCountThisDay[pickComplexKey] ?? 0) + 1;
            complexCountAcrossTrip[pickComplexKey] =
                (complexCountAcrossTrip[pickComplexKey] ?? 0) + 1;
          }
        }
      }
    }
  }
  debugPrint(
    '[places_first] Sélecteur déterministe : ${out.length} visites sélectionnées '
    '(${filteredClusters.length} clusters × max $maxPerDay/jour)',
  );
  // V8.7 (Lalith 2026-05-10 — Quality-1A v4) — selector summary
  // enrichi avec la ventilation du final gate. `print` non throttlé.
  // Volume = 1 ligne par run.
  final finalGateTotal = finalGateCounts.values.fold<int>(0, (s, v) => s + v);
  if (rejectedByWellnessCap > 0 ||
      finalGateTotal > 0 ||
      rejectedByMajorsCap > 0) {
    // ignore: avoid_print
    print(
      '[places_selector_summary] tripId=${trip.id} '
      'selected=${out.length} '
      'rejectedByFinalQuality=$finalGateTotal '
      'rejectedByBlockedType=${finalGateCounts['blocked_type'] ?? 0} '
      'rejectedByBlockedLodging=${finalGateCounts['blocked_lodging'] ?? 0} '
      'rejectedByBlockedTitle=${finalGateCounts['blocked_title'] ?? 0} '
      'rejectedByBlockedAddress=${finalGateCounts['blocked_address'] ?? 0} '
      'rejectedByOutOfCountry=${finalGateCounts['out_of_country'] ?? 0} '
      'rejectedByRestaurantOutOfScope=${finalGateCounts['restaurant_out_of_scope'] ?? 0} '
      'rejectedByWeakEvent=${finalGateCounts['weak_event'] ?? 0} '
      'rejectedByLowReviews=${(finalGateCounts['low_reviews'] ?? 0) + (finalGateCounts['high_rating_few_reviews'] ?? 0)} '
      'rejectedByLowRating=${finalGateCounts['low_rating'] ?? 0} '
      'rejectedByGenericPoi=${finalGateCounts['generic_poi'] ?? 0} '
      'rejectedByWellnessNotInInterests=${finalGateCounts['wellness_not_in_interests'] ?? 0} '
      'rejectedByNightlifeNotInInterests=${finalGateCounts['nightlife_not_in_interests'] ?? 0} '
      'rejectedByWellnessCap=$rejectedByWellnessCap '
      'rejectedByMajorsCap=$rejectedByMajorsCap '
      'tripWideWellnessCap=$tripWideWellnessCap',
    );
  }
  return out;
}

/// Durée par défaut en minutes selon primary type Places.
int _defaultDurationForType(String primaryType) {
  if (primaryType.contains('museum') ||
      primaryType == 'art_gallery' ||
      primaryType == 'aquarium' ||
      primaryType == 'zoo') {
    return 90;
  }
  if (primaryType.contains('park') || primaryType == 'botanical_garden') {
    return 60;
  }
  if (primaryType == 'church' ||
      primaryType == 'place_of_worship' ||
      primaryType == 'mosque') {
    return 45;
  }
  if (primaryType == 'shopping_mall' || primaryType.contains('store')) {
    return 60;
  }
  if (primaryType == 'spa' ||
      primaryType == 'massage_spa' ||
      primaryType == 'wellness_center' ||
      primaryType == 'sauna' ||
      primaryType == 'hammam' ||
      primaryType == 'thermal_bath' ||
      primaryType == 'beauty_salon') {
    return 90;
  }
  if (primaryType == 'historical_landmark' ||
      primaryType == 'monument' ||
      primaryType == 'tourist_attraction') {
    return 60;
  }
  return 75;
}

String? _priceLabelFromLevel(int? level) {
  switch (level) {
    case 0:
      return 'Gratuit';
    case 1:
      return '~10€';
    case 2:
      return '~20€';
    case 3:
      return '~40€';
    case 4:
      return '~70€';
    default:
      return null;
  }
}

/// Insère déterministiquement déjeuner (12:30) et dîner (19:30) pour chaque
/// jour. Pour chaque jour :
/// - Activité matinale (start_time < 13h) → ancre déjeuner
/// - Activité aprem (start_time ∈ [13h, 19h]) → ancre dîner
/// - Si aucune activité ancrage pour un jour, on utilise le `DayCenter` du
///   jour (centre du groupe géographique). Évite qu'un jour sans activité
///   Gemini se retrouve sans repas du tout.
///
/// Filtres restos (cf. _findBestRestoNear) :
/// - Profil voyageur (rating min, priceLevel min/max)
/// - Boost +0.1 rating si Gastronomie dans intérêts
/// - Anti fast food (Burger King, kebab fast food, McDo...)
/// - Anti doublon (titre + primary type pour diversité midi/soir)
///
/// Logique distance : `(maxConsecutiveDistanceMeters × 0.8).clamp(150, 600)`,
/// défaut 640m pour profil sans contrainte. Marge 20% pour absorber les
/// imprécisions Places.
Future<List<ActivitySuggestion>> insertDeterministicMeals({
  required List<ActivitySuggestion> activities,
  required List<DayCandidates> pool,
  required PlacesNearbyService nearbyService,
  required TravelerPlacesProfile? travelerProfile,
  required List<String> tripInterests,
  required String? languageCode,

  /// Mode de déplacement local préféré (`walk`/`taxi`/...) pour ajuster le
  /// rayon de recherche resto. Null = comportement actuel (basé profil).
  String? localTransportMode,

  /// Cap maximum de `priceLevel` Places dérivé du budget par personne du
  /// voyage. Évince les restos manifestement trop chers. Lieux sans
  /// priceLevel toujours conservés.
  int? budgetPriceCap,
}) async {
  // Group activities par jour (peut être vide si Gemini a sauté un jour)
  final byDay = <String, List<ActivitySuggestion>>{};
  for (final a in activities) {
    final key = a.dayDate.toIso8601String().split('T').first;
    byDay.putIfAbsent(key, () => []).add(a);
  }
  // Index DayCenter par jour ISO — utilisé en fallback quand Gemini n'a rien
  // proposé sur un jour, ou quand l'ancre activité n'a pas de coords.
  final centersByDay = <String, DayCenter>{};
  for (final d in pool) {
    centersByDay[d.day.toIso8601String().split('T').first] = d.center;
  }

  final maxConsec = effectiveMaxConsecutiveDistance(
    travelerProfile: travelerProfile,
    localTransportMode: localTransportMode,
    fallback: 800,
  );
  final mealRadius = (maxConsec * 0.8).round().clamp(150, 600);

  double? hourFloat(String hhmm) {
    final p = hhmm.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h + m / 60.0;
  }

  String norm(String s) => s.toLowerCase().trim();

  String? priceFromLevel(int? level) {
    switch (level) {
      case 0:
        return 'Gratuit';
      case 1:
        return '~10€';
      case 2:
        return '~20€';
      case 3:
        return '~40€';
      case 4:
        return '~70€';
      default:
        return null;
    }
  }

  final out = <ActivitySuggestion>[];

  // 2026-05-08 calibrage #5 : essai cap=1 → cassait gravement Couple
  // (mls 12→2, 10 meals skippés) car anchors partagés en intra-Marrakech
  // épuisent la pool restos après ~6-8 picks uniques. Revenu à cap=2
  // (comportement initial). Le softExcludeTitlesUseCount × -50/usage
  // suffit à pousser un resto déjà-utilisé en bas du classement quand
  // la pool a des alternatives ; le 2× n'arrive qu'en dernier recours
  // (pool très pauvre). Acceptable par design. Cf. memo calibrage #5.
  const maxRestoUsesAcrossTrip = 2;
  final restoUseCount = <String, int>{};
  final cuisineUseCount = <String, int>{};

  // V8 Cost-2 (Lalith 2026-05-10) — pool restos partagée par centre.
  // Avant : 2 meals × N jours × cascade 1-3 nearby = jusqu'à 6N appels.
  // Après : 1 nearby par centre distinct (`_buildRestaurantPoolForCenter`),
  // puis picks in-memory pour chaque meal. Sur 8j / 2 villes : 2 appels au
  // lieu de ~24 (-92%).
  //
  // Signature : on réutilise `placesPoolSignature` avec le rayon de fetch
  // resto dédié pour ne pas confondre avec le grouping pool d'intérêts
  // (radius walking) — 2 caches séparés en gemini_cache.
  final restaurantPoolBySig = <String, List<NearbyCandidate>>{};
  for (final dc in pool) {
    final sig = placesPoolSignature(
      center: dc.center,
      radius: _restaurantPoolFetchRadiusMeters,
      languageCode: languageCode,
    );
    if (restaurantPoolBySig.containsKey(sig)) continue;
    final restos = await _buildRestaurantPoolForCenter(
      nearbyService: nearbyService,
      center: dc.center,
      languageCode: languageCode,
    );
    restaurantPoolBySig[sig] = restos;
    // ignore: avoid_print
    print(
      '[places_pool_build] kind=resto sig=$sig source=${dc.center.source} '
      'radius=${_restaurantPoolFetchRadiusMeters}m → ${restos.length} candidats',
    );
  }

  // On itère sur TOUS les jours de la pool (pas seulement ceux avec activités
  // Gemini), pour insérer même les repas des jours sans visite Gemini.
  for (final dayCenter in pool) {
    final dayKey = dayCenter.day.toIso8601String().split('T').first;
    final list = byDay[dayKey] ?? const <ActivitySuggestion>[];
    final sortedList = [...list]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final excludeTitles = <String>{
      ...sortedList.map((a) => norm(a.title)),
      // Restos déjà utilisés ≥ maxRestoUsesAcrossTrip sur le voyage : exclus.
      ...restoUseCount.entries
          .where((e) => e.value >= maxRestoUsesAcrossTrip)
          .map((e) => e.key),
    };

    // V8 Cost-2 : pool restos partagée par tous les jours du même centre.
    final restoPoolSig = placesPoolSignature(
      center: dayCenter.center,
      radius: _restaurantPoolFetchRadiusMeters,
      languageCode: languageCode,
    );
    final restoPool =
        restaurantPoolBySig[restoPoolSig] ?? const <NearbyCandidate>[];

    // Anchors : matinale (avant 13h, géolocalisée) ou centre du jour si
    // rien — garantit qu'on insère toujours un déjeuner même sans activité
    // matinale Gemini. Cf. fix C 26/04 (Lalith J3 sans activité du tout).
    ActivitySuggestion? lunchAnchorActivity;
    for (final a in sortedList) {
      final h = hourFloat(a.startTime);
      if (h == null || h >= 13.0) continue;
      if (a.latitude == null || a.longitude == null) continue;
      lunchAnchorActivity = a;
    }
    final lunchLat = lunchAnchorActivity?.latitude ?? dayCenter.center.latitude;
    final lunchLng =
        lunchAnchorActivity?.longitude ?? dayCenter.center.longitude;
    final lunchAnchorLabel = lunchAnchorActivity?.title ?? 'centre du jour';

    // Cuisines déjà utilisées sur le voyage — exclues en première passe pour
    // diversifier midi/soir entre les jours (pas 2× pizza, 2× sushi, etc.).
    // Si la pool n'a plus rien après cette exclusion, fallback sans.
    final cuisinesUsedTrip = cuisineUseCount.keys.toSet();

    final lunchCtx = 'kind=lunch date=$dayKey anchor="$lunchAnchorLabel"';
    // V8 Cost-2 : picks in-memory depuis la pool partagée — 0 appel API.
    var lunch = _pickRestoFromPool(
      pool: restoPool,
      anchorLatitude: lunchLat,
      anchorLongitude: lunchLng,
      mealRadius: mealRadius,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      excludePrimaryTypes: cuisinesUsedTrip,
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
      logContext: '$lunchCtx pass=1_strict_cuisine',
    );
    // Fallback : si exclusion cuisines a vidé la pool, retry sans.
    lunch ??= _pickRestoFromPool(
      pool: restoPool,
      anchorLatitude: lunchLat,
      anchorLongitude: lunchLng,
      mealRadius: mealRadius,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
      logContext: '$lunchCtx pass=2_relaxed_cuisine',
    );

    String? lunchPrimaryType;
    if (lunch != null) {
      final lunchCandidate = lunch.$1;
      final lunchDistM = lunch.$2;
      lunchPrimaryType = lunchCandidate.types.isNotEmpty
          ? lunchCandidate.types.first
          : null;
      // Suffixe reason si le pick est plus loin que le rayon initial
      // (équivalent de l'ancien `radiusUsed > mealRadius`).
      final widenedSuffix = lunchDistM > mealRadius
          ? ' — un peu plus loin car peu d\'options proches'
          : '';
      // ignore: avoid_print
      print(
        '[places_pool_reuse] kind=resto day=$dayKey meal=lunch '
        'sig=$restoPoolSig → "${lunchCandidate.name}" @${lunchDistM}m',
      );
      out.add(
        ActivitySuggestion(
          dayDate: dayCenter.day,
          startTime: '12:30',
          title: lunchCandidate.name,
          detail: lunchCandidate.address,
          tag: 'Repas',
          durationMinutes: 75,
          priceEstimate: priceFromLevel(lunchCandidate.priceLevel),
          matchReason:
              'Top noté ★${lunchCandidate.rating} (${lunchCandidate.userRatingCount ?? 0} avis), à ${lunchDistM}m de "$lunchAnchorLabel"$widenedSuffix',
          latitude: lunchCandidate.latitude,
          longitude: lunchCandidate.longitude,
        ),
      );
      final lunchKey = norm(lunchCandidate.name);
      excludeTitles.add(lunchKey);
      restoUseCount[lunchKey] = (restoUseCount[lunchKey] ?? 0) + 1;
      if (lunchPrimaryType != null) {
        cuisineUseCount[lunchPrimaryType] =
            (cuisineUseCount[lunchPrimaryType] ?? 0) + 1;
      }
    } else {
      debugPrint(
        '[places_first] ⚠️ ${dayCenter.day.toIso8601String().split("T").first} déjeuner : '
        'aucun resto fiable trouvé jusqu\'à 1500m de "$lunchAnchorLabel" — slot laissé vide',
      );
    }

    // Ancre dîner : aprem (13h-19h) ou centre du jour
    ActivitySuggestion? dinnerAnchorActivity;
    for (final a in sortedList) {
      final h = hourFloat(a.startTime);
      if (h == null || h < 13.0 || h >= 19.0) continue;
      if (a.latitude == null || a.longitude == null) continue;
      dinnerAnchorActivity = a;
    }
    final dinnerLat =
        dinnerAnchorActivity?.latitude ?? dayCenter.center.latitude;
    final dinnerLng =
        dinnerAnchorActivity?.longitude ?? dayCenter.center.longitude;
    final dinnerAnchorLabel = dinnerAnchorActivity?.title ?? 'centre du jour';

    // Dîner : on exclut le primary type du déjeuner du jour ET les cuisines
    // déjà utilisées sur le voyage (en passe 1). Fallback si pool vide.
    final cuisinesUsedTripForDinner = <String>{
      ...cuisineUseCount.keys,
      ?lunchPrimaryType,
    };

    final dinnerCtx = 'kind=dinner date=$dayKey anchor="$dinnerAnchorLabel"';
    var dinner = _pickRestoFromPool(
      pool: restoPool,
      anchorLatitude: dinnerLat,
      anchorLongitude: dinnerLng,
      mealRadius: mealRadius,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      excludePrimaryTypes: cuisinesUsedTripForDinner,
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
      logContext: '$dinnerCtx pass=1_strict_cuisine',
    );
    // Fallback 1 : retry sans exclusion cuisines voyage (mais conserve
    // l'exclusion midi du jour pour ne pas servir 2× pareil dans la journée).
    dinner ??= _pickRestoFromPool(
      pool: restoPool,
      anchorLatitude: dinnerLat,
      anchorLongitude: dinnerLng,
      mealRadius: mealRadius,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      excludePrimaryTypes: <String>{?lunchPrimaryType},
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
      logContext: '$dinnerCtx pass=2_lunch_dup_only',
    );

    if (dinner != null) {
      final dinnerCandidate = dinner.$1;
      final dinnerDistM = dinner.$2;
      final widenedSuffix = dinnerDistM > mealRadius
          ? ' — un peu plus loin car peu d\'options proches'
          : '';
      final dinnerPrimaryType = dinnerCandidate.types.isNotEmpty
          ? dinnerCandidate.types.first
          : null;
      // ignore: avoid_print
      print(
        '[places_pool_reuse] kind=resto day=$dayKey meal=dinner '
        'sig=$restoPoolSig → "${dinnerCandidate.name}" @${dinnerDistM}m',
      );
      out.add(
        ActivitySuggestion(
          dayDate: dayCenter.day,
          startTime: '19:30',
          title: dinnerCandidate.name,
          detail: dinnerCandidate.address,
          tag: 'Repas',
          durationMinutes: 90,
          priceEstimate: priceFromLevel(dinnerCandidate.priceLevel),
          matchReason:
              'Top noté ★${dinnerCandidate.rating} (${dinnerCandidate.userRatingCount ?? 0} avis), à ${dinnerDistM}m de "$dinnerAnchorLabel"$widenedSuffix',
          latitude: dinnerCandidate.latitude,
          longitude: dinnerCandidate.longitude,
        ),
      );
      final dinnerKey = norm(dinnerCandidate.name);
      restoUseCount[dinnerKey] = (restoUseCount[dinnerKey] ?? 0) + 1;
      if (dinnerPrimaryType != null) {
        cuisineUseCount[dinnerPrimaryType] =
            (cuisineUseCount[dinnerPrimaryType] ?? 0) + 1;
      }
    } else {
      debugPrint(
        '[places_first] ⚠️ ${dayCenter.day.toIso8601String().split("T").first} dîner : '
        'aucun resto fiable trouvé jusqu\'à 1500m de "$dinnerAnchorLabel" — slot laissé vide',
      );
    }
  }
  debugPrint(
    '[places_first] Insertion déterministe : ${out.length} repas insérés',
  );
  return out;
}

/// Trie la pool par "qualité" (rating × log(userRatingCount)) et garde les
/// `maxPoolSize` meilleurs. Sert à borner les tokens envoyés à Gemini quand
/// la ville est très riche en lieux. 50 est un compromis raisonnable :
/// largement assez pour 6 jours × 4 créneaux × 3 options diverses.
List<
  MapEntry<String, ({NearbyCandidate candidate, List<String> matchedInterests})>
>
_trimPool(
  Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})>
  pool, {
  int maxPoolSize = 50,
}) {
  final entries = pool.entries.toList();
  entries.sort((a, b) {
    final ra = a.value.candidate.rating ?? 0;
    final rb = b.value.candidate.rating ?? 0;
    final ca = a.value.candidate.userRatingCount ?? 0;
    final cb = b.value.candidate.userRatingCount ?? 0;
    // Score : on multiplie par log(count) pour favoriser les lieux avec un
    // bon rating ET un volume d'avis significatif (vs un 5★ avec 3 avis).
    double score(double r, int c) =>
        r * (c <= 1 ? 1 : (1 + (c.bitLength.toDouble())));
    return score(rb, cb).compareTo(score(ra, ca));
  });
  return entries.take(maxPoolSize).toList();
}

/// Construit le prompt Gemini pour un groupe de jours en mode CoPilot.
/// Gemini reçoit la pool de candidats RÉELS (avec ID court P0/P1/.../P49),
/// le contexte voyage, et doit retourner pour chaque jour les créneaux et
/// les 3 options choisies — UNIQUEMENT parmi la pool fournie. Aucune
/// invention possible.
String buildCoPilotPrompt({
  required PlacesPromptInput input,
  required Trip trip,
  required TravelerPlacesProfile? travelerProfile,
}) {
  final entries = _trimPool(input.pool);
  // Lignes du catalogue : "P0: Nom — adresse [types] ★rating (N avis) — match: Culture, Bons plans"
  final catalogLines = <String>[];
  for (var i = 0; i < entries.length; i++) {
    final c = entries[i].value.candidate;
    final interests = entries[i].value.matchedInterests.join(', ');
    final addr = c.address ?? '';
    final typesShort = c.types.take(3).join(', ');
    catalogLines.add(
      'P$i: ${c.name} — $addr [$typesShort] ★${c.rating} (${c.userRatingCount ?? 0} avis) — match: $interests',
    );
  }
  final dayLines = input.days.map(_iso).join(', ');
  final hasKids = trip.travelers.any((t) => t.age < 13);
  final travelers = trip.travelers.isEmpty
      ? 'solo'
      : trip.travelers.map((t) => '${t.name} (${t.age} ans)').join(', ');

  final profileBlock = travelerProfile == null
      ? ''
      : '\nProfil voyageur "${trip.travelerType}" : ${travelerProfile.rule ?? "—"}'
            '${travelerProfile.maxActivityMinutes != null ? "\nDurée max par activité : ${travelerProfile.maxActivityMinutes} min." : ""}'
            '${travelerProfile.maxConsecutiveDistanceMeters != null ? "\nDistance max entre 2 activités du même jour : ${travelerProfile.maxConsecutiveDistanceMeters}m." : ""}';

  return '''
Tu es un expert en voyages. Tu dois SÉLECTIONNER (pas inventer) des activités pour un voyageur, en t'appuyant UNIQUEMENT sur la liste de lieux RÉELS ci-dessous (tous vérifiés sur Google Places).

🚫 RÈGLE ABSOLUE : tu ne peux UTILISER QUE les lieux du catalogue, identifiés par leur référence (P0, P1, ...). Tu n'as PAS le droit d'en inventer d'autres ou de modifier les noms. Si la pool ne contient pas un type de lieu pour un créneau (ex: pas de bar pour "Soirée"), saute ce créneau.

Voyage :
- Destination : ${trip.destination}
- Voyageurs : $travelers${hasKids ? ' (enfants présents)' : ''}
- Centres d'intérêt : ${trip.interests?.join(', ') ?? "non précisés"}$profileBlock

Jours à organiser : $dayLines (${input.days.length} jour${input.days.length > 1 ? 's' : ''}).

Catalogue de lieux disponibles autour du centre du jour (${input.center.source}, ${entries.length} lieux retenus) :
${catalogLines.join('\n')}

Pour CHAQUE jour ci-dessus :
- Identifie 2 à 4 créneaux pertinents (ex: "Matin", "Déjeuner", "Après-midi", "Soirée").
- Pour CHAQUE créneau, propose **EXACTEMENT 3 options** parmi le catalogue (par ref P0, P1, ...).
- Les 3 options d'un même créneau doivent être de la MÊME intention (ex: 3 musées pour un matin culture, 3 restos pour un déjeuner) mais variées en gamme/quartier/ambiance.
- Varie les choix entre les jours : pas la même option à chaque jour. Si la pool est petite, accepte de répéter MAX 2 fois la même option à travers tous les créneaux du voyage.
- Pour chaque option, donne un `match_reason` (1 phrase) qui explique pourquoi elle convient à CE voyageur sur CE créneau.
- Choisis une heure de début réaliste pour le créneau (matin 9-10h, déjeuner 12-13h, après-midi 14-16h, soirée 19-21h, à adapter aux horaires d'ouverture probables du type de lieu).

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "days": [
    {
      "date": "YYYY-MM-DD",
      "slots": [
        {
          "label": "Matin",
          "start_time": "10:00",
          "options": [
            {"ref": "P0", "duration_minutes": 90, "price_estimate": "~12€", "match_reason": "Matche ton intérêt 'Culture' + créneau matin tranquille"},
            {"ref": "P5", "duration_minutes": 60, "price_estimate": "Gratuit", "match_reason": "..."},
            {"ref": "P12", "duration_minutes": 120, "price_estimate": "~25€", "match_reason": "..."}
          ]
        }
      ]
    }
  ]
}
''';
}

/// Parse la réponse Gemini d'un prompt CoPilot et reconstitue les
/// `SuggestionGroup` consommables par le pipeline existant. Les options
/// sont reconstruites depuis la pool (titre canonique Places, adresse,
/// rating) — Gemini ne fait que choisir des refs, pas de strings à valider.
List<SuggestionGroup> parseCoPilotResponse({
  required String rawJson,
  required PlacesPromptInput input,
}) {
  // Index P0/P1/.../Pn → candidat. Doit reproduire l'ordre de _trimPool
  // utilisé dans le prompt.
  final entries = _trimPool(input.pool);
  final byRef = <String, NearbyCandidate>{};
  for (var i = 0; i < entries.length; i++) {
    byRef['P$i'] = entries[i].value.candidate;
  }
  // Validation déterministe du `date` retourné par Gemini (cf. fix D 26/04).
  final validDayKeys = input.days
      .map((d) => d.toIso8601String().split('T').first)
      .toSet();

  final cleaned = _stripCodeFences(rawJson).trim();
  dynamic parsed;
  try {
    parsed = jsonDecode(cleaned);
  } catch (e) {
    debugPrint('parseCoPilotResponse : JSON invalide — $e');
    return [];
  }
  if (parsed is! Map) return [];
  final daysJson = parsed['days'] as List? ?? const [];

  final groups = <SuggestionGroup>[];
  for (final dayJson in daysJson) {
    if (dayJson is! Map) continue;
    final dateStr = dayJson['date'] as String?;
    if (dateStr == null) continue;
    if (!validDayKeys.contains(dateStr)) {
      debugPrint(
        '[places_first] CoPilot date "$dateStr" hors cluster (attendu: ${validDayKeys.join(",")}) — skip',
      );
      continue;
    }
    final date = DateTime.tryParse(dateStr);
    if (date == null) continue;
    final slots = dayJson['slots'] as List? ?? const [];
    for (final slotJson in slots) {
      if (slotJson is! Map) continue;
      final slotLabel = (slotJson['label'] as String?)?.trim() ?? 'Créneau';
      final slotStart = (slotJson['start_time'] as String?)?.trim() ?? '';
      final optionsJson = slotJson['options'] as List? ?? const [];

      final options = <ActivitySuggestion>[];
      for (final optJson in optionsJson) {
        if (optJson is! Map) continue;
        final ref = (optJson['ref'] as String?)?.trim();
        if (ref == null) continue;
        final candidate = byRef[ref];
        if (candidate == null) {
          debugPrint('Réf inconnue "$ref" dans la réponse Gemini — skip');
          continue;
        }
        // Filtre déterministe horaire/type Places : rejette les aberrations
        // type "bar à 12h30" sans dépendre de Gemini.
        if (!_isAppropriateForTime(candidate, slotStart)) {
          debugPrint(
            '[places_first] Filtre horaire : rejet "${candidate.name}" '
            '(types=${candidate.types.take(3).join(",")}) à $slotStart',
          );
          continue;
        }
        // Tag déduit du primary type Places (heuristique simple, à raffiner)
        final tag = _tagFromPrimaryType(
          candidate.types.isNotEmpty ? candidate.types.first : '',
        );
        options.add(
          ActivitySuggestion(
            dayDate: date,
            startTime: slotStart,
            title: candidate.name,
            detail: candidate.address,
            tag: tag,
            durationMinutes: (optJson['duration_minutes'] as num?)?.toInt(),
            priceEstimate: (optJson['price_estimate'] as String?)?.trim(),
            matchReason: (optJson['match_reason'] as String?)?.trim(),
            latitude: candidate.latitude,
            longitude: candidate.longitude,
          ),
        );
      }
      if (options.isEmpty) continue;
      groups.add(
        SuggestionGroup(
          dayDate: date,
          slotLabel: slotLabel,
          startTime: slotStart,
          options: options,
        ),
      );
    }
  }
  return groups;
}

/// Mappe le primary type Places vers un tag Voyage compréhensible par l'UI
/// (cf. tags utilisés dans le pipeline existant : Repas, Visite, Culture, etc.).
String _tagFromPrimaryType(String primaryType) {
  if (primaryType.isEmpty) return 'Activité';
  if (primaryType.contains('restaurant') ||
      primaryType == 'cafe' ||
      primaryType == 'bakery' ||
      primaryType == 'meal_delivery' ||
      primaryType == 'meal_takeaway' ||
      primaryType == 'food_court') {
    return 'Repas';
  }
  if (primaryType.contains('museum') ||
      primaryType == 'art_gallery' ||
      primaryType == 'library' ||
      primaryType == 'historical_landmark' ||
      primaryType == 'historical_place') {
    return 'Culture';
  }
  if (primaryType == 'park' ||
      primaryType == 'national_park' ||
      primaryType == 'botanical_garden' ||
      primaryType == 'zoo' ||
      primaryType == 'aquarium' ||
      primaryType == 'beach') {
    return 'Nature';
  }
  if (primaryType == 'bar' ||
      primaryType == 'night_club' ||
      primaryType == 'pub' ||
      // V8.9 (Lalith 2026-05-10 — Q1B) — brewpub/brewery/bar_and_grill
      // taggés Nightlife pour aligner avec le filtre time-of-day
      // ≥17h. Avant un Brewpub primary leakait en tag=Activité.
      primaryType == 'brewpub' ||
      primaryType == 'brewery' ||
      primaryType == 'bar_and_grill' ||
      primaryType.contains('bar')) {
    return 'Nightlife';
  }
  if (primaryType.contains('shop') ||
      primaryType.contains('store') ||
      primaryType == 'shopping_mall' ||
      primaryType == 'market') {
    return 'Shopping';
  }
  // Wellness — uniquement spas/saunas/hammams. `gym` est passé en
  // 'Activité' (sport pratiqué) — cf. spec Lalith 2026-05-09 séparation
  // claire Activité (à pratiquer) vs Événements (à regarder).
  if (primaryType == 'spa' ||
      primaryType == 'massage_spa' ||
      primaryType == 'massage' ||
      primaryType == 'public_bath' ||
      primaryType == 'wellness_center' ||
      primaryType == 'sauna' ||
      primaryType == 'hammam' ||
      primaryType == 'thermal_bath' ||
      primaryType == 'beauty_salon') {
    return 'Wellness';
  }
  if (primaryType == 'church' || primaryType == 'place_of_worship') {
    return 'Culture';
  }
  // ─── Événements (lieux de représentation, à regarder) ──────────────
  // Stadiums/arenas : événements sportifs (NBA, foot, kick-boxing pro).
  // Theaters/event venues : spectacles. Cinemas : projections.
  if (primaryType == 'performing_arts_theater' ||
      primaryType == 'event_venue' ||
      primaryType == 'cultural_center' ||
      primaryType == 'convention_center' ||
      primaryType == 'movie_theater' ||
      primaryType == 'live_music_venue' ||
      primaryType == 'stadium' ||
      primaryType == 'arena' ||
      primaryType == 'sports_complex') {
    return 'Événements';
  }
  // ─── Activité (à pratiquer/faire) ──────────────────────────────────
  // Parcs d'attractions, parcs aquatiques, sports actifs (gym, école de
  // surf, yoga, kitesurf, kick-boxing école), tourist_attraction généraux.
  // `landmark` reste 'Visite' (monument à voir, pas activité).
  if (primaryType == 'amusement_park' ||
      primaryType == 'amusement_center' ||
      primaryType == 'theme_park' ||
      primaryType == 'water_park' ||
      primaryType == 'adventure_sports_center' ||
      primaryType == 'sports_activity_location' ||
      primaryType == 'sports_school' ||
      primaryType == 'fitness_center' ||
      primaryType == 'gym' ||
      primaryType == 'tourist_attraction') {
    return 'Activité';
  }
  if (primaryType == 'landmark') {
    return 'Visite';
  }
  return 'Activité';
}

/// Cohérence sémantique entre un tag (dérivé du primary type Place) et un
/// intérêt voyageur (sélectionné par l'user). Sert à filtrer les match_reason
/// surprenants type "Pâtisserie [Shopping] Matche 'Culture'" en n'affichant
/// la mention "Matche 'X'" que si X est plausiblement aligné avec le tag.
///
/// Tag par défaut "Activité" → on accepte tout (peu de risque de surprise).
bool _isInterestCoherentWithTag(String interest, String tag) {
  const coherence = <String, Set<String>>{
    'Repas': {'Gastronomie', 'Bons plans', 'Hors circuit'},
    'Culture': {'Culture', 'Spots populaires', 'Hors circuit', 'Événements'},
    'Nature': {'Nature', 'Plage', 'Sports', 'Hors circuit'},
    'Nightlife': {'Nightlife', 'Événements'},
    'Shopping': {'Shopping', 'Bons plans', 'Esthétique'},
    'Wellness': {'Wellness', 'Esthétique'},
    'Visite': {
      'Spots populaires',
      'Culture',
      'Hors circuit',
      'Événements',
      'Nature',
    },
    // Activité (à pratiquer) — sports actifs, parcs attractions, water_park,
    // tourist_attraction. Cohérent avec Sports / Loisirs / Spots populaires.
    'Activité': {
      'Sports',
      'Spots populaires',
      'Hors circuit',
      'Plage',
      'Nature',
      'Bons plans',
    },
    // Événements (à regarder) — théâtre/concert/cinéma/stade/arena. Cohérent
    // avec Événements / Nightlife / Spots populaires / Culture.
    'Événements': {'Événements', 'Nightlife', 'Spots populaires', 'Culture'},
    // Tags hérités — gardés rétrocompat (peuvent encore apparaître si un
    // code legacy renvoie 'Loisir'/'Sport') mais ne sont plus émis par le
    // nouveau `_tagFromPrimaryType`.
    'Loisir': {'Spots populaires', 'Sports', 'Événements', 'Nightlife'},
    'Sport': {'Sports', 'Spots populaires'},
  };
  final allowed = coherence[tag];
  if (allowed == null) return true; // tag générique → on n'exclut rien
  return allowed.contains(interest);
}

String _stripCodeFences(String text) {
  var t = text.trim();
  final fence = RegExp(r'^```(?:json)?\s*|\s*```$', multiLine: true);
  t = t.replaceAll(fence, '').trim();
  return t;
}

/// Vrai si le lieu (via ses types Places) est cohérent avec le créneau horaire
/// proposé. Filtre déterministe — aucune confiance dans Gemini pour les
/// horaires d'ouverture.
///
/// Logique de "vote" : pour chaque type Places connu du lieu, on évalue si
/// `hour` tombe dans un créneau plausible pour ce type. Si AU MOINS UN type
/// donne un verdict positif → on accepte (un lieu peut être bar+restaurant,
/// le restaurant légitime un déjeuner). Si TOUS les types connus disent non
/// → on rejette. Aucun type géré → accepte par défaut.
///
/// `matchedInterests` (optionnel) sert aux types Événements contextuels :
/// si le lieu (`stadium`/`event_venue`/`cultural_center`) a été remonté via
/// l'intérêt 'Événements', il est restreint au soir (≥18h). Sinon il reste
/// permissif (visite stade Bernabéu en journée OK, etc.).
///
/// Exemples :
/// - "Pub Mac Carthy" types=[bar,pub] à 12:30 → bar:non, pub:non → REJET
/// - "Brasserie Excelsior" types=[restaurant,bar] à 12:30 → restaurant:oui → ACCEPT
/// - "Place Stanislas" types=[tourist_attraction] à 22:00 → pas géré → ACCEPT
/// - "Cinéma Colisée" types=[movie_theater] à 14:30 → REJET (≥18h strict)
/// - "Stade Bernabéu" types=[stadium] matched=[Spots populaires] à 11:00 → ACCEPT
/// - "Stade Bernabéu" types=[stadium] matched=[Événements] à 11:00 → REJET
bool _isAppropriateForTime(
  NearbyCandidate c,
  String startTime, {
  Set<String>? matchedInterests,
}) {
  final hour = _parseHourFloat(startTime);
  if (hour == null) return true;

  // ─── Règle de rejet ABSOLU (l'emporte sur le vote) ──────────────────
  // Les bâtiments administratifs/éducatifs ne sont JAMAIS un repas, peu
  // importe leur signal touristique secondaire. Si Gemini les place à un
  // créneau repas (12-15h ou 18:30-23h), on rejette dur. Parade au cas où
  // un tel lieu passe à travers la blacklist (mairie historique, école
  // emblématique) — il peut être visité, jamais mangé.
  if (c.types.isNotEmpty && _neverMealPrimaryTypes.contains(c.types.first)) {
    final isMealHour =
        (hour >= 11.5 && hour <= 15.0) || (hour >= 18.5 && hour <= 23.0);
    if (isMealHour) return false;
  }

  // ─── Règle ≥18h ABSOLUE pour les types "evening event" purs ─────────
  // Cinéma/théâtre/salle de concert/night-club : aller voir un film à
  // 09:30 n'a pas de sens. PRIME sur la règle bars (17h) car night_club
  // est aussi listé dans `_strictBarPrimaryTypes`. Cf. spec 2026-05-08.
  if (c.types.isNotEmpty && _eveningOnlyEventTypes.contains(c.types.first)) {
    if (hour < 18.0) return false;
    return true;
  }

  // ─── Règle ≥18h CONTEXTUELLE pour stadium/event_venue/cultural_center
  // Bloqué uniquement si le lieu a été remonté via 'Événements'
  // (matchedInterests). Sinon permissif (visite touristique journée OK).
  if (c.types.isNotEmpty &&
      _eventVenueContextualTypes.contains(c.types.first) &&
      (matchedInterests?.contains('Événements') ?? false)) {
    if (hour < 18.0) return false;
    return true;
  }

  // ─── Règle de rejet ABSOLU pour bars ────────────────────────────────
  // Si le primary type est un bar/pub/club, ON IGNORE les types secondaires
  // (un Pub a souvent `restaurant` en secondaire ce qui le ferait passer
  // au créneau déjeuner via le vote). Un bar reste un bar : pas avant 17h.
  // Cf. fix 26/04 Pub Mac Carthy (irish_pub) sélectionné à 14:30.
  if (c.types.isNotEmpty && _strictBarPrimaryTypes.contains(c.types.first)) {
    return hour >= 17.0;
  }

  // ─── Vote sur les types Places connus ───────────────────────────────
  bool? overallVerdict;
  for (final type in c.types) {
    final v = _typeAllowedAtHour(type, hour);
    if (v == null) continue;
    if (v) return true; // au moins un type valide → on accepte
    overallVerdict = false;
  }
  return overallVerdict != false;
}

/// Types Places considérés comme "repas" : restaurants/cafés/bars. Servent à :
/// 1. filtrer la pool envoyée à Gemini en mode Auto category=all (Gemini ne
///    voit pas les restos donc ne peut pas en proposer aux mauvais créneaux)
/// 2. cibler la recherche post-Gemini quand on insère les repas par scoring
///    déterministe (cf. insertDeterministicMeals).
const Set<String> _mealPlaceTypes = <String>{
  'restaurant',
  'cafe',
  'bakery',
  'bar',
  'pub',
  'food_court',
  'meal_delivery',
  'meal_takeaway',
  'wine_bar',
  'sports_bar',
  'night_club',
  'fine_dining_restaurant',
  'fast_food_restaurant',
  'french_restaurant',
  'italian_restaurant',
  'japanese_restaurant',
  'chinese_restaurant',
  'thai_restaurant',
  'mexican_restaurant',
  'mediterranean_restaurant',
  'pizza_restaurant',
  'sushi_restaurant',
  'vegan_restaurant',
  'vegetarian_restaurant',
  'seafood_restaurant',
  'steak_house',
  'sandwich_shop',
  'breakfast_restaurant',
  'brunch_restaurant',
  'coffee_shop',
  'tea_house',
  'ice_cream_shop',
  // Pâtisseries / boulangeries fines / confiseries : alimentaires, pas
  // des activités de visite. Leur place est dans les créneaux repas/snack
  // (insertion déterministe meals), pas dans les slots visite. Évite les
  // 4-5 pâtisseries en créneaux non-repas observées sur Essaouira (logs
  // Lalith 2026-05-08).
  'pastry_shop',
  'dessert_shop',
  'cake_shop',
  'confectionery',
  'donut_shop',
  'chocolate_shop',
  'candy_store',
};

bool _isMealPrimaryType(NearbyCandidate c) {
  if (c.types.isEmpty) return false;
  final primary = c.types.first;
  // Tous les types Places de cuisine ethnique se terminent en `_restaurant`
  // (moroccan_restaurant, lebanese_restaurant, indian_restaurant, etc.).
  if (primary.contains('restaurant')) return true;
  // Patterns supplémentaires (kebab_shop, sandwich_shop, pizza_shop, etc.)
  // qui désignent des points de restauration sans le mot "restaurant".
  if (primary.endsWith('_shop') &&
      (primary.contains('kebab') ||
          primary.contains('sandwich') ||
          primary.contains('pizza') ||
          primary.contains('coffee') ||
          primary.contains('tea') ||
          primary.contains('ice_cream'))) {
    return true;
  }
  return _mealPlaceTypes.contains(primary);
}

/// Types Places considérés comme "wellness" pour 2 usages :
/// 1. cap densité dans `selectVisitsDeterministic` (max 1/jour, 2/cluster
///    si Wellness pas un intérêt fort du voyageur)
/// 2. tag affiché à l'utilisateur (`_tagFromPrimaryType` → 'Wellness')
///
/// `beauty_salon`/`hair_salon`/`nail_salon`/`massage` sont déjà filtrés
/// en amont par `_hardExcludedPrimaryTypes` (services pratiques, pas
/// activités touristiques) — pas besoin de les lister ici. `gym` reste
/// taggé Wellness via le mapping mais n'est pas concerné par le cap
/// densité (un gym n'est pas un spa).
const Set<String> _wellnessPrimaryTypes = <String>{
  'spa',
  'massage_spa',
  'wellness_center',
  'sauna',
  'hammam',
  'thermal_bath',
  // V8.9 (Lalith 2026-05-10 — Q1B) — additions retour debug Thaïlande :
  // « Dorum Onsen&Sauna » primary `public_bath` taggé Activité au lieu
  // de Wellness. `massage` (variante Google de massage_spa) idem.
  'public_bath',
  'massage',
};

bool _isWellnessPrimaryType(NearbyCandidate c) {
  if (c.types.isEmpty) return false;
  return _wellnessPrimaryTypes.contains(c.types.first);
}

/// Types Places "Événements" — usage strictement parallèle à
/// `_wellnessPrimaryTypes` : sert au cap densité dans le sélecteur
/// (max 1/jour standard, 2/jour pour profils tolérants Événements ∈
/// interests). Aligné sur `_tagFromPrimaryType` branche Événements.
///
/// 2026-05-08 calibrage #4 : sans ce cap, Grand luxe 17/05 enchaînait
/// Palais Festivals → Meydene → Théâtre Royal — 3 venues consécutifs
/// même quand le pool offrait Culture/Activité au même créneau.
const Set<String> _eventsPrimaryTypes = <String>{
  'performing_arts_theater',
  'event_venue',
  'cultural_center',
  'convention_center',
  'movie_theater',
  'live_music_venue',
  'stadium',
  'arena',
  'sports_complex',
};

bool _isEventsPrimaryType(NearbyCandidate c) {
  if (c.types.isEmpty) return false;
  return _eventsPrimaryTypes.contains(c.types.first);
}

/// Types "bar" qui imposent la règle ≥17h même si types secondaires acceptent
/// un autre créneau. Couvre les pubs/clubs typés `irish_pub` ou `cocktail_bar`
/// en primary, qui ont souvent `restaurant` ou `food` en secondaire et
/// passaient via le système de vote (cf. bug 26/04 Pub Mac Carthy à 14:30).
const Set<String> _strictBarPrimaryTypes = <String>{
  'bar',
  'pub',
  'irish_pub',
  'sports_bar',
  'wine_bar',
  'cocktail_bar',
  'lounge_bar',
  'night_club',
  'hookah_bar',
  // V8.8 (Lalith 2026-05-10) — additions retour debug Thaïlande :
  // « Third Pint Brewpub » primary `brewpub` était sélectionné à
  // 14:30 (tag=Activité). brewpub/brewery sont des bars-restos
  // soir, pas des activités diurnes. `bar_and_grill` même logique.
  'brewpub',
  'brewery',
  'bar_and_grill',
};

/// 2026-05-08 — types Événements à n'autoriser QUE le soir (≥18h).
/// Cinéma, théâtre, salle de concert, night-club : aller voir un film à
/// 09:30 ou un concert à 14:30 n'a pas de sens UX. Règle stricte sans
/// condition (les types secondaires ne sauvent pas — un cinéma reste un
/// cinéma). Cf. spec Lalith 2026-05-08.
const Set<String> _eveningOnlyEventTypes = <String>{
  'movie_theater',
  'performing_arts_theater',
  'live_music_venue',
  'night_club',
};

/// Types Événements **contextuels** : bloqués <18h UNIQUEMENT si le lieu
/// a été remonté via l'intérêt 'Événements'. Sinon (matché Spots
/// populaires/Culture/Sports), permissifs.
///
/// Justification :
/// - `stadium` peut être visité en journée (visite Bernabéu, Old Trafford…)
/// - `event_venue` ambigu (palais des congrès parfois visitable en journée)
/// - `cultural_center` souvent visitable en journée (expo permanente)
///   mais en mode événement (concert, projection) → soir uniquement.
const Set<String> _eventVenueContextualTypes = <String>{
  'stadium',
  'event_venue',
  'cultural_center',
};

/// Types administratifs/éducatifs : ne peuvent JAMAIS être un repas.
const Set<String> _neverMealPrimaryTypes = <String>{
  'local_government_office', 'city_hall', 'courthouse', 'embassy',
  'post_office', 'town_square_government',
  'school', 'primary_school', 'secondary_school', 'university',
  'language_school', 'tutoring_center', 'preschool',
  'library', // bibliothèque universitaire / municipale (visite OK, repas non)
};

/// Parse "HH:MM" en heure flottante (12:30 → 12.5). Retourne null si format
/// invalide, ce qui mène à acceptation par défaut (on ne pénalise pas une
/// suggestion à cause d'une heure mal formée).
double? _parseHourFloat(String startTime) {
  final parts = startTime.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h + m / 60.0;
}

/// Verdict "ce type Places est-il ouvert/légitime à cette heure".
/// - `true` = créneau plausible
/// - `false` = créneau implausible
/// - `null` = type non géré, pas d'opinion
///
/// Plages volontairement larges (15-30 min de tolérance) — on filtre les
/// aberrations grossières (bar à 12h, musée à 22h), pas les bords de
/// fenêtre. Les vraies horaires d'ouverture par lieu sont disponibles via
/// Places API mais pas chargées en pool — coût/complexité non justifié.
bool? _typeAllowedAtHour(String type, double hour) {
  switch (type) {
    // Bars / clubs / pubs : ≥ 17h
    case 'bar':
    case 'pub':
    case 'night_club':
    case 'wine_bar':
    case 'sports_bar':
    case 'brewpub':
    case 'brewery':
    case 'bar_and_grill':
      return hour >= 17.0;
    // V8.9 (Lalith 2026-05-10 — Quality-1B) — markets time-of-day.
    // Beaucoup de marchés sont matin (farmers) ou journée. Les
    // night markets ne sont pas tagués spécifiquement par Google v1
    // — on couvre via le type `market` générique restreint au jour.
    case 'farmers_market':
      return hour >= 6.0 && hour <= 14.0;
    case 'flea_market':
      return hour >= 8.0 && hour <= 17.0;
    case 'market':
      return hour >= 7.0 && hour <= 18.0;
    // Cafés / bakeries : 7h-19h
    case 'cafe':
    case 'bakery':
      return hour >= 7.0 && hour <= 19.0;
    // Restaurants : midi (11:30-15h) ou soir (18:30-23h)
    case 'restaurant':
      return (hour >= 11.5 && hour <= 15.0) || (hour >= 18.5 && hour <= 23.0);
    // Musées / galeries / bibliothèques / monuments historiques : 9h-18:30
    case 'museum':
    case 'art_gallery':
    case 'library':
    case 'historical_landmark':
    case 'historical_place':
      return hour >= 9.0 && hour <= 18.5;
    // Lieux de culte : 8h-19h
    case 'church':
    case 'place_of_worship':
    case 'mosque':
    case 'synagogue':
    case 'hindu_temple':
    case 'buddhist_temple':
      return hour >= 8.0 && hour <= 19.0;
    // Parcs / jardins / zoo / aquarium : 7h-21h
    case 'park':
    case 'national_park':
    case 'botanical_garden':
    case 'zoo':
    case 'aquarium':
      return hour >= 7.0 && hour <= 21.0;
    // Shopping : 10h-20h
    case 'shopping_mall':
    case 'department_store':
    case 'clothing_store':
    case 'shoe_store':
    case 'jewelry_store':
    case 'book_store':
      return hour >= 10.0 && hour <= 20.0;
    // Spas / beauté / wellness : 9h-20h
    case 'spa':
    case 'massage_spa':
    case 'wellness_center':
    case 'sauna':
    case 'hammam':
    case 'thermal_bath':
    case 'beauty_salon':
    case 'hair_salon':
    case 'nail_salon':
      return hour >= 9.0 && hour <= 20.0;
    // Sport / loisirs en salle : 9h-22h
    case 'gym':
    case 'amusement_park':
    case 'amusement_center':
    case 'bowling_alley':
      return hour >= 9.0 && hour <= 22.0;
    default:
      return null;
  }
}

/// Orchestre le flow Places-first pour le mode CoPilot bout-en-bout :
/// 1. Récolte les candidats Places pour chaque jour (`gatherCandidatesForTrip`).
/// 2. Pré-filtre les candidats dont le nom matche déjà une activité au planning
///    (= déjà choisie par le voyageur, pas la peine de la reproposer).
/// 3. Groupe les jours par centre géographique (`groupDaysByCenter`).
/// 4. Pour chaque groupe : prompt Gemini → parser → SuggestionGroup.
/// 5. Concatène tous les SuggestionGroup et retourne pour la sheet.
///
/// Appelle Gemini en parallèle sur les groupes (typiquement 1-3 groupes
/// pour la majorité des voyages). Cache via `gemini_cache` action
/// `places_first_copilot` (clé = hash du prompt) → re-runs gratuits.
Future<List<SuggestionGroup>> runCoPilotPlacesFirst({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,
  required AiSuggestionsService aiService,

  /// Titres normalisés des activités déjà au planning. Pré-filtre la pool
  /// pour éviter de reproposer ce que le voyageur a déjà coché.
  Set<String> existingTitlesNormalized = const {},

  /// Langue Places (BCP-47). Cf. `gatherCandidatesForTrip`.
  String? languageCode,

  /// POI-2.1 — Repository POI pour enrichir le pool avec des candidats curatés.
  PoiRepository? poiRepository,
}) async {
  // V7 (Lalith 2026-05-10 — Phase Cost-1) — démarre un budget pour
  // tracker les appels Places de cette génération. Tous les
  // searchNearby/searchText du pipeline passeront par les guards
  // (dedup intra-run, hard cap, bail-out 429). Le summary log est
  // posé dans le `finally` même en cas d'erreur.
  nearbyService.startRun(tripId: trip.id);
  try {
    return await _runCoPilotPlacesFirstBody(
      trip: trip,
      hotels: hotels,
      geocoder: geocoder,
      nearbyService: nearbyService,
      aiService: aiService,
      existingTitlesNormalized: existingTitlesNormalized,
      languageCode: languageCode,
      poiRepository: poiRepository,
    );
  } finally {
    nearbyService.endRun(context: 'coPilot');
  }
}

Future<List<SuggestionGroup>> _runCoPilotPlacesFirstBody({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,
  required AiSuggestionsService aiService,
  Set<String> existingTitlesNormalized = const {},
  String? languageCode,
  PoiRepository? poiRepository,
}) async {
  final pool = await gatherCandidatesForTrip(
    trip: trip,
    hotels: hotels,
    geocoder: geocoder,
    nearbyService: nearbyService,
    languageCode: languageCode,
    poiRepository: poiRepository,
  );
  if (pool.isEmpty) {
    debugPrint(
      '[places_first] CoPilot Places-first : pool vide, rien à proposer',
    );
    return [];
  }

  // Pré-filtre : retire de chaque DayCandidates les candidats dont le name
  // matche un titre déjà au planning. Évite de reproposer.
  if (existingTitlesNormalized.isNotEmpty) {
    String norm(String s) =>
        s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final day in pool) {
      day.byInterest.forEach((interest, list) {
        list.removeWhere(
          (c) => existingTitlesNormalized.contains(norm(c.name)),
        );
      });
    }
  }

  final groups = groupDaysByCenter(pool);
  // K-means clustering par quartier (mode coPilot : pool min plus large
  // pour avoir 3 alternatives par créneau).
  final clusters = partitionByQuartier(groups, coPilotMode: true);
  debugPrint(
    '[places_first] CoPilot Places-first : ${groups.length} groupe(s) géo → ${clusters.length} cluster(s) après K-means',
  );

  final travelerProfile = trip.travelerType != null
      ? travelerPlacesProfiles[trip.travelerType]
      : null;

  // Appels Gemini en parallèle, un par cluster. Chaque échec individuel
  // ne casse pas les autres (try/catch isolé par cluster).
  final results = await Future.wait(
    clusters.map((group) async {
      final prompt = buildCoPilotPrompt(
        input: group,
        trip: trip,
        travelerProfile: travelerProfile,
      );
      try {
        final raw = await aiService.generateRaw(
          prompt: prompt,
          cacheAction: 'places_first_copilot',
          cacheKey: prompt.hashCode.toString(),
          temperature: 0.6,
        );
        return parseCoPilotResponse(rawJson: raw, input: group);
      } catch (e) {
        debugPrint(
          '[places_first] CoPilot Places-first : Gemini exception sur groupe ${group.center.source} : $e',
        );
        return <SuggestionGroup>[];
      }
    }),
  );

  final merged = results.expand((g) => g).toList();
  debugPrint(
    '[places_first] CoPilot Places-first : ${merged.length} SuggestionGroup au total',
  );
  return merged;
}

/// Construit le prompt Gemini pour un groupe de jours en mode Auto.
/// Différence avec CoPilot : on demande une liste plate d'activités (5-8 par
/// jour étalées sur la journée), 1 option par activité (pas 3). La pool est
/// la même structure que CoPilot. Le `category` filtre les types attendus
/// (tout / restos uniquement / activités hors repas).
String buildAutoPrompt({
  required PlacesPromptInput input,
  required Trip trip,
  required TravelerPlacesProfile? travelerProfile,
  required SuggestionCategory category,
}) {
  final entries = _trimPool(input.pool);
  // Catalogue avec coordonnées géographiques : Gemini peut raisonner sur la
  // proximité (différence lat ≈ 111 km/° ; différence lng ≈ 73 km/° en France
  // métropolitaine) pour ordonner ses choix par cluster, sans calcul exact.
  final catalogLines = <String>[];
  for (var i = 0; i < entries.length; i++) {
    final c = entries[i].value.candidate;
    final interests = entries[i].value.matchedInterests.join(', ');
    final addr = c.address ?? '';
    final typesShort = c.types.take(3).join(', ');
    catalogLines.add(
      'P$i: ${c.name} (${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}) — $addr [$typesShort] ★${c.rating} (${c.userRatingCount ?? 0} avis) — match: $interests',
    );
  }
  final dayLines = input.days.map(_iso).join(', ');
  final hasKids = trip.travelers.any((t) => t.age < 13);
  final travelers = trip.travelers.isEmpty
      ? 'solo'
      : trip.travelers.map((t) => '${t.name} (${t.age} ans)').join(', ');

  // Distance max activités successives : injectée dans la consigne proximité
  // ci-dessous si le profil voyageur en spécifie une (Senior 300m, Famille
  // 1000m, etc.). Le facteur transport local de l'utilisateur (walk → ×0.7,
  // taxi → ×1.5...) est appliqué pour aligner la consigne avec le scoring
  // déterministe en aval.
  final maxConsecDist = travelerProfile?.maxConsecutiveDistanceMeters == null
      ? null
      : effectiveMaxConsecutiveDistance(
          travelerProfile: travelerProfile,
          localTransportMode: trip.localTransportMode,
        );
  final profileBlock = travelerProfile == null
      ? ''
      : '\nProfil voyageur "${trip.travelerType}" : ${travelerProfile.rule ?? "—"}'
            '${travelerProfile.maxActivityMinutes != null ? "\nDurée max par activité : ${travelerProfile.maxActivityMinutes} min." : ""}';

  // Guidance par catégorie. La pool est déjà filtrée par catégorie au niveau
  // de `runAutoPlacesFirst` (interestsOverride). Les consignes ci-dessous
  // structurent le RYTHME et le VOLUME de chaque journée.
  // Volume adapté au profil voyageur. Senior/Chill ont un rythme tranquille
  // (2-3 activités/jour) ; profils standards 4-5. Pour `category=all` les
  // repas (déjeuner+dîner) sont insérés en sus, pas comptés ici.
  final maxPerDay = travelerProfile?.maxActivitiesPerDay;
  final volumeRangeAll = maxPerDay != null
      ? 'EXACTEMENT $maxPerDay activités NON-ALIMENTAIRES par jour (rythme adapté au profil "${trip.travelerType}")'
      : 'EXACTEMENT 4 ou 5 activités NON-ALIMENTAIRES par jour';
  final volumeMinAll = maxPerDay != null
      ? 'MINIMUM ${math.max(2, maxPerDay - 1)} activités par jour'
      : 'MINIMUM 3 activités par jour';

  final categoryGuidance = switch (category) {
    SuggestionCategory.all =>
      '''
🍽️ REPAS : ne propose AUCUN restaurant, café, brasserie, bistrot, bakery, food court ou bar à manger. Le code insère automatiquement déjeuner (12h30) et dîner (19h30) après ta réponse, en sélectionnant le meilleur restaurant proche de tes activités. Tu te concentres uniquement sur les VISITES & ACTIVITÉS.

Pour CHAQUE jour, sélectionne $volumeRangeAll étalées sur la journée :
- Matin (9h-11h30) : 1-2 activités (visite, balade, marché, culture, monument)
- Après-midi (14h-18h) : 1-3 activités (visite, shopping, nature, wellness, parc)
- Soirée (21h+) : 0-1 activité (concert, événement, spectacle) — uniquement si profil compatible (pas si enfants)

⚠️ $volumeMinAll. Varie les types d'activités dans la même journée et les choix entre les jours.''',
    SuggestionCategory.restaurants =>
      '''
Pour CHAQUE jour, sélectionne 2 à 3 repas étalés :
- Petit-déjeuner (8h-10h) : optionnel, seulement si la pool contient des cafés/bakeries
- Déjeuner (12h-13h30) : 1 restaurant
- Dîner (19h-21h) : 1 restaurant
Varie le style et la gamme entre les jours. Pas de doublon sur la durée du voyage si possible.''',
    SuggestionCategory.activities =>
      '''
Pour CHAQUE jour, sélectionne EXACTEMENT 4 à 6 activités NON ALIMENTAIRES étalées :
- Matin (9h-12h) : 1-2 activités
- Après-midi (14h-18h) : 2-3 activités
- Soirée (19h+) : 0-1 activité (bar, événement) si profil compatible
⚠️ MINIMUM 4 par jour. Varie les types et évite les répétitions entre jours.''',
  };

  // Consigne proximité géographique. Avec les lat/lng dans le catalogue,
  // Gemini peut estimer la distance entre 2 lieux. La règle est plus stricte
  // pour les profils qui exigent peu de marche (Senior).
  final proximityRule = maxConsecDist != null
      ? '''🗺️ PROXIMITÉ GÉOGRAPHIQUE — RÈGLE ABSOLUE pour le profil "${trip.travelerType}" :
- Chaque lieu du catalogue a ses coordonnées entre parenthèses (lat,lng).
- Distance approximative : 0.001° de lat ≈ 111m, 0.001° de lng ≈ 73m (France).
- Pour CHAQUE jour, ORDONNE tes activités successives par PROXIMITÉ géographique stricte.
- INTERDIT de proposer 2 activités successives à plus de ${maxConsecDist}m l'une de l'autre.
- Préfère 5 activités proches dans un même quartier plutôt que 7 dispersées qui dépasseraient ${maxConsecDist}m.
- Si la pool ne te permet pas de tenir cette règle pour un créneau, SAUTE ce créneau.'''
      : '''🗺️ PROXIMITÉ GÉOGRAPHIQUE :
- Chaque lieu du catalogue a ses coordonnées entre parenthèses (lat,lng).
- Pour CHAQUE jour, ordonne tes activités par cluster géographique cohérent (≤800m entre activités successives idéalement).''';

  // Accommodation : ancrage géographique non contraignant. Mentionné dans le
  // prompt si présent (cf. brief Lalith 2026-05-08 — ne pas forcer toutes
  // les activités à proximité, juste éviter les journées dispersées).
  final accommodationLine = trip.accommodation != null
      ? '\n- Hébergement : ${trip.accommodation!.name}'
            '${trip.accommodation!.address != null && trip.accommodation!.address!.isNotEmpty ? " · ${trip.accommodation!.address}" : ""}'
      : '';

  // Définitions Lunao des intérêts (terminologie produit). Sans ça Gemini
  // interprète "Hors circuit" / "Bons plans" génériquement et la qualité
  // de matching baisse. Limite aux intérêts sélectionnés pour économiser
  // les tokens.
  final interestList = trip.interests ?? const <String>[];
  final interestDefinitionsBody = interestList
      .map(
        (i) => interestExplanations[i] != null
            ? '- $i : ${interestExplanations[i]}'
            : '- $i',
      )
      .join('\n');
  final interestDefinitions = interestList.isEmpty
      ? ''
      : '\n\nDéfinitions Lunao des centres d\'intérêt sélectionnés :\n$interestDefinitionsBody';

  // Étapes existantes : si le voyage a déjà des étapes, c'est un circuit
  // déjà esquissé. Lunao doit compléter, pas repartir de zéro. Cf. brief
  // Lalith 2026-05-08.
  final hasSegments = trip.itinerarySegments.isNotEmpty;
  final segmentsBlock = hasSegments
      ? '\n\n📍 ÉTAPES DÉJÀ DÉFINIES POUR CE VOYAGE — contexte fort :\n'
            '${trip.itinerarySegments.map((s) => "- ${s.city}${s.country != null ? " (${s.country})" : ""} · ${s.days} jour${s.days > 1 ? 's' : ''}").join('\n')}\n'
            'Ces étapes sont des contraintes : ne repars pas de zéro. '
            'Privilégie les activités cohérentes géographiquement avec '
            'l\'étape du jour, et complète/ajuste l\'itinéraire au lieu '
            'de le reconstruire.'
      : '';

  return '''
Tu es un expert en voyages. Tu dois SÉLECTIONNER (pas inventer) des activités pour un voyageur, en t'appuyant UNIQUEMENT sur la liste de lieux RÉELS ci-dessous (tous vérifiés sur Google Places).

🚫 RÈGLE ABSOLUE : tu ne peux UTILISER QUE les lieux du catalogue, identifiés par leur référence (P0, P1, ...). Tu n'as PAS le droit d'en inventer d'autres ou de modifier les noms. Si la pool ne contient pas un type de lieu pour un créneau (ex: pas de bar pour "Soirée"), saute ce créneau.

🚫 LIEUX INTERDITS — ne JAMAIS proposer même s'ils sont dans le catalogue :
- Bâtiments administratifs : mairies, préfectures, tribunaux, banques, bureaux de poste, centres administratifs, agences (immo, voyages).
- Bâtiments éducatifs : bibliothèques universitaires, écoles, lycées, instituts de langue (Goethe-Institut, Cervantes, Alliance française, etc.).
- Infrastructures du quotidien : stations-service, parkings, supermarchés, centres médicaux, commissariats.
EXCEPTION : si le bâtiment EST un monument touristique reconnu (ex: "Hôtel de Ville de Bruxelles" gothique brabançon classé), tu peux le proposer en Visite/Culture en précisant la valeur patrimoniale dans le titre.

Voyage :
- Destination : ${trip.destination}
- Voyageurs : $travelers${hasKids ? ' (enfants présents)' : ''}
- Centres d'intérêt : ${trip.interests?.join(', ') ?? "non précisés"}$accommodationLine$profileBlock$interestDefinitions$segmentsBlock

Jours à organiser : $dayLines (${input.days.length} jour${input.days.length > 1 ? 's' : ''}).

Catalogue de lieux disponibles autour du centre du jour (${input.center.source}, ${entries.length} lieux retenus) :
${catalogLines.join('\n')}

$categoryGuidance

$proximityRule

Pour CHAQUE activité sélectionnée :
- Choisis une heure de début réaliste (cohérente avec le type de lieu et son ouverture probable).
- Donne une `duration_minutes` réaliste (musée 60-120, repas 45-90, balade 30-60, spa 90-120).
- Donne un `price_estimate` (ex: "~12€", "Gratuit", "~25€/personne").
- Donne un `match_reason` (1 phrase) qui explique pourquoi le lieu convient à CE voyageur sur CE créneau.
- Évite de positionner deux activités sur des créneaux qui se chevauchent dans le même jour.

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "activities": [
    {"day_date": "YYYY-MM-DD", "start_time": "10:00", "ref": "P0", "duration_minutes": 90, "price_estimate": "~12€", "match_reason": "Matche ton intérêt 'Culture' + créneau matin tranquille"},
    {"day_date": "YYYY-MM-DD", "start_time": "12:30", "ref": "P5", "duration_minutes": 75, "price_estimate": "~18€", "match_reason": "..."}
  ]
}
''';
}

/// Parse la réponse Gemini d'un prompt Auto et reconstitue une liste plate
/// d'`ActivitySuggestion` consommables par le pipeline existant. Comme pour
/// CoPilot, les options sont reconstruites depuis la pool (titre canonique
/// Places, adresse, rating, lat/lng) — Gemini ne fait que choisir des refs.
List<ActivitySuggestion> parseAutoResponse({
  required String rawJson,
  required PlacesPromptInput input,
}) {
  final entries = _trimPool(input.pool);
  final byRef = <String, NearbyCandidate>{};
  for (var i = 0; i < entries.length; i++) {
    byRef['P$i'] = entries[i].value.candidate;
  }
  // Set des jours valides pour ce cluster (validation déterministe anti-
  // hallucination Gemini sur le `day_date`). Si Gemini retourne un jour hors
  // de la liste fournie en prompt → on rejette plutôt que de mettre une
  // activité Épinal sur un jour Nancy. Cf. bug 26/04 J5.
  final validDayKeys = input.days
      .map((d) => d.toIso8601String().split('T').first)
      .toSet();

  final cleaned = _stripCodeFences(rawJson).trim();
  dynamic parsed;
  try {
    parsed = jsonDecode(cleaned);
  } catch (e) {
    debugPrint('parseAutoResponse : JSON invalide — $e');
    return [];
  }
  if (parsed is! Map) return [];
  final activitiesJson = parsed['activities'] as List? ?? const [];

  final out = <ActivitySuggestion>[];
  for (final actJson in activitiesJson) {
    if (actJson is! Map) continue;
    final ref = (actJson['ref'] as String?)?.trim();
    if (ref == null) continue;
    final candidate = byRef[ref];
    if (candidate == null) {
      debugPrint('Réf inconnue "$ref" dans la réponse Auto Gemini — skip');
      continue;
    }
    final dateStr = actJson['day_date'] as String?;
    if (dateStr == null) continue;
    if (!validDayKeys.contains(dateStr)) {
      debugPrint(
        '[places_first] day_date "$dateStr" hors cluster (attendu: ${validDayKeys.join(",")}) — skip "${candidate.name}"',
      );
      continue;
    }
    final date = DateTime.tryParse(dateStr);
    if (date == null) continue;
    final startTime = (actJson['start_time'] as String?)?.trim() ?? '';
    // Filtre déterministe horaire/type Places : rejette les aberrations type
    // "bar à 12h30" sans dépendre de Gemini. Cf. _isAppropriateForTime.
    if (!_isAppropriateForTime(candidate, startTime)) {
      debugPrint(
        '[places_first] Filtre horaire : rejet "${candidate.name}" '
        '(types=${candidate.types.take(3).join(",")}) à $startTime',
      );
      continue;
    }
    final tag = _tagFromPrimaryType(
      candidate.types.isNotEmpty ? candidate.types.first : '',
    );
    out.add(
      ActivitySuggestion(
        dayDate: date,
        startTime: startTime,
        title: candidate.name,
        detail: candidate.address,
        tag: tag,
        durationMinutes: (actJson['duration_minutes'] as num?)?.toInt(),
        priceEstimate: (actJson['price_estimate'] as String?)?.trim(),
        matchReason: (actJson['match_reason'] as String?)?.trim(),
        latitude: candidate.latitude,
        longitude: candidate.longitude,
      ),
    );
  }
  return out;
}

/// Orchestre le flow Places-first pour le mode Auto bout-en-bout. **Round 2A
/// (validé Lalith 2026-04-26) : sélection 100% déterministe pour les visites,
/// Gemini totalement bypass.**
///
/// Pipeline :
/// 1. Filtre la liste d'intérêts selon la catégorie demandée.
/// 2. Récolte les candidats Places (`gatherCandidatesForTrip`, cascade walk→transit).
/// 3. Pré-filtre les candidats dont le nom matche déjà une activité au planning.
/// 4. Groupe les jours par centre géographique + K-means par quartier.
/// 5. **Sélection déterministe** des visites : pour chaque jour de chaque
///    cluster, slots fixes (selon `maxActivitiesPerDay` du profil) + scoring
///    qualité × intérêt × distance. Cf. `selectVisitsDeterministic`.
/// 6. **Insertion déterministe** des repas (déjeuner 12:30, dîner 19:30) en
///    `category=all` uniquement. Cf. `insertDeterministicMeals`.
/// 7. Concatène et retourne.
///
/// Pourquoi 0 Gemini : un LLM ne respecte pas fiablement les contraintes
/// (heure, distance, comptes, types). Avec scoring code, on garantit
/// reproductibilité, distances respectées par construction, 0 hallucination.
///
/// Note `category=restaurants` : Gemini gardé temporairement (cas peu utilisé,
/// chantier ultérieur — cf. project_open_improvements.md).
Future<List<ActivitySuggestion>> runAutoPlacesFirst({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,
  required AiSuggestionsService aiService,
  required SuggestionCategory category,
  Set<String> existingTitlesNormalized = const {},

  /// Langue Places (BCP-47). Cf. `gatherCandidatesForTrip`.
  String? languageCode,

  /// POI-2.1 — Repository POI pour enrichir le pool avec des candidats curatés.
  PoiRepository? poiRepository,
}) async {
  // V7 (Lalith 2026-05-10 — Phase Cost-1) — budget Places scopé à la
  // run. Cf. runCoPilotPlacesFirst pour la motivation.
  nearbyService.startRun(tripId: trip.id);
  try {
    return await _runAutoPlacesFirstBody(
      trip: trip,
      hotels: hotels,
      geocoder: geocoder,
      nearbyService: nearbyService,
      aiService: aiService,
      category: category,
      existingTitlesNormalized: existingTitlesNormalized,
      languageCode: languageCode,
      poiRepository: poiRepository,
    );
  } finally {
    nearbyService.endRun(context: 'auto/${category.name}');
  }
}

Future<List<ActivitySuggestion>> _runAutoPlacesFirstBody({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,
  required AiSuggestionsService aiService,
  required SuggestionCategory category,
  Set<String> existingTitlesNormalized = const {},
  String? languageCode,
  PoiRepository? poiRepository,
}) async {
  List<String>? interestsOverride;
  final tripInterests = trip.interests ?? const <String>[];
  if (category == SuggestionCategory.restaurants) {
    interestsOverride = const ['Gastronomie'];
  } else if (category == SuggestionCategory.activities) {
    interestsOverride = tripInterests.where((i) => i != 'Gastronomie').toList();
    if (interestsOverride.isEmpty) {
      debugPrint(
        '[places_first] Auto Places-first : intérêts non-repas vides → pool vide',
      );
      return [];
    }
  }

  final pool = await gatherCandidatesForTrip(
    trip: trip,
    hotels: hotels,
    geocoder: geocoder,
    nearbyService: nearbyService,
    interestsOverride: interestsOverride,
    languageCode: languageCode,
    poiRepository: poiRepository,
  );
  if (pool.isEmpty) {
    debugPrint('[places_first] Auto Places-first : pool vide, rien à proposer');
    return [];
  }

  if (existingTitlesNormalized.isNotEmpty) {
    String norm(String s) =>
        s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final day in pool) {
      day.byInterest.forEach((interest, list) {
        list.removeWhere(
          (c) => existingTitlesNormalized.contains(norm(c.name)),
        );
      });
    }
  }

  // Phase 4 / Tâche 4.5 — Pipeline template-first (flag-gated).
  // Court-circuit total quand `useDayTemplates == false` :
  // comportement strictement pré-4.5. Quand le flag est ON et
  // que la destination a une DI + des templates connus
  // localement, tente le pipeline template-first. Si le résultat
  // est jugé utilisable, retourne (+ meals inserés via le helper
  // legacy `insertDeterministicMeals`). Sinon fallback complet
  // vers la logique legacy (groupDaysByCenter +
  // selectVisitsDeterministic).
  //
  // Activable via `--dart-define=USE_DAY_TEMPLATES=true`.
  //
  // Cette branche n'est exécutée QUE pour `category == all`
  // (visites + repas). Pour `category == restaurants` (legacy
  // Gemini path) et `category == activities` (visites seules),
  // la logique existante est conservée — le template-first ne
  // s'applique pas en 4.5.
  if (category == SuggestionCategory.all) {
    final templateFlags = FeatureFlags.fromEnvironment();
    if (templateFlags.useDayTemplates) {
      final tfDi = lookupLocalDestinationIntelligence(trip.destination);
      final tfTemplates = loadLocalDayTemplatesForDestination(trip.destination);
      if (tfDi != null && tfTemplates.isNotEmpty) {
        final tfComplexGroups = loadLocalComplexGroupsForDestination(
          trip.destination,
        );
        final tfResult = tryTemplateFirstPipeline(
          trip: trip,
          di: tfDi,
          templates: tfTemplates,
          pool: pool,
          complexGroups: tfComplexGroups,
        );
        if (tfResult.isUsable) {
          debugPrint(
            '[template_first_pipeline] using template-first '
            '${tfResult.activities.length} visits destination='
            '"${trip.destination}"',
          );
          final tfMerged = <ActivitySuggestion>[...tfResult.activities];
          // Insertion repas via le helper legacy. Réutilise le pool
          // déjà fetché + le service nearbyService déjà en scope.
          final tfTravelerProfile = trip.travelerType != null
              ? travelerPlacesProfiles[trip.travelerType]
              : null;
          final tfMealsBudgetCap = priceLevelCapForBudget(
            budgetPerPersonEur: trip.budgetPerPersonEur,
            durationDays: trip.durationDays,
          );
          final tfMeals = await insertDeterministicMeals(
            activities: tfMerged,
            pool: pool,
            nearbyService: nearbyService,
            travelerProfile: tfTravelerProfile,
            tripInterests: tripInterests,
            languageCode: languageCode,
            localTransportMode: trip.localTransportMode,
            budgetPriceCap: tfMealsBudgetCap,
          );
          tfMerged.addAll(tfMeals);
          debugPrint(
            '[template_first_pipeline] +${tfMeals.length} meals '
            'inserted via legacy helper, total ${tfMerged.length}',
          );
          return tfMerged;
        }
        debugPrint(
          '[template_first_fallback] reason='
          '${tfResult.fallbackReason} destination='
          '"${trip.destination}"',
        );
      } else {
        debugPrint(
          '[template_first_fallback] reason=missing_di_or_templates '
          'destination="${trip.destination}"',
        );
      }
    }
  }

  final groups = groupDaysByCenter(pool);
  final clusters = partitionByQuartier(groups);

  final travelerProfile = trip.travelerType != null
      ? travelerPlacesProfiles[trip.travelerType]
      : null;

  // ─── category=restaurants : LEGACY Gemini (chantier ultérieur) ──────
  // Gardé temporairement pour ne pas régresser le cas "Suggérer restos seuls".
  // À porter en déterministe dans une prochaine itération (ex: top N restos
  // par jour, scoring qualité × diversité culinaire).
  if (category == SuggestionCategory.restaurants) {
    debugPrint(
      '[places_first] Auto Places-first (restos legacy Gemini) : ${groups.length} groupe(s) → ${clusters.length} cluster(s)',
    );
    final results = await Future.wait(
      clusters.map((group) async {
        final prompt = buildAutoPrompt(
          input: group,
          trip: trip,
          travelerProfile: travelerProfile,
          category: category,
        );
        try {
          final raw = await aiService.generateRaw(
            prompt: prompt,
            cacheAction: 'places_first_auto',
            cacheKey: prompt.hashCode.toString(),
            temperature: 0.7,
          );
          return parseAutoResponse(rawJson: raw, input: group);
        } catch (e) {
          debugPrint(
            '[places_first] Auto Places-first restos : Gemini exception ${group.center.source} : $e',
          );
          return <ActivitySuggestion>[];
        }
      }),
    );
    return results.expand((s) => s).toList();
  }

  // ─── Sélection déterministe des visites (Round 2A — 0 Gemini) ───────
  // Pour `category=all` on retire les types repas de la pool : le sélecteur
  // ne propose que des visites, les repas sont insérés ensuite par scoring
  // séparé. Pour `category=activities` la pool est déjà sans repas (filtre
  // interestsOverride en amont).
  final clustersForVisits = category == SuggestionCategory.all
      ? clusters.map(_filterOutMealTypes).toList()
      : clusters;
  debugPrint(
    '[places_first] Auto Places-first : ${groups.length} groupe(s) géo → ${clusters.length} cluster(s), category=${category.name} '
    '(sélecteur déterministe — 0 Gemini)',
  );

  // Phase 2 / Tâche 2.4 + Phase 3 / Tâche 3.2 — flag-aware
  // câblage. Default tout OFF (cf. `FeatureFlags.defaults()`).
  // Activables via :
  //   --dart-define=USE_SAME_COMPLEX_DEDUP=true
  //   --dart-define=USE_DESTINATION_SCOPE=true
  // Lookups registry **toujours faits** (no-op si flag OFF,
  // court-circuité dans le sélecteur).
  final featureFlags = FeatureFlags.fromEnvironment();
  final complexGroupsForTrip = loadLocalComplexGroupsForDestination(
    trip.destination,
  );
  final destinationIntelligenceForTrip = lookupLocalDestinationIntelligence(
    trip.destination,
  );
  final visits = selectVisitsDeterministic(
    clusters: clustersForVisits,
    trip: trip,
    travelerProfile: travelerProfile,
    existingTitlesNormalized: existingTitlesNormalized,
    useSameComplexDedup: featureFlags.useSameComplexDedup,
    complexGroups: complexGroupsForTrip,
    useDestinationScope: featureFlags.useDestinationScope,
    destinationIntelligence: destinationIntelligenceForTrip,
  );
  debugPrint(
    '[places_first] Auto Places-first : ${visits.length} visites sélectionnées',
  );

  final merged = <ActivitySuggestion>[...visits];

  // Insertion déterministe des repas en category=all uniquement.
  if (category == SuggestionCategory.all) {
    final mealsBudgetCap = priceLevelCapForBudget(
      budgetPerPersonEur: trip.budgetPerPersonEur,
      durationDays: trip.durationDays,
    );
    final meals = await insertDeterministicMeals(
      activities: merged,
      pool: pool,
      nearbyService: nearbyService,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      languageCode: languageCode,
      localTransportMode: trip.localTransportMode,
      budgetPriceCap: mealsBudgetCap,
    );
    merged.addAll(meals);
  }

  debugPrint(
    '[places_first] Auto Places-first : ${merged.length} ActivitySuggestion au total (${visits.length} visites + ${merged.length - visits.length} repas)',
  );
  return merged;
}
