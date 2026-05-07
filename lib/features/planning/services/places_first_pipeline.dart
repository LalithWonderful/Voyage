import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/interests_to_places_mapping.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

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
  'salle de spectacle': {
    'performing_arts_theater', 'event_venue', 'cultural_center',
    'live_music_venue', 'movie_theater', 'convention_center',
  },
  'salle de concert': {
    'performing_arts_theater', 'event_venue', 'live_music_venue',
    'cultural_center', 'movie_theater',
  },
  'theatre': {
    'performing_arts_theater', 'event_venue', 'cultural_center',
  },
  'concert': {
    'performing_arts_theater', 'event_venue', 'live_music_venue',
    'cultural_center',
  },
  'cinema': {
    'movie_theater',
  },
  'spectacle': {
    'performing_arts_theater', 'event_venue', 'cultural_center',
    'live_music_venue',
  },
};

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
bool _isProfileQueryCompatibleWithInterest(String query, String interest) {
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
  final kept = <NearbyCandidate>[];
  for (final c in results) {
    final nameNorm = _normalizeForMatch(c.name);
    final matched = queryWords.any((qw) => nameNorm.contains(qw));
    final primaryType = c.types.isNotEmpty ? c.types.first : '?';
    final matchedByStrongType =
        strongTypes != null && strongTypes.contains(primaryType);
    if (matched) {
      kept.add(c);
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✓ "${c.name}" '
        'type=$primaryType addr="${c.address}" '
        '@${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}',
      );
    } else if (matchedByStrongType) {
      kept.add(c);
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✓ (via type fort '
        '$primaryType) "${c.name}" addr="${c.address}" '
        '@${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}',
      );
    } else {
      debugPrint(
        '[places_first_match] interest=$interest q="$textQuery" ✗ rejeté "${c.name}" '
        'type=$primaryType addr="${c.address}" — aucun mot de la query '
        '(${queryWords.join(",")}) dans le name',
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
  'valley', 'vallée',
  'cascades', 'waterfall', 'cascade',
  'desert tour', 'sahara', 'sahara tour', 'merzouga', 'erg chebbi',
  'day trip', 'daytrip', 'day-trip',
  'excursion', 'guided tour', 'shore excursion',
  'atlas mountains', 'atlas tour', 'haut atlas',
  '4x4 tour', 'quad tour', 'quad bike',
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

bool _isExcludedPlace(NearbyCandidate c) {
  if (c.types.isEmpty) return false;
  if (_blacklistedPlaceIds.contains(c.placeId)) return true;
  if (c.types.any(_hardExcludedAnyTypes.contains)) return true;
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
              .where((q) => _isProfileQueryCompatibleWithInterest(q, interest))
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
        calls.add(
          nearbyService
              .searchText(
                textQuery: tq,
                latitude: center.latitude,
                longitude: center.longitude,
                radius: radius,
                languageCode: languageCode,
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
        final r = c.rating;
        if (r == null || r < placesGlobalMinRating) return false;
        if (!query.matchesFilters(c)) return false;
        if (_isExcludedPlace(c)) return false;
        return true;
      }).toList();
      byInterest[interest] = filtered;
    }
    return byInterest;
  }

  // Traitement parallèle par jour. Le cache places_search dédoublonne les
  // appels redondants quand plusieurs jours partagent le même centre.
  final results = await Future.wait(
    days.map((day) async {
      final center = await centerForDay(
        trip: trip,
        day: day,
        hotels: hotels,
        geocoder: geocoder,
      );
      if (center == null) {
        debugPrint('Jour ${_iso(day)} : centre non géocodable, skip');
        return null;
      }

      // 1. Récolte walking (zone de marche prioritaire)
      final byInterest = await collectByInterest(center, walkRadius);

      // 2. Cascade transit TOUJOURS appliquée (Lalith 26/04) : sans ça, des
      // attractions majeures comme Musée de l'Image Épinal (~1km du centre) ou
      // Imagerie d'Épinal (~2km) sont absentes de la pool. Les lieux walking
      // restent prioritaires via le scoring distance ; transit ne fait
      // qu'enrichir avec des candidats plus distants (utiles si profil sans
      // contrainte stricte ou si pool walking pauvre culturellement).
      if (transitRadius != null) {
        final walkUniqueCount = byInterest.values
            .expand((l) => l)
            .map((c) => c.placeId)
            .toSet()
            .length;
        final byInterestTransit = await collectByInterest(
          center,
          transitRadius,
        );
        for (final entry in byInterestTransit.entries) {
          final walkList = byInterest[entry.key] ?? const <NearbyCandidate>[];
          final walkIds = walkList.map((c) => c.placeId).toSet();
          final added = entry.value
              .where((c) => !walkIds.contains(c.placeId))
              .toList();
          if (added.isNotEmpty) {
            byInterest[entry.key] = [...walkList, ...added];
          }
        }
        final totalAfter = byInterest.values
            .expand((l) => l)
            .map((c) => c.placeId)
            .toSet()
            .length;
        debugPrint(
          '[places_first] ${_iso(day)} : walk=$walkUniqueCount → +${totalAfter - walkUniqueCount} via transit (${transitRadius}m)',
        );
      }

      return DayCandidates(day: day, center: center, byInterest: byInterest);
    }),
  );

  final pool = results.whereType<DayCandidates>().toList();
  final totalUnique = pool.fold<int>(0, (sum, d) => sum + d.uniqueCandidates);
  debugPrint(
    '[places_first] Récolte terminée : ${pool.length} jours, $totalUnique lieux uniques cumulés',
  );
  return pool;
}

String _iso(DateTime d) => d.toIso8601String().split('T').first;

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

/// Cherche le meilleur restaurant à proximité d'un point d'ancrage (= une
/// activité de la journée). Filtres déterministes (Lalith 26/04) :
/// - rating ≥ profile.minRating (boost +0.1 si "Gastronomie" dans intérêts)
/// - userRatingCount ≥ profile.minUserRatingCount ?? 30
/// - profile.minPriceLevel/maxPriceLevel respectés (Grand luxe ≥3, etc.)
/// - rejet types fast food (`_fastFoodPrimaryTypes`)
/// - rejet types blacklist général (`_isExcludedPlace`)
/// - rejet titres déjà au planning (anti-doublon)
/// - rejet primary types déjà utilisés pour le déjeuner (diversité midi/soir)
/// - tri final par score qualité (rating × log(userRatingCount))
///
/// Retourne null si aucun candidat ne passe — l'appelant skip le créneau.
Future<NearbyCandidate?> _findBestRestoNear({
  required PlacesNearbyService nearbyService,
  required double latitude,
  required double longitude,
  required int radius,
  required String? languageCode,
  required TravelerPlacesProfile? travelerProfile,
  required List<String> tripInterests,
  Set<String> excludeTitlesNorm = const {},
  Set<String> excludePrimaryTypes = const {},

  /// Titres déjà utilisés sur le voyage : pénalisés fortement dans le score
  /// (-50 par usage) pour favoriser la variété SANS être bloqués dur. Si
  /// la pool est petite, ils peuvent quand même remonter.
  Map<String, int> softExcludeTitlesUseCount = const {},

  /// Cap maximum de `priceLevel` Places dérivé du budget par personne du
  /// voyage (cf. `priceLevelCapForBudget`). Si défini, restreint le
  /// `maxPrice` effectif au minimum entre celui du profil voyageur et ce
  /// cap. Lieux sans priceLevel toujours conservés.
  int? budgetPriceCap,
}) async {
  // Cascade distance pour restos : si rien à `radius`, on étend à 2× puis 4×.
  // Évite J1 sans repas quand le top resto est à 250m mais radius = 240m (cas
  // Senior avec maxConsec=300m × 0.8). On garde le radius initial comme cible
  // mais on autorise plus loin si pool vide.
  List<NearbyCandidate> candidates = const [];
  for (final mult in const [1.0, 2.0, 4.0]) {
    final r = (radius * mult).round();
    candidates = await nearbyService.searchNearby(
      latitude: latitude,
      longitude: longitude,
      includedTypes: const ['restaurant', 'cafe', 'bakery'],
      radius: r,
      maxResults: 20,
      languageCode: languageCode,
    );
    if (candidates.isNotEmpty) break;
  }

  // Seuils effectifs : profil voyageur + boost Gastronomie + plancher 4.0
  // Boost +0.2 + minReviews ×2 si Gastronomie. Et surtout `minPriceLevel ≥ 2`
  // si Gastronomie : les fast food (Chinexpress, Istanbul Kebab, FIVE TACOS,
  // Harlem Smash...) sont priceLevel 1, les vrais restos ≥2. Filtre robuste
  // qui élimine TOUS les fast food sans toucher aux bons restos. Validé 26/04
  // après tests Lalith.
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
  // Boost minPriceLevel à 2 si Gastronomie (sauf si profil vise déjà le
  // bon marché : Backpack/Meilleur prix avec maxPriceLevel ≤ 1).
  // maxPrice : croise le profil voyageur ET le cap budget user — on prend
  // le minimum (le plus restrictif des deux) si les 2 sont définis.
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
  final filtered = candidates.where((c) {
    if (c.rating == null || c.rating! < effectiveMinRating) return false;
    if ((c.userRatingCount ?? 0) < effectiveMinReviews) return false;
    if (_isExcludedPlace(c)) return false;
    // Strict primary meal : élimine les faux positifs Places (Marché Central
    // tagué `florist` primary mais retourné par searchNearby car `bakery` en
    // secondaire). Un vrai resto a un primary `restaurant`/`cafe`/`bakery`.
    if (!_isMealPrimaryType(c)) return false;
    if (c.types.isNotEmpty && _fastFoodPrimaryTypes.contains(c.types.first)) {
      return false;
    }
    if (fastFoodChainRegex.hasMatch(c.name)) return false;
    if (excludeTitlesNorm.contains(norm(c.name))) return false;
    // Diversité : exclut le style cuisine du déjeuner pour ne pas re-proposer
    // le même type au dîner (ex: japanese_restaurant midi → exclut au soir).
    if (c.types.isNotEmpty && excludePrimaryTypes.contains(c.types.first)) {
      return false;
    }
    if (minPrice != null && c.priceLevel != null && c.priceLevel! < minPrice) {
      return false;
    }
    if (maxPrice != null && c.priceLevel != null && c.priceLevel! > maxPrice) {
      return false;
    }
    return true;
  }).toList();
  if (filtered.isEmpty) return null;

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

  filtered.sort((a, b) => score(b).compareTo(score(a)));
  return filtered.first;
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
}) {
  final maxPerDay = travelerProfile?.maxActivitiesPerDay ?? 4;
  final slots = _visitSlotsForCount(maxPerDay);
  // Distance max entre 2 activités successives. Croise profil voyageur ET
  // préférence transport local de l'utilisateur (walk → ×0.7, taxi → ×1.5,
  // etc.). Si profil sans contrainte explicite, fallback 1500m.
  final maxConsec = effectiveMaxConsecutiveDistance(
    travelerProfile: travelerProfile,
    localTransportMode: trip.localTransportMode,
  );
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

  // Set de clés de dédup global au voyage : un même lieu (placeId, ou
  // fallback name+coords arrondies) ne peut apparaître qu'une seule fois
  // dans tout l'itinéraire. Évite les doublons entre clusters non
  // connectés par le `useCountThisCluster` (cas observé Lalith
  // 2026-05-08 : Plage d'Essaouira / Hammam Kenza / Sidi Magdoul Hammam
  // pickés à la fois le 15/05 et le 17/05 dans le même cluster mais
  // qui s'évite via cluster — et pareil entre 2 clusters Essaouira).
  final selectedDedupKeys = <String>{};

  // 3 niveaux de cap : par jour (max 1×, strict), par cluster (max 2×),
  // ET par voyage (compteur global pour pénaliser dans le scoring).
  // Le compteur global évite J6 = J1/J3 quand 2 clusters proches ont des
  // lieux communs (Place Stanislas dans cluster hôtel ET cluster segment).
  const maxReusePerCluster = 2;
  final useCountAcrossTrip = <String, int>{};
  for (final cluster in clusters) {
    final useCountThisCluster = <String, int>{};
    final entries = cluster.pool.entries.toList();

    for (final day in cluster.days) {
      final usedThisDay = <String>{};
      ActivitySuggestion? lastActivity;

      for (final slot in slots) {
        // Ancrage : activité précédente du jour, ou centre du cluster pour le 1er slot.
        final anchorLat = lastActivity?.latitude ?? cluster.center.latitude;
        final anchorLng = lastActivity?.longitude ?? cluster.center.longitude;

        // Filtres durs (sans distance pour le moment)
        final baseCandidates = entries.where((e) {
          final c = e.value.candidate;
          if (!_isAppropriateForTime(c, slot)) return false;
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
          return true;
        }).toList();

        if (baseCandidates.isEmpty) {
          // Diagnostic : pourquoi aucun candidat ne passe les filtres durs ?
          var rejectTime = 0, rejectMeal = 0, rejectExisting = 0;
          var rejectCity = 0, rejectDay = 0, rejectReuse = 0, rejectIconic = 0;
          var rejectDup = 0;
          for (final e in entries) {
            final c = e.value.candidate;
            if (!_isAppropriateForTime(c, slot)) {
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
          }
          debugPrint(
            '[places_first] ⚠️ ${day.toIso8601String().split("T").first} slot $slot : 0 candidat sur ${entries.length} '
            '(rejet horaire=$rejectTime, repas=$rejectMeal, existant=$rejectExisting, ville=$rejectCity, déjà-pris-voyage=$rejectDup, déjà-jour=$rejectDay, sur-utilisé=$rejectReuse, iconic-déjà-vu=$rejectIconic)',
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
          // Distance penalty renforcée (×8 au lieu de ×5) — décourage les
          // transitions longues qui forcent taxi/voiture pour Senior.
          final distancePenalty = (d / maxConsec) * 8.0;
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
          return qualityScore +
              interestBonus +
              iconicMuseumBonus +
              iconicTouristBonus -
              distancePenalty -
              diversityPenalty;
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
        lastActivity = out.last;
      }
    }
  }
  debugPrint(
    '[places_first] Sélecteur déterministe : ${out.length} visites sélectionnées '
    '(${clusters.length} clusters × max $maxPerDay/jour)',
  );
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
  if (primaryType == 'shopping_mall' || primaryType.contains('store'))
    return 60;
  if (primaryType == 'spa' || primaryType == 'beauty_salon') return 90;
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

  int distMeters(double lat1, double lng1, double lat2, double lng2) {
    final dLat = (lat1 - lat2) * 111000;
    final dLng = (lng1 - lng2) * 73000;
    return math.sqrt(dLat * dLat + dLng * dLng).round();
  }

  final out = <ActivitySuggestion>[];

  // Cap dur 2× sur les restos (fallback si pool petite). La diversification
  // active passe par le `softExcludeTitlesUseCount` envoyé à _findBestRestoNear
  // qui pénalise -50 par usage : un resto jamais utilisé écrase un resto déjà
  // utilisé. Mais si pool maigre, le 2e usage reste possible.
  const maxRestoUsesAcrossTrip = 2;
  final restoUseCount = <String, int>{};
  final cuisineUseCount = <String, int>{};

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

    var lunch = await _findBestRestoNear(
      nearbyService: nearbyService,
      latitude: lunchLat,
      longitude: lunchLng,
      radius: mealRadius,
      languageCode: languageCode,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      excludePrimaryTypes: cuisinesUsedTrip,
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
    );
    // Fallback : si exclusion cuisines a vidé la pool, retry sans.
    lunch ??= await _findBestRestoNear(
      nearbyService: nearbyService,
      latitude: lunchLat,
      longitude: lunchLng,
      radius: mealRadius,
      languageCode: languageCode,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
    );

    String? lunchPrimaryType;
    if (lunch != null) {
      lunchPrimaryType = lunch.types.isNotEmpty ? lunch.types.first : null;
      final dM = distMeters(
        lunchLat,
        lunchLng,
        lunch.latitude,
        lunch.longitude,
      );
      out.add(
        ActivitySuggestion(
          dayDate: dayCenter.day,
          startTime: '12:30',
          title: lunch.name,
          detail: lunch.address,
          tag: 'Repas',
          durationMinutes: 75,
          priceEstimate: priceFromLevel(lunch.priceLevel),
          matchReason:
              'Top noté ★${lunch.rating} (${lunch.userRatingCount ?? 0} avis), à ${dM}m de "$lunchAnchorLabel"',
          latitude: lunch.latitude,
          longitude: lunch.longitude,
        ),
      );
      final lunchKey = norm(lunch.name);
      excludeTitles.add(lunchKey);
      restoUseCount[lunchKey] = (restoUseCount[lunchKey] ?? 0) + 1;
      if (lunchPrimaryType != null) {
        cuisineUseCount[lunchPrimaryType] =
            (cuisineUseCount[lunchPrimaryType] ?? 0) + 1;
      }
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

    var dinner = await _findBestRestoNear(
      nearbyService: nearbyService,
      latitude: dinnerLat,
      longitude: dinnerLng,
      radius: mealRadius,
      languageCode: languageCode,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      excludePrimaryTypes: cuisinesUsedTripForDinner,
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
    );
    // Fallback 1 : retry sans exclusion cuisines voyage (mais conserve
    // l'exclusion midi du jour pour ne pas servir 2× pareil dans la journée).
    dinner ??= await _findBestRestoNear(
      nearbyService: nearbyService,
      latitude: dinnerLat,
      longitude: dinnerLng,
      radius: mealRadius,
      languageCode: languageCode,
      travelerProfile: travelerProfile,
      tripInterests: tripInterests,
      excludeTitlesNorm: excludeTitles,
      excludePrimaryTypes: <String>{?lunchPrimaryType},
      softExcludeTitlesUseCount: restoUseCount,
      budgetPriceCap: budgetPriceCap,
    );

    if (dinner != null) {
      final dM = distMeters(
        dinnerLat,
        dinnerLng,
        dinner.latitude,
        dinner.longitude,
      );
      final dinnerPrimaryType = dinner.types.isNotEmpty
          ? dinner.types.first
          : null;
      out.add(
        ActivitySuggestion(
          dayDate: dayCenter.day,
          startTime: '19:30',
          title: dinner.name,
          detail: dinner.address,
          tag: 'Repas',
          durationMinutes: 90,
          priceEstimate: priceFromLevel(dinner.priceLevel),
          matchReason:
              'Top noté ★${dinner.rating} (${dinner.userRatingCount ?? 0} avis), à ${dM}m de "$dinnerAnchorLabel"',
          latitude: dinner.latitude,
          longitude: dinner.longitude,
        ),
      );
      final dinnerKey = norm(dinner.name);
      restoUseCount[dinnerKey] = (restoUseCount[dinnerKey] ?? 0) + 1;
      if (dinnerPrimaryType != null) {
        cuisineUseCount[dinnerPrimaryType] =
            (cuisineUseCount[dinnerPrimaryType] ?? 0) + 1;
      }
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
      primaryType.contains('bar')) {
    return 'Nightlife';
  }
  if (primaryType.contains('shop') ||
      primaryType.contains('store') ||
      primaryType == 'shopping_mall' ||
      primaryType == 'market') {
    return 'Shopping';
  }
  if (primaryType == 'spa' ||
      primaryType == 'beauty_salon' ||
      primaryType == 'gym') {
    return 'Wellness';
  }
  if (primaryType == 'church' || primaryType == 'place_of_worship') {
    return 'Culture';
  }
  if (primaryType == 'tourist_attraction' || primaryType == 'landmark') {
    return 'Visite';
  }
  if (primaryType == 'amusement_park' || primaryType == 'amusement_center') {
    return 'Loisir';
  }
  if (primaryType == 'stadium' || primaryType == 'sports_complex') {
    return 'Sport';
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
      'Spots populaires', 'Culture', 'Hors circuit', 'Événements', 'Nature'
    },
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
/// Exemples :
/// - "Pub Mac Carthy" types=[bar,pub] à 12:30 → bar:non, pub:non → REJET
/// - "Brasserie Excelsior" types=[restaurant,bar] à 12:30 → restaurant:oui → ACCEPT
/// - "Place Stanislas" types=[tourist_attraction] à 22:00 → pas géré → ACCEPT
bool _isAppropriateForTime(NearbyCandidate c, String startTime) {
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
      return hour >= 17.0;
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
    // Spas / beauté : 9h-20h
    case 'spa':
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
}) async {
  final pool = await gatherCandidatesForTrip(
    trip: trip,
    hotels: hotels,
    geocoder: geocoder,
    nearbyService: nearbyService,
    languageCode: languageCode,
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
      .map((i) => interestExplanations[i] != null
          ? '- $i : ${interestExplanations[i]}'
          : '- $i')
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

  final visits = selectVisitsDeterministic(
    clusters: clustersForVisits,
    trip: trip,
    travelerProfile: travelerProfile,
    existingTitlesNormalized: existingTitlesNormalized,
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
