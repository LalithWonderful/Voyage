import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Un hébergement (hôtel/location) avec sa période, pour un prompt Gemini
/// qui sait gérer les voyages multi-villes (plusieurs hôtels successifs).
class HotelStay {
  final String name;
  final String? address;
  final DateTime? checkIn;
  final DateTime? checkOut;
  const HotelStay({required this.name, this.address, this.checkIn, this.checkOut});
}

class AiRateLimitException implements Exception {
  final String action;
  AiRateLimitException(this.action);
  @override
  String toString() =>
      'Tu as atteint la limite d\'utilisation IA pour cette action. Réessaie dans quelques minutes.';
}

class TransportSuggestion {
  final String fromTitle;
  final String toTitle;
  final String defaultMode;
  final List<TransportOption> options;

  const TransportSuggestion({
    required this.fromTitle,
    required this.toTitle,
    required this.defaultMode,
    required this.options,
  });

  factory TransportSuggestion.fromJson(Map<String, dynamic> json) => TransportSuggestion(
    fromTitle: (json['from_title'] as String?) ?? '',
    toTitle: (json['to_title'] as String?) ?? '',
    defaultMode: (json['default_mode'] as String?) ?? 'walk',
    options: (json['options'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => TransportOption.fromJson(e))
            .toList() ??
        const [],
  );
}

class SuggestionsResult {
  /// Mode auto : liste plate d'activités, 1 par créneau, toutes cochées par défaut.
  /// Vide en mode coPilot.
  final List<ActivitySuggestion> activities;
  /// Mode coPilot : groupes par créneau, chaque groupe a 3 options alternatives,
  /// toutes décochées par défaut. Vide en mode auto.
  final List<SuggestionGroup> groups;
  /// Trajets entre activités. En mode coPilot, généré à la volée après la
  /// sélection (l'utilisateur ne sait pas à l'avance ce qu'il va cocher).
  final List<TransportSuggestion> transports;
  const SuggestionsResult({
    this.activities = const [],
    this.groups = const [],
    this.transports = const [],
  });
}

/// Catégorie de suggestion demandée par l'utilisateur via le menu "Suggérer".
/// Permet à Gemini de se concentrer sur un type précis pour plus de pertinence.
enum SuggestionCategory {
  /// Toutes catégories confondues — comportement historique.
  all,
  /// Repas uniquement (restos, cafés, street food, food tours, marchés gastro, cours de cuisine).
  restaurants,
  /// Activités hors repas (visites, culture, nature, wellness, nightlife, shopping...).
  activities,
}

/// Descriptions concrètes envoyées à Gemini pour chaque centre d'intérêt.
/// Sans ça, les labels comme "Esthétique" peuvent être interprétés de travers
/// (ex: "lieux Instagrammables" plutôt que "institut de beauté").
/// Vocabulaire choisi pour coller aux termes qu'on trouve dans les guides de voyage
/// (Lonely Planet, Routard, Fodor's...) — domaines où Gemini a le plus de contexte.
const _interestExplanations = <String, String>{
  'Randonnée': 'sentiers balisés, treks, randonnées pédestres en montagne ou forêt, parcs nationaux, GR, balades nature avec points de vue',
  'Shopping': 'boutiques de créateurs, marchés artisanaux, concept stores, friperies vintage, centres commerciaux, souvenirs authentiques et artisanat local',
  'Nightlife': 'bars à cocktails, clubs, discothèques, rooftops, speakeasies, lounges, concerts tard le soir, DJ sets, pubs locaux',
  'Spots populaires': 'sites emblématiques, monuments iconiques, attractions incontournables, points de vue célèbres, lieux très photographiés / Instagrammables',
  'Hors circuit': 'lieux peu connus des touristes, quartiers alternatifs, bars et cafés fréquentés par les habitants, pépites locales hors des sentiers battus',
  'Bons plans': 'excellents rapports qualité/prix, happy hours, menus du jour, musées gratuits certains jours, pass combinés, astuces pour économiser',
  'Wellness': 'spas, centres de bien-être, yoga, massages, thermes, hammams, saunas, onsens (Japon), bains thermaux, retraites méditation',
  'Esthétique': 'instituts de beauté, manucure/pédicure, salons de coiffure, barbershops, soins du visage, épilation, salons d\'onglerie',
  'Gastronomie': 'restaurants recommandés, food tours, cours de cuisine, spécialités locales authentiques, street food, marchés gastronomiques, dégustations',
  'Culture': 'musées, monuments historiques, sites archéologiques, patrimoine classé, galeries d\'art, théâtres, architecture remarquable',
  'Plage': 'plages, criques, baignade en mer, activités balnéaires, snorkeling, farniente, beach clubs',
  'Sports': 'sports outdoor (surf, ski, escalade, VTT, kayak, paddle), cours d\'initiation, matchs locaux au stade à aller voir, sports traditionnels du pays',
  'Nature': 'parcs naturels, jardins botaniques, observation d\'animaux, réserves naturelles, cascades, panoramas naturels, zoos et aquariums',
  'Événements': 'festivals en cours, concerts, expositions temporaires, spectacles, fêtes traditionnelles, marchés saisonniers, événements sportifs (vérifie qu\'ils ont lieu pendant les dates du voyage)',
};

/// Descriptions concrètes des types de voyageur.
/// Termes alignés sur le vocabulaire des guides/blogs voyage pour que Gemini
/// calibre bien le niveau de gamme et le style d'activités attendu.
const _travelerTypeExplanations = <String, String>{
  'Road-trip': 'itinéraires pittoresques en voiture, villages authentiques, points de vue en chemin, étapes pittoresques, relais routiers typiques, diners/cafés d\'autoroute emblématiques',
  'Grand luxe': 'lieux haut de gamme, restaurants étoilés Michelin, palaces, expériences VIP privées, spas de palace, boutiques de luxe, concierges, transferts privatifs',
  'Meilleur prix': 'activités gratuites ou bon marché (<15€/personne), restos street food ou bouis-bouis authentiques, musées gratuits, marchés, évite systématiquement les lieux chers ou étoilés',
  'Backpack': 'style sac à dos, auberges de jeunesse, activités gratuites ou très pas chères, authenticité locale, rencontres avec d\'autres voyageurs, aventure, street food',
  'En famille': 'kid-friendly, parcs d\'attractions, zoos, aquariums, musées interactifs pour enfants, activités éducatives et ludiques, trajets courts, menus enfants',
  'Voyage pro': 'restaurants business, lieux courts à visiter entre deux réunions, bars d\'hôtels, cafés coworking, options sans bagage, efficacité, ambiance calme',
};

/// Formate les préférences voyageur (type + intérêts) avec leurs descriptions
/// concrètes pour Gemini. Partagé par `_buildPrompt` (suggestions journalières)
/// et `suggestAlternatives` (alternatives pour remplacer une activité).
({String interestsStr, String travelerTypeDescribed}) _describeProfile({
  required String? travelerType,
  required List<String> interests,
}) {
  final interestsStr = interests.isEmpty
      ? 'aucun spécifié'
      : interests
          .map((i) {
            final desc = _interestExplanations[i];
            return desc != null ? '  • $i → $desc' : '  • $i';
          })
          .join('\n');
  final travelerTypeDescribed = travelerType == null
      ? 'non spécifié'
      : (_travelerTypeExplanations[travelerType] != null
          ? '$travelerType → ${_travelerTypeExplanations[travelerType]}'
          : travelerType);
  return (interestsStr: interestsStr, travelerTypeDescribed: travelerTypeDescribed);
}

class AiSuggestionsService {
  final SupabaseClient _client;
  /// Cache Gemini partagé (table `gemini_cache`). Nullable pour les usages legacy
  /// qui n'instancieraient pas le service via le provider Riverpod ; quand null,
  /// chaque appel Gemini est fait sans lookup ni upsert (= comportement d'origine).
  final GeminiCacheService? _cache;
  AiSuggestionsService(this._client, {GeminiCacheService? cache}) : _cache = cache;

  // ⚠️ DÉSACTIVÉ TEMPORAIREMENT — À RÉACTIVER AVANT PUBLICATION.
  // Passer à `true` quand la fonction Postgres `check_and_log_ai_usage` est déployée en prod.
  static const _rateLimitEnabled = false;

  // Limites par action (max appels / fenêtre de temps)
  static const _limits = <String, ({int maxPerWindow, int windowMinutes})>{
    'suggest_activities': (maxPerWindow: 10, windowMinutes: 60),
    'suggest_alternatives': (maxPerWindow: 30, windowMinutes: 60),
    'describe_activity': (maxPerWindow: 100, windowMinutes: 60),
    'describe_activities_batch': (maxPerWindow: 30, windowMinutes: 60),
    'extract_document': (maxPerWindow: 30, windowMinutes: 60),
  };

  /// Propose une boucle régionale autour d'une destination principale, pour les
  /// voyageurs qui ne connaissent pas la région et veulent que l'IA leur suggère
  /// des étapes (villes voisines, durée par étape, courte description).
  ///
  /// Exemple : Nancy 10 jours → [Nancy 3 jours, Strasbourg 3, Colmar 2, Trèves 2].
  /// Sémantique "jours" : la somme des `days` de toutes les étapes doit couvrir
  /// la durée du voyage (ex: 9 jours = somme = 9). Voir `TripSegment` pour le détail.
  /// Le caller affiche le résultat dans une sheet multi-select (cf. RegionalLoopSheet).
  Future<List<({String city, String country, int days, String description})>> suggestRegionalItinerary({
    required String mainDestination,
    required int durationDays,
    String? travelerType,
    List<String> interests = const [],
    int radiusKm = 150,
    bool sameCountryOnly = false,
    List<String> excludeCities = const [],
    int daysAlreadyPlaced = 0,
  }) async {
    // Cache : la sortie est quasi déterministe pour les mêmes inputs (mainCity,
    // durée, profil, rayon, étapes déjà placées). On normalise les listes en les
    // triant pour stabiliser la clé.
    final sortedInterests = [...interests]..sort();
    final sortedExcludes = [...excludeCities.map(GeminiCacheService.normKey)]..sort();
    final cacheKey = GeminiCacheService.hashKey([
      (k: 'main', v: GeminiCacheService.normKey(mainDestination)),
      (k: 'days', v: durationDays),
      (k: 'type', v: GeminiCacheService.normKey(travelerType ?? '')),
      (k: 'interests', v: sortedInterests),
      (k: 'radius', v: radiusKm),
      (k: 'same_country', v: sameCountryOnly),
      (k: 'exclude', v: sortedExcludes),
      (k: 'placed', v: daysAlreadyPlaced),
    ]);
    final cached = await _cache?.get('regional_itinerary', cacheKey);
    if (cached != null) {
      final segs = (cached['segments'] as List?) ?? const [];
      final result = <({String city, String country, int days, String description})>[];
      for (final s in segs) {
        if (s is! Map) continue;
        final city = (s['city'] as String?)?.trim() ?? '';
        final country = (s['country'] as String?)?.trim() ?? '';
        final days = (s['days'] as num?)?.toInt() ?? 0;
        final desc = (s['description'] as String?)?.trim() ?? '';
        if (city.isEmpty || days < 1) continue;
        result.add((city: city, country: country, days: days, description: desc));
      }
      if (result.isNotEmpty) return result;
    }

    await _checkRateLimit('suggest_regional_itinerary');
    final (:interestsStr, :travelerTypeDescribed) =
        _describeProfile(travelerType: travelerType, interests: interests);

    // On suggère le reliquat de jours non encore couvert par les étapes existantes.
    // Ne JAMAIS dépasser ce reliquat sinon le total déborde la durée du voyage et
    // l'utilisateur ne peut plus enregistrer.
    final tripDaysTotal = durationDays.clamp(1, 60);
    final remainingDays = (tripDaysTotal - daysAlreadyPlaced).clamp(1, 60);
    final totalDays = remainingDays;
    final alreadyPlacedBlock = daysAlreadyPlaced > 0
        ? '\n- ⚠️ Le voyageur a DÉJÀ placé $daysAlreadyPlaced jour${daysAlreadyPlaced > 1 ? 's' : ''} dans son planning '
            '(${excludeCities.isEmpty ? "étapes existantes" : excludeCities.join(', ')}). Tu ne dois proposer QUE des nouvelles étapes '
            'pour combler les $remainingDays jour${remainingDays > 1 ? 's' : ''} restants (sur un total de $tripDaysTotal jours de voyage).'
        : '';
    final mustIncludeMain = excludeCities
            .map((c) => c.trim().toLowerCase())
            .contains(mainDestination.trim().toLowerCase())
        ? '- ⚠️ $mainDestination est déjà dans les étapes du voyageur — NE LA REPROPOSE PAS, propose UNIQUEMENT des villes voisines.'
        : '- Inclus OBLIGATOIREMENT $mainDestination dans la boucle (avec assez de jours pour la visiter, 2-3 jours typiquement).';
    final excludeBlock = excludeCities.isEmpty
        ? ''
        : '\n- NE PROPOSE PAS ces villes (elles sont déjà dans le planning du voyageur) : ${excludeCities.join(', ')}.';
    final crossBorderRule = sameCountryOnly
        ? '''**RESTER DANS LE PAYS** : ne propose QUE des villes du même pays que $mainDestination. Pas de villes dans des pays voisins, même si elles sont dans le rayon de $radiusKm km.'''
        : '''**TRANSFRONTALIER OK** : si dans le rayon de $radiusKm km il y a des villes intéressantes dans des pays voisins, propose-les (ex: depuis Metz à 150km tu peux proposer Luxembourg-Ville, Trèves en Allemagne, Bruxelles si dans le rayon ; depuis Lille tu peux proposer Bruges). Le voyageur a fait 1000km pour son voyage, il sera ravi de découvrir un pays de plus à 100km.''';
    final prompt = '''
Tu es un expert en voyage. Le voyageur va à **$mainDestination** pour $durationDays jours et ne connaît pas la région. Propose-lui une **boucle régionale logique** de 3 à 5 étapes max dans un rayon STRICT de **$radiusKm km à vol d'oiseau autour de $mainDestination**, en incluant la destination principale + des villes intéressantes à proximité.

🚫 RAYON STRICT : aucune ville à plus de $radiusKm km de $mainDestination. Avant de proposer une ville, vérifie mentalement sa distance à vol d'oiseau (pas en temps de route). Exemples pour calibrer :
- Reims est à ~190 km de Nancy → INTERDIT si rayon ≤ 150 km
- Strasbourg est à ~125 km de Nancy → OK si rayon ≥ 150 km
- Luxembourg est à ~95 km de Nancy → OK si rayon ≥ 100 km
Si tu hésites sur la distance d'une ville, NE LA PROPOSE PAS — choisis-en une autre dont tu es sûr.

$crossBorderRule

Profil du voyageur :
- Type : $travelerTypeDescribed
- Intérêts :
$interestsStr

Contraintes :
$mustIncludeMain
- **Total des jours proposés = EXACTEMENT $totalDays** (ni plus, ni moins). Un "jour" = une journée calendaire que le voyageur passe basé dans cette ville (où il dort). N'invente pas de jours supplémentaires "au cas où".$alreadyPlacedBlock
- Étapes ordonnées géographiquement (pas d'aller-retour absurde A→B→A).
- Pour chaque étape : une ville précise (pas une région), un nombre de jours réaliste (1-4), le pays (en français, ex: "France", "Allemagne", "Belgique", "Luxembourg"), et 1 phrase courte d'accroche (ce qu'on y fait, pourquoi y aller).$excludeBlock

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "segments": [
    {"city": "Nancy", "country": "France", "days": 3, "description": "Capitale de la Lorraine, place Stanislas, vieille ville classée UNESCO"},
    {"city": "Trèves", "country": "Allemagne", "days": 2, "description": "Plus ancienne ville d'Allemagne, héritage romain (Porta Nigra), capitale du vin Riesling"},
    ...
  ]
}
''';

    developer.log('Gemini regional itinerary pour $mainDestination ($durationDays j)', name: 'ai');
    final model = _buildModel();
    final response = await model.generateContent([Content.text(prompt)]);
    final raw = response.text;
    if (raw == null || raw.isEmpty) throw Exception('Réponse vide de Gemini.');
    final cleaned = _stripCodeFences(raw).trim();
    final parsed = jsonDecode(cleaned);
    final segs = (parsed is Map) ? (parsed['segments'] as List?) ?? const [] : const [];
    final result = <({String city, String country, int days, String description})>[];
    for (final s in segs) {
      if (s is! Map<String, dynamic>) continue;
      final city = (s['city'] as String?)?.trim() ?? '';
      final country = (s['country'] as String?)?.trim() ?? '';
      // Lecture tolérante : on accepte `days` (nouveau prompt) OU `nights` (au cas
      // où Gemini retombe sur l'ancien vocabulaire malgré la consigne).
      final days = ((s['days'] as num?) ?? (s['nights'] as num?))?.toInt() ?? 0;
      final desc = (s['description'] as String?)?.trim() ?? '';
      if (city.isEmpty || days < 1) continue;
      result.add((city: city, country: country, days: days, description: desc));
    }
    if (result.isNotEmpty) {
      await _cache?.put('regional_itinerary', cacheKey, {
        'segments': result
            .map((r) => {
                  'city': r.city,
                  'country': r.country,
                  'days': r.days,
                  'description': r.description,
                })
            .toList(),
      });
    }
    return result;
  }

  Future<void> _checkRateLimit(String action) async {
    if (!_rateLimitEnabled) return;
    final cfg = _limits[action];
    if (cfg == null) return;
    try {
      await _client.rpc('check_and_log_ai_usage', params: {
        'p_action': action,
        'p_max_per_window': cfg.maxPerWindow,
        'p_window_minutes': cfg.windowMinutes,
      });
    } on PostgrestException catch (e) {
      if (e.message.contains('rate_limit_exceeded')) {
        developer.log('Rate limit dépassé pour $action', name: 'ai');
        throw AiRateLimitException(action);
      }
      // Si la fonction n'existe pas encore (PGRST202), on laisse passer silencieusement
      if (e.code == 'PGRST202') {
        developer.log('Fonction rate limit absente — skip ($action)', name: 'ai');
        return;
      }
      rethrow;
    }
  }

  GenerativeModel _buildModel({double temperature = 0.7}) {
    if (AiConstants.geminiApiKey == 'COLLE_TA_CLE_ICI' || AiConstants.geminiApiKey.isEmpty) {
      throw Exception('Clé Gemini manquante. Ajoute-la dans lib/core/constants/ai_constants.dart.');
    }
    return GenerativeModel(
      model: AiConstants.geminiModel,
      apiKey: AiConstants.geminiApiKey,
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json',
        temperature: temperature,
      ),
    );
  }

  /// Propose 5 alternatives pour REMPLACER une activité existante,
  /// en gardant le même créneau (jour + heure + catégorie proche).
  Future<List<ActivitySuggestion>> suggestAlternatives({
    required TripActivity current,
    required Trip trip,
    required String? travelerType,
    required List<String> interests,
    required List<TripActivity> allActivities,
  }) async {
    await _checkRateLimit('suggest_alternatives');
    final otherTitles = allActivities
        .where((a) => a.id != current.id)
        .map((a) => '- ${a.title}')
        .join('\n');
    final (:interestsStr, :travelerTypeDescribed) =
        _describeProfile(travelerType: travelerType, interests: interests);

    final prompt = '''
Tu es un expert en voyages. Propose 5 ALTERNATIVES pour remplacer l'activité suivante dans le planning, en gardant la même dynamique (jour, heure, type d'activité).

Activité actuelle à remplacer :
- Titre : ${current.title}
- Détail : ${current.detail ?? 'aucun'}
- Catégorie : ${current.tag}
- Date : ${current.dayDate.toIso8601String().split('T').first}
- Heure : ${current.startTime}
- Durée : ${current.durationMinutes ?? 60} minutes

Contexte voyage :
- Destination : ${trip.destination}
- Type voyageur : $travelerTypeDescribed
- Centres d'intérêt (IMPORTANT : les alternatives doivent coller à ces goûts, pas juste au tag de catégorie) :
$interestsStr

À NE PAS proposer (déjà dans le planning) :
- ${current.title}
${otherTitles.isEmpty ? '' : otherTitles}

Consignes :
- Garde la MÊME catégorie (${current.tag}) et la MÊME date/heure.
- **IMPORTANT : chaque alternative doit être OUVERTE au créneau ${current.startTime} (durée ${current.durationMinutes ?? 60} min).** Ne propose jamais un musée/monument si l'horaire tombe la nuit, ni un bar si c'est le matin, ni un resto en dehors des heures de repas. Respecte les horaires d'ouverture typiques à ${trip.destination}.
- Propose des lieux PRÉCIS et variés (noms réels de restos/musées/bars/spots), pas des généralités.
- Adapte la gamme des alternatives au type de voyageur ci-dessus (prix, niveau de service) et privilégie les lieux qui matchent un des centres d'intérêt listés.
- 5 alternatives distinctes et intéressantes.

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "activities": [
    {
      "day_date": "${current.dayDate.toIso8601String().split('T').first}",
      "start_time": "${current.startTime}",
      "title": "Nom précis de l'alternative",
      "detail": "Adresse, quartier, ou raison du match",
      "tag": "${current.tag}",
      "duration_minutes": ${current.durationMinutes ?? 60},
      "price_estimate": "~15€"
    }
  ]
}
''';

    developer.log('Gemini alternatives pour ${current.title}', name: 'ai');
    final model = _buildModel(temperature: 0.9);
    final response = await model.generateContent([Content.text(prompt)]);
    final rawText = response.text;
    if (rawText == null || rawText.isEmpty) {
      throw Exception('Réponse vide de Gemini.');
    }
    final cleaned = _stripCodeFences(rawText).trim();
    final parsed = jsonDecode(cleaned);
    List<dynamic> list;
    if (parsed is List) {
      list = parsed;
    } else if (parsed is Map) {
      list = (parsed['activities'] as List?) ?? const [];
    } else {
      list = const [];
    }
    final alternatives = <ActivitySuggestion>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      try {
        alternatives.add(ActivitySuggestion.fromJson(item));
      } catch (_) {}
    }
    return alternatives;
  }

  /// Génère des descriptions en BATCH pour N activités en UN SEUL appel Gemini.
  /// Retourne la liste dans le MÊME ordre que [items].
  /// Pour les activités dont la description ne peut pas être générée, renvoie une chaîne vide.
  ///
  /// Cache item par item (action `describe_activity`, partagée avec [describeActivity]) :
  /// les items déjà cachés sont récupérés en lookup, seuls les misses partent en
  /// batch chez Gemini, et chaque nouvelle description est upsert individuellement
  /// pour qu'un futur single-shot la retrouve directement.
  Future<List<String>> describeActivitiesBatch({
    required List<({String title, String? detail, String? tag})> items,
    required String destination,
  }) async {
    if (items.isEmpty) return [];

    // 1. Lookup cache pour chaque item, en parallèle. Même clé que describeActivity.
    final destNorm = GeminiCacheService.normKey(destination);
    String keyFor(({String title, String? detail, String? tag}) it) => GeminiCacheService.hashKey([
          (k: 'title', v: GeminiCacheService.normKey(it.title)),
          (k: 'dest', v: destNorm),
          (k: 'tag', v: GeminiCacheService.normKey(it.tag ?? '')),
        ]);
    final keys = items.map(keyFor).toList();
    final cachedByIdx = <int, String>{};
    if (_cache != null) {
      final lookups = await Future.wait(keys.map((k) => _cache.get('describe_activity', k)));
      for (var i = 0; i < lookups.length; i++) {
        final desc = lookups[i]?['description'] as String?;
        if (desc != null && desc.isNotEmpty) cachedByIdx[i] = desc;
      }
    }
    final missingIndices = <int>[
      for (var i = 0; i < items.length; i++)
        if (!cachedByIdx.containsKey(i)) i,
    ];
    if (missingIndices.isEmpty) {
      developer.log('Batch describe — ${items.length} hits cache, 0 appel Gemini', name: 'gemini_cache');
      return [for (var i = 0; i < items.length; i++) cachedByIdx[i] ?? ''];
    }

    // 2. Batch-call Gemini pour les misses uniquement.
    await _checkRateLimit('describe_activities_batch');
    final missingItems = [for (final i in missingIndices) items[i]];

    final bullets = missingItems
        .asMap()
        .entries
        .map((e) =>
            '${e.key + 1}. ${e.value.title}'
            '${e.value.detail != null && e.value.detail!.isNotEmpty ? ' — ${e.value.detail}' : ''}'
            ' (catégorie: ${e.value.tag ?? "non précisée"})')
        .join('\n');

    final prompt = '''
Tu es guide de voyage. Écris une description ENGAGEANTE de 3 à 5 phrases (en français) pour CHACUNE des activités ci-dessous.

Destination commune : $destination

Activités (garde le MÊME ordre dans la réponse) :
$bullets

Contraintes par description :
- Ton chaleureux mais factuel, sans cliché ("incontournable", "dépaysement garanti" à éviter).
- Mentionne ce qu'on y trouve/fait concrètement, l'ambiance, pourquoi c'est intéressant.
- Pas d'intro ("Voici..."). Commence direct. Max 4-5 phrases. Pas de listes à l'intérieur.
- Si tu ne connais PAS précisément un lieu, décris ce type d'endroit dans cette ville, sans inventer de faits spécifiques.

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "descriptions": [
    "Description de l'activité 1",
    "Description de l'activité 2"
  ]
}
''';

    developer.log(
      'Gemini describe BATCH — ${missingItems.length} miss / ${items.length} total',
      name: 'ai',
    );
    final model = _buildModel(temperature: 0.7);
    final response = await model.generateContent([Content.text(prompt)]);
    final rawText = response.text;
    if (rawText == null || rawText.isEmpty) {
      throw Exception('Réponse vide de Gemini.');
    }
    final cleaned = _stripCodeFences(rawText).trim();
    final parsed = jsonDecode(cleaned);
    List<dynamic> list;
    if (parsed is List) {
      list = parsed;
    } else if (parsed is Map) {
      list = (parsed['descriptions'] as List?) ?? const [];
    } else {
      list = const [];
    }

    // 3. Upsert les nouvelles descriptions, en parallèle (best-effort).
    final newDescriptionsByIdx = <int, String>{};
    for (var j = 0; j < missingIndices.length; j++) {
      final v = j < list.length ? list[j] : null;
      final desc = v is String ? v : '';
      if (desc.isEmpty) continue;
      newDescriptionsByIdx[missingIndices[j]] = desc;
    }
    if (_cache != null && newDescriptionsByIdx.isNotEmpty) {
      await Future.wait(newDescriptionsByIdx.entries.map(
        (e) => _cache.put('describe_activity', keys[e.key], {'description': e.value}),
      ));
    }

    // 4. Reconstruit la liste finale dans l'ordre original (cache + nouveau).
    return [
      for (var i = 0; i < items.length; i++)
        cachedByIdx[i] ?? newDescriptionsByIdx[i] ?? '',
    ];
  }

  /// Génère des options de trajet entre 2 activités spécifiques dans un voyage.
  /// Retourne 2 à 4 modes avec durée et prix estimé.
  Future<TransportSuggestion> generateTransportBetween({
    required TripActivity from,
    required TripActivity to,
    required String destination,
    String? travelerType,
  }) async {
    // Cache : la paire (from, to) à `destination` donne le même résultat. Le
    // `travelerType` change le default_mode → inclus dans la clé.
    final cacheKey = GeminiCacheService.hashKey([
      (k: 'from', v: GeminiCacheService.normKey(from.title)),
      (k: 'to', v: GeminiCacheService.normKey(to.title)),
      (k: 'dest', v: GeminiCacheService.normKey(destination)),
      (k: 'type', v: GeminiCacheService.normKey(travelerType ?? '')),
    ]);
    final cached = await _cache?.get('transport_pair', cacheKey);
    if (cached != null) {
      try {
        return TransportSuggestion.fromJson(cached);
      } catch (_) {}
    }

    await _checkRateLimit('suggest_alternatives');

    final fromLoc = from.detail != null && from.detail!.isNotEmpty ? from.detail : from.title;
    final toLoc = to.detail != null && to.detail!.isNotEmpty ? to.detail : to.title;

    final prompt = '''
Tu es un expert en voyages. Propose des options de trajet entre ces deux points à ${destination.isEmpty ? "la destination du voyage" : destination}.

Départ : "${from.title}"${fromLoc != from.title ? " ($fromLoc)" : ""}
Arrivée : "${to.title}"${toLoc != to.title ? " ($toLoc)" : ""}
Profil du voyageur : ${travelerType ?? "non spécifié"}

Consignes :
- Propose 2 à 4 options de déplacement réalistes pour CE trajet précis (à pied / taxi / métro / bus / vélo / voiture / train / bateau / tuk-tuk selon le pays).
- Durée réaliste en minutes selon la distance probable.
- Prix estimé par personne dans la devise locale (ou "Gratuit" pour la marche).
- "default_mode" = celui le plus cohérent avec le profil (Grand luxe → taxi, Backpack → à pied/métro, En famille → taxi ou métro).

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "from_title": "${from.title}",
  "to_title": "${to.title}",
  "default_mode": "walk|taxi|metro|bus|bike|car|train|boat|tuktuk",
  "options": [
    {"mode": "walk", "duration_minutes": 15, "price_estimate": "Gratuit", "detail": "via le quartier X"},
    {"mode": "taxi", "duration_minutes": 5, "price_estimate": "~8€"},
    {"mode": "metro", "duration_minutes": 12, "price_estimate": "~2€", "detail": "ligne 3"}
  ]
}
''';

    developer.log('Gemini transport entre ${from.title} → ${to.title}', name: 'ai');
    final model = _buildModel(temperature: 0.5);
    final response = await model.generateContent([Content.text(prompt)]);
    final rawText = response.text;
    if (rawText == null || rawText.isEmpty) {
      throw Exception('Réponse vide de Gemini.');
    }
    final cleaned = _stripCodeFences(rawText).trim();
    final parsed = jsonDecode(cleaned);
    if (parsed is! Map<String, dynamic>) {
      throw Exception('Format inattendu de Gemini.');
    }
    await _cache?.put('transport_pair', cacheKey, parsed);
    return TransportSuggestion.fromJson(parsed);
  }

  /// Génère une description courte (3-5 phrases) du lieu/activité en français.
  Future<String> describeActivity({
    required String title,
    String? detail,
    required String destination,
    String? tag,
  }) async {
    // Cache : titre + destination + tag suffisent. Le `detail` (adresse) ne change
    // pas la description du lieu de fond, on l'exclut de la clé pour maximiser les hits.
    final cacheKey = GeminiCacheService.hashKey([
      (k: 'title', v: GeminiCacheService.normKey(title)),
      (k: 'dest', v: GeminiCacheService.normKey(destination)),
      (k: 'tag', v: GeminiCacheService.normKey(tag ?? '')),
    ]);
    final cached = await _cache?.get('describe_activity', cacheKey);
    if (cached != null) {
      final desc = cached['description'] as String?;
      if (desc != null && desc.isNotEmpty) return desc;
    }

    await _checkRateLimit('describe_activity');
    final prompt = '''
Tu es guide de voyage. Écris une description ENGAGEANTE de 3 à 5 phrases (en français) pour l'activité suivante, destinée à donner envie au voyageur.

- Activité / lieu : $title
- Détail / adresse : ${detail ?? 'aucun'}
- Destination du voyage : $destination
- Catégorie : ${tag ?? 'non précisé'}

Contraintes :
- Ton chaleureux mais factuel, sans cliché touristique ("incontournable", "dépaysement garanti" à éviter).
- Mentionne ce qu'on y trouve/fait concrètement, l'ambiance, pourquoi c'est intéressant.
- Pas d'intro du genre "Voici une description...". Commence direct.
- Max 4-5 phrases. Pas de listes.
- Si tu ne connais PAS précisément le lieu, décris ce que ce type d'endroit offre dans cette ville, sans inventer de faits spécifiques.

Retourne UNIQUEMENT ce JSON (sans balises, sans texte autour) :
{"description": "La description ici."}
''';

    developer.log('Gemini describe — $title', name: 'ai');
    final model = _buildModel(temperature: 0.7);
    final response = await model.generateContent([Content.text(prompt)]);
    final rawText = response.text;
    if (rawText == null || rawText.isEmpty) {
      throw Exception('Réponse vide de Gemini.');
    }
    final cleaned = _stripCodeFences(rawText).trim();
    final parsed = jsonDecode(cleaned);
    if (parsed is! Map<String, dynamic>) {
      throw Exception('Format inattendu de Gemini.');
    }
    final desc = parsed['description'] as String?;
    if (desc == null || desc.isEmpty) {
      throw Exception('Description vide.');
    }
    await _cache?.put('describe_activity', cacheKey, {'description': desc});
    return desc;
  }

  /// Extrait les infos d'un document de voyage depuis du texte collé.
  Future<Map<String, dynamic>> extractDocumentFromText(String text, {String? hintCategory}) async {
    await _checkRateLimit('extract_document');
    final prompt = _buildExtractionPrompt(hintCategory, inputLabel: 'Texte :\n---\n$text\n---');
    return _extractDocument([Content.text(prompt)]);
  }

  /// Extrait les infos d'un document depuis une image (screenshot, photo de billet, PDF scanné...).
  Future<Map<String, dynamic>> extractDocumentFromImage(
    Uint8List imageBytes, {
    required String mimeType,
    String? hintCategory,
  }) async {
    await _checkRateLimit('extract_document');
    final prompt = _buildExtractionPrompt(hintCategory, inputLabel: 'Image fournie ci-dessous. Lis attentivement le texte visible et extrais les informations.');
    return _extractDocument([
      Content.multi([
        TextPart(prompt),
        DataPart(mimeType, imageBytes),
      ]),
    ]);
  }

  Future<Map<String, dynamic>> _extractDocument(List<Content> contents) async {
    developer.log('Extraction doc — appel Gemini', name: 'ai');
    final model = _buildModel(temperature: 0.1);
    final response = await model.generateContent(contents);
    final rawText = response.text;
    developer.log('Extraction doc — réponse: $rawText', name: 'ai');
    if (rawText == null || rawText.isEmpty) {
      throw Exception('Réponse vide de Gemini.');
    }
    final cleaned = _stripCodeFences(rawText).trim();
    final parsed = jsonDecode(cleaned);
    if (parsed is! Map<String, dynamic>) {
      throw Exception('Format inattendu de Gemini.');
    }
    final name = parsed['name'] as String?;
    if (name == null || name.isEmpty) {
      throw Exception('Impossible d\'extraire un document de la source fournie.');
    }
    return parsed;
  }

  String _buildExtractionPrompt(String? hintCategory, {required String inputLabel}) {
    final categoryHint = hintCategory == null
        ? 'Détecte d\'abord la catégorie parmi : hotel, flight, train, car_rental, ticket, other.'
        : 'Le document est de catégorie "$hintCategory".';

    return '''
Tu reçois un email, un texte ou une image (capture d'écran, photo de billet, PDF scanné) de confirmation de réservation de voyage. $categoryHint
Extrais les infos et retourne UNIQUEMENT ce JSON strict, sans balises, sans texte autour :

{
  "category": "hotel | flight | train | car_rental | ticket | other",
  "name": "Nom principal du document (nom hôtel, libellé vol, titre spectacle...)",
  "metadata": { ... }
}

Champs de "metadata" selon "category" (tous optionnels, mets les strings vides ou oublie les clés si non trouvé) :

- hotel :
  "address" (string)
  "check_in" (YYYY-MM-DD)
  "check_out" (YYYY-MM-DD)
  "reservation_number" (string)

- flight :
  "airline" (compagnie)
  "flight_number" (ex "AF1234")
  "from" (code IATA ou nom aéroport de départ)
  "to" (aéroport d'arrivée)
  "date" (YYYY-MM-DD)
  "departure_time" ("HH:MM")
  "arrival_time" ("HH:MM")
  "seat" (siège)
  "reservation_number"

- train :
  "company" (SNCF, Trenitalia, Eurostar...)
  "train_number"
  "from" (gare de départ)
  "to" (gare d'arrivée)
  "date"
  "departure_time"
  "arrival_time"
  "car" (voiture)
  "seat" (place)
  "class" (1re, 2e...)
  "reservation_number"

- car_rental :
  "company"
  "pickup_location"
  "pickup_date"
  "pickup_time"
  "return_location"
  "return_date"
  "return_time"
  "vehicle" (modèle)
  "reservation_number"

- ticket :
  "venue" (lieu)
  "address"
  "date"
  "time"
  "seat"
  "reservation_number"

- other :
  "description" (string libre)
  "date" (si pertinent)

Si "name" n'est pas trouvable clairement, retourne {"name":"","category":"other","metadata":{}}.

$inputLabel
''';
  }

  Future<SuggestionsResult> suggestActivities({
    required Trip trip,
    required String? travelerType,
    required List<String> interests,
    List<TripActivity> existingActivities = const [],
    String? hotelName,
    String? hotelAddress,
    List<HotelStay> hotels = const [],
    double? userLat,
    double? userLng,
    int? userToDestinationTravelMin,
    SuggestionCategory category = SuggestionCategory.all,
    PlanningMode mode = PlanningMode.auto,
  }) async {
    await _checkRateLimit('suggest_activities');
    final prompt = _buildPrompt(
      trip: trip,
      travelerType: travelerType,
      interests: interests,
      existingActivities: existingActivities,
      hotelName: hotelName,
      hotelAddress: hotelAddress,
      hotels: hotels,
      userLat: userLat,
      userLng: userLng,
      userToDestinationTravelMin: userToDestinationTravelMin,
      category: category,
      mode: mode,
    );
    developer.log('Gemini prompt (mode=${mode.name}):\n$prompt', name: 'ai');

    final model = _buildModel();
    final response = await model.generateContent([Content.text(prompt)]);
    final rawText = response.text;

    developer.log('Gemini raw response: $rawText', name: 'ai');

    if (rawText == null || rawText.isEmpty) {
      throw Exception('Réponse vide de Gemini.');
    }

    final cleaned = _stripCodeFences(rawText).trim();

    dynamic parsed;
    try {
      parsed = jsonDecode(cleaned);
    } catch (e) {
      throw Exception('Gemini n\'a pas retourné du JSON valide.\nRéponse : ${cleaned.substring(0, cleaned.length.clamp(0, 200))}...');
    }

    // Mode coPilot : on attend `{"groups": [...], "transports": []}` (transports
    // souvent vide car ils dépendent du choix utilisateur, on les régénère après).
    if (mode == PlanningMode.coPilot) {
      final groupsList = (parsed is Map) ? (parsed['groups'] as List?) ?? const [] : const [];
      final groups = <SuggestionGroup>[];
      for (final item in groupsList) {
        if (item is! Map<String, dynamic>) continue;
        try {
          final g = SuggestionGroup.fromJson(item);
          if (g.options.isNotEmpty) groups.add(g);
        } catch (e) {
          developer.log('Groupe ignoré (format invalide) : $item → $e', name: 'ai');
        }
      }
      final transportsList = (parsed is Map) ? (parsed['transports'] as List?) ?? const [] : const [];
      final transports = <TransportSuggestion>[];
      for (final item in transportsList) {
        if (item is! Map<String, dynamic>) continue;
        try {
          transports.add(TransportSuggestion.fromJson(item));
        } catch (_) {}
      }
      return SuggestionsResult(groups: groups, transports: transports);
    }

    // Mode auto : structure historique `{"activities": [...], "transports": [...]}`
    List<dynamic> activitiesList;
    List<dynamic> transportsList = [];
    if (parsed is List) {
      activitiesList = parsed;
    } else if (parsed is Map) {
      activitiesList = (parsed['activities'] as List?) ?? (parsed['suggestions'] as List?) ?? [];
      transportsList = (parsed['transports'] as List?) ?? const [];
    } else {
      activitiesList = [];
    }

    final suggestions = <ActivitySuggestion>[];
    for (final item in activitiesList) {
      if (item is! Map<String, dynamic>) continue;
      try {
        suggestions.add(ActivitySuggestion.fromJson(item));
      } catch (e) {
        developer.log('Activité ignorée (format invalide) : $item → $e', name: 'ai');
      }
    }

    final transports = <TransportSuggestion>[];
    for (final item in transportsList) {
      if (item is! Map<String, dynamic>) continue;
      try {
        transports.add(TransportSuggestion.fromJson(item));
      } catch (e) {
        developer.log('Trajet ignoré (format invalide) : $item → $e', name: 'ai');
      }
    }

    return SuggestionsResult(activities: suggestions, transports: transports);
  }

  String _stripCodeFences(String text) {
    var t = text.trim();
    // enlève ```json ... ``` ou ``` ... ```
    final fence = RegExp(r'^```(?:json)?\s*|\s*```$', multiLine: true);
    t = t.replaceAll(fence, '').trim();
    return t;
  }

  String _buildPrompt({
    required Trip trip,
    required String? travelerType,
    required List<String> interests,
    required List<TripActivity> existingActivities,
    String? hotelName,
    String? hotelAddress,
    List<HotelStay> hotels = const [],
    double? userLat,
    double? userLng,
    int? userToDestinationTravelMin,
    SuggestionCategory category = SuggestionCategory.all,
    PlanningMode mode = PlanningMode.auto,
  }) {
    final now = DateTime.now();
    final todayIso = DateTime(now.year, now.month, now.day).toIso8601String().split('T').first;
    // Effective start = max(aujourd'hui, trip.startDate) pour éviter les suggestions dans le passé
    final effectiveStart = trip.startDate.isBefore(DateTime(now.year, now.month, now.day))
        ? todayIso
        : trip.startDate.toIso8601String().split('T').first;
    final start = trip.startDate.toIso8601String().split('T').first;
    final end = trip.endDate.toIso8601String().split('T').first;

    // Buffer pour le délai d'arrivée sur place : temps de trajet réel (si connu) + 15 min de préparation
    // Fallback 30 min si on n'a pas la position GPS.
    final bufferMin = userToDestinationTravelMin != null ? userToDestinationTravelMin + 15 : 30;
    final earliestMinOfDay = now.hour * 60 + now.minute + bufferMin;
    final earliestTimeToday =
        '${(earliestMinOfDay ~/ 60).clamp(0, 23).toString().padLeft(2, '0')}:${(earliestMinOfDay % 60).toString().padLeft(2, '0')}';

    // Bloc position utilisateur (pour le prompt)
    final userLocationBlock = (userLat != null && userLng != null)
        ? 'Position actuelle du voyageur : lat=${userLat.toStringAsFixed(4)}, lng=${userLng.toStringAsFixed(4)}'
            '${userToDestinationTravelMin != null ? ' (environ $userToDestinationTravelMin min de trajet du centre de ${trip.destination})' : ''}.'
        : 'Position du voyageur : non renseignée (utilise la destination comme point de référence).';
    final travelers = trip.travelers.isEmpty
        ? 'solo'
        : trip.travelers.map((t) => '${t.name} (${t.age} ans)').join(', ');
    final hasKids = trip.travelers.any((t) => t.age < 13);
    final (:interestsStr, :travelerTypeDescribed) =
        _describeProfile(travelerType: travelerType, interests: interests);

    // Séparer les activités des jours précédents (déjà vécues par le voyageur) de celles
    // à venir : les premières ne doivent jamais être reproposées, même en variante ; les
    // secondes occupent un créneau à ne pas écraser.
    final today = DateTime(now.year, now.month, now.day);
    bool isPastDay(TripActivity a) {
      final dayOnly = DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day);
      return dayOnly.isBefore(today);
    }
    // Inclut l'adresse (detail) si disponible : Gemini peut raisonner par quartier
    // et regrouper ses suggestions géographiquement (éviter les aller-retours entre
    // quartiers A→B→A). Critiques en mode Restaurants pour matcher le repas à
    // l'activité précédente.
    String fmtActivity(TripActivity a) {
      final date = a.dayDate.toIso8601String().split('T').first;
      final addr = (a.detail != null && a.detail!.trim().isNotEmpty)
          ? ' [📍 ${a.detail!.trim()}]'
          : '';
      return '- $date ${a.startTime} : ${a.title}$addr';
    }

    final pastActivities = existingActivities.where(isPastDay).toList();
    final upcomingActivities = existingActivities.where((a) => !isPastDay(a)).toList();

    final pastBlock = pastActivities.isEmpty
        ? 'Aucune — le voyage commence aujourd\'hui ou rien n\'a encore été fait.'
        : pastActivities.map(fmtActivity).join('\n');
    final upcomingBlock = upcomingActivities.isEmpty
        ? 'Aucune pour l\'instant — les jours restants sont libres.'
        : upcomingActivities.map(fmtActivity).join('\n');

    // Cas 1 : plusieurs hôtels renseignés (voyage multi-villes) → bloc détaillé par période
    // Cas 2 : un seul hôtel (via hotels[0] OU hotelName legacy) → comportement historique
    // Cas 3 : rien → libellé générique
    String fmtIso(DateTime d) => d.toIso8601String().split('T').first;
    String accommodationBlock;
    if (hotels.length > 1) {
      final lines = hotels.map((h) {
        final period = (h.checkIn != null && h.checkOut != null)
            ? 'du ${fmtIso(h.checkIn!)} au ${fmtIso(h.checkOut!)}'
            : 'période non précisée';
        final addr = (h.address != null && h.address!.isNotEmpty) ? ' — ${h.address}' : '';
        return '  - "${h.name}" ($period)$addr';
      }).join('\n');
      accommodationBlock =
          'Hébergements (voyage multi-villes) :\n$lines\n'
          '→ Pour chaque jour, les activités doivent être proches de l\'hôtel couvrant ce jour '
          '(check_in ≤ jour ≤ check_out). Les retours en fin de journée doivent utiliser EXACTEMENT '
          'le libellé "Retour à [nom de l\'hôtel du jour]".';
    } else {
      final single = hotels.isNotEmpty ? hotels.first : null;
      final resolvedHotelName = single?.name ?? hotelName ?? trip.accommodation?.name;
      final resolvedHotelAddress = single?.address ?? hotelAddress ?? trip.accommodation?.address;
      accommodationBlock = (resolvedHotelName == null || resolvedHotelName.isEmpty)
          ? 'Hébergement : non renseigné → utilise le libellé générique "Retour à l\'hôtel".'
          : 'Hébergement renseigné : "$resolvedHotelName"'
            '${resolvedHotelAddress != null && resolvedHotelAddress.isNotEmpty ? ' ($resolvedHotelAddress)' : ''}'
            ' → tous les retours en fin de journée doivent utiliser EXACTEMENT le nom "Retour à $resolvedHotelName".';
    }

    // Override fort de catégorie : Gemini tend à mélanger les types d'activités s'il
    // voit des consignes contradictoires (ex: "couvre tous les intérêts" vs "que des
    // restos"). On met l'override tout en tête du prompt et on neutralise les règles
    // qui contredisent (couverture d'intérêts, variété matin/midi/soir).
    final categoryTopOverride = switch (category) {
      SuggestionCategory.all => '',
      SuggestionCategory.restaurants => '''
🔴 MISSION EXCLUSIVE — RESTAURANTS SEULEMENT 🔴
Tu dois proposer UNIQUEMENT des repas : petits-déjeuners, déjeuners, dîners, cafés, brunchs, street food, food tours, marchés gastronomiques, cours de cuisine.
TOUTE activité NON alimentaire (musée, visite, balade, parc, spa, shopping, culture, événement...) est STRICTEMENT INTERDITE dans cette requête.
Tag obligatoire : "Repas" pour petit-déj/déjeuner/dîner, "Gastronomie" pour food tours / marchés gastro / cours de cuisine.
Si tu es tenté de proposer autre chose qu'un repas, remplace-le par un restaurant à la place.

''',
      SuggestionCategory.activities => '''
🔴 MISSION EXCLUSIVE — VISITES & ACTIVITÉS SEULEMENT 🔴
Tu dois proposer UNIQUEMENT des activités NON alimentaires : visites culturelles, musées, monuments, parcs naturels, plages, spas, instituts de beauté, shopping, nightlife (bars/clubs), événements, spots populaires, sports, ateliers, balades.
TOUTE activité alimentaire (restaurant, petit-déjeuner, déjeuner, dîner, brunch, café pour manger, food tour, marché gastro) est STRICTEMENT INTERDITE dans cette requête.
Tags autorisés : "Visite", "Culture", "Nature", "Sports", "Wellness", "Esthétique", "Plage", "Bons plans", "Événements", "Nightlife", "Shopping", "Hors circuit", "Spots populaires".
Si tu es tenté de proposer un repas, remplace-le par une visite ou une activité à la place.

''',
    };

    // Construction du bloc destination : mono-ville si pas d'étapes, ou per-day breakdown
    // si l'utilisateur a structuré son voyage en étapes (ex: Nancy J1-J3, Vosges J4-J5).
    String destinationBlock;
    if (trip.itinerarySegments.isEmpty) {
      destinationBlock = '''🚫 DESTINATION STRICTE : ${trip.destination} UNIQUEMENT
- Toutes les activités doivent être PHYSIQUEMENT dans ${trip.destination} (centre-ville et proche périphérie : <15 km du centre).
- INTERDIT de proposer des activités dans des villes voisines (ex: pour Nancy, ne propose JAMAIS Metz, Épinal, Lunéville, Strasbourg ; pour Madrid, ne propose JAMAIS Tolède, Avila ; pour Bangkok, ne propose JAMAIS Ayutthaya).
- L'adresse formatée Google de chaque proposition doit obligatoirement contenir "${trip.destination}".
- Si tu hésites entre 2 lieux et qu'un est dans une autre ville → choisis celui qui est dans ${trip.destination}.''';
    } else {
      String fmt(DateTime d) => d.toIso8601String().split('T').first;
      // Calcul des dates effectives par segment selon l'ordre + cumul des jours
      final segLines = <String>[];
      for (var i = 0; i < trip.itinerarySegments.length; i++) {
        final s = trip.itinerarySegments[i];
        final from = trip.segmentStart(i);
        final to = trip.segmentEnd(i);
        segLines.add('- du ${fmt(from)} au ${fmt(to)} (${s.days} jour${s.days > 1 ? 's' : ''}) : **${s.city}**');
      }
      destinationBlock = '''🚫 VOYAGE MULTI-ÉTAPES — chaque jour a SA ville. Respecte impérativement le planning d'étapes ci-dessous :
${segLines.join('\n')}

- Pour chaque suggestion, l'adresse Google formatée doit contenir le nom de la VILLE de l'étape correspondante (ex: si J5 est en Alsace, propose des lieux dans Strasbourg/Colmar/Eguisheim, JAMAIS Nancy).
- Pour les jours qui ne sont dans aucune étape (jour de transition / arrivée / retour), utilise "${trip.destination}" comme ville par défaut.
- INTERDIT de mélanger plusieurs villes sur la même journée. Une journée = une ville. Le voyageur n'est pas téléporté entre 2 villes en cours de journée.''';
    }

    // Première bullet de la consigne — diffère selon le mode :
    // - auto : N activités/jour, toutes seront cochées par défaut côté UI
    // - coPilot : 3 OPTIONS alternatives par créneau (matin/déjeuner/après-midi/soir),
    //   l'UI affichera les options en groupes et le voyageur cochera ce qui lui plaît
    final modeIntro = mode == PlanningMode.coPilot
        ? '''- 🎯 MODE CO-PILOTE : pour chaque jour du voyage, identifie 2 à 4 créneaux libres (ex: "Matin", "Déjeuner", "Après-midi", "Soirée") et **propose EXACTEMENT 3 options alternatives par créneau** — pas 2, pas 4, exactement 3. Si tu ne trouves pas 3 lieux distincts qui valent le coup pour un créneau, n'inclus pas ce créneau du tout.
- 🚫 **TITRES INTERDITS — noms génériques** : ne propose JAMAIS un lieu sous un titre vague type "Marché couvert", "Place de marché", "Shopping de luxe", "Promenade en ville", "Balade dans le centre", "Visite du quartier", "Ruelle pittoresque". Ces titres ne correspondent à aucun lieu Google Maps précis et seront rejetés. Donne TOUJOURS un nom propre identifiable : nom officiel d'un monument ("Place Stanislas"), d'une enseigne ("Galeries Lafayette Nancy"), d'un restaurant ("Brasserie Excelsior"), d'un musée ("Musée des Beaux-Arts de Nancy"). Si tu n'es pas sûr du nom exact, utilise un repère géographique précis ET un nom propre ("Café Foy place Stanislas"), pas un terme générique seul.
- Les 3 options d'un même créneau doivent être de la MÊME intention (ex: 3 musées pour un créneau "Matin culture", 3 restos différents pour "Déjeuner") mais variées en gamme / quartier / ambiance pour offrir un vrai choix.
- Pour CHAQUE option, fournis un champ `match_reason` : 1 phrase courte qui explique POURQUOI elle matche le profil voyageur (ex: "Matche ton intérêt 'Hors circuit' + budget Backpack", "Galerie d'art réputée, calme, parfait pour début de matinée"). Aide le voyageur à choisir entre les 3.'''
        : switch (category) {
            SuggestionCategory.all => '- Propose entre 3 et 6 activités par jour **qui reflètent concrètement les centres d\'intérêt et le type de voyageur listés ci-dessus**. Règle de couverture : sur l\'ensemble du planning proposé, CHAQUE centre d\'intérêt listé doit apparaître au moins UNE fois (ex: "Esthétique" listé → au moins un institut de beauté/spa ; "Événements" listé → au moins un festival/concert/expo ou marché saisonnier en cours pendant les dates). Les prix et la gamme des lieux doivent matcher le type de voyageur (ex: "Meilleur prix" → privilégie gratuit ou <15€/personne ; "Grand luxe" → haut de gamme uniquement).',
            SuggestionCategory.restaurants => '- Propose 2 à 3 repas par jour UNIQUEMENT (petit-déjeuner + déjeuner + dîner selon ce qui manque au planning). Ne force PAS la couverture des centres d\'intérêt non-alimentaires — tu fais UNIQUEMENT des restos ici. Les prix doivent matcher le type de voyageur ("Meilleur prix" → street food / bouis-bouis ; "Grand luxe" → restaurants étoilés).',
            SuggestionCategory.activities => '- Propose 2 à 4 activités non-alimentaires par jour. Règle de couverture : chaque centre d\'intérêt NON ALIMENTAIRE listé (Culture, Wellness, Nature, etc.) doit apparaître au moins une fois dans le planning proposé. N\'ajoute AUCUN repas, même pour "combler" un créneau. Les prix et gamme doivent matcher le type de voyageur.',
          };

    // En mode coPilot, on ne demande PAS de transports (l'utilisateur n'a pas
    // encore choisi ses options, les paires sont inconnues — on les régénère
    // au save via `generateTransportBetween`). On retire aussi la consigne
    // "retour à l'hôtel" (l'app les insère automatiquement après le save).
    final transportConsigne = mode == PlanningMode.coPilot
        ? ''
        : '''
- CHAQUE jour doit se TERMINER par une activité "Retour à l'hôtel" (tag "Hébergement", duration_minutes 15, price_estimate "Gratuit"). Si un hébergement précis apparaît dans les activités existantes ou que tu en proposes un, utilise son nom exact ("Retour au Memmo Alfama" par ex.) ; sinon utilise le libellé générique "Retour à l'hôtel". Garde le MÊME nom d'hébergement pour tous les retours du voyage.
- Pour CHAQUE paire d'activités consécutives dans un même jour (y compris vers le retour à l'hôtel), génère un objet "transport" avec 2 à 4 options de déplacement (à pied / taxi / métro / bus / vélo / voiture / train / bateau / tuk-tuk selon le pays).
- **DURÉES RÉALISTES** : pour la marche, vitesse moyenne piéton = 4-5 km/h, donc 10 min = ~800 m, 30 min = ~2,5 km, 1h = ~5 km. Si tu NE CONNAIS PAS la position exacte d'une activité (ex: nom d'hébergement privé que tu ne reconnais pas), DONNE une durée pessimiste (>= 30 min à pied) plutôt qu'une estimation optimiste. **Ne propose jamais "20 min à pied" si le lieu est potentiellement à l'autre bout de la ville.** Pour les taxis/métro, compte aussi l'attente et les transferts.
- Le "default_mode" doit être cohérent avec le profil : Grand luxe → taxi, Backpack/Meilleur prix → à pied ou transports en commun, En famille → taxi ou métro selon durée.
- Les titres "from_title"/"to_title" doivent correspondre EXACTEMENT aux titres des activités.
''';

    final outputFormat = mode == PlanningMode.coPilot
        ? '''{
  "groups": [
    {
      "day_date": "YYYY-MM-DD",
      "slot_label": "Matin",
      "start_time": "10:00",
      "options": [
        {"title": "Musée X", "detail": "Adresse / quartier", "tag": "Culture", "duration_minutes": 90, "price_estimate": "~12€", "start_time": "10:00", "match_reason": "Matche ton intérêt 'Culture' + créneau matin tranquille"},
        {"title": "Galerie Y", "detail": "...", "tag": "Culture", "duration_minutes": 60, "price_estimate": "Gratuit", "start_time": "10:30", "match_reason": "Plus light, gratuit, parfait si tu veux une matinée chill"},
        {"title": "Atelier Z", "detail": "...", "tag": "Culture", "duration_minutes": 120, "price_estimate": "~25€", "start_time": "10:00", "match_reason": "Activité interactive, idéal en famille"}
      ]
    }
  ]
}'''
        : '''{
  "activities": [
    {
      "day_date": "YYYY-MM-DD",
      "start_time": "HH:MM",
      "title": "Nom précis de l'activité ou du lieu",
      "detail": "Adresse, quartier, ou raison du match",
      "tag": "Repas|Visite|Nightlife|Transport|Hébergement|Nature|Shopping|Culture|Wellness|Sport",
      "duration_minutes": 90,
      "price_estimate": "~15€"
    }
  ],
  "transports": [
    {
      "from_title": "Titre exact de l'activité de départ",
      "to_title": "Titre exact de l'activité d'arrivée",
      "default_mode": "walk|taxi|metro|bus|bike|car|train|boat|tuktuk",
      "options": [
        {"mode": "walk", "duration_minutes": 15, "price_estimate": "Gratuit", "detail": "via le quartier historique"},
        {"mode": "taxi", "duration_minutes": 5, "price_estimate": "~8€"},
        {"mode": "metro", "duration_minutes": 12, "price_estimate": "~2€", "detail": "ligne 3"}
      ]
    }
  ]
}''';

    return '''
$categoryTopOverride$destinationBlock

Tu es un expert en voyages. Propose un planning d'activités personnalisé en français pour le voyage suivant.

Voyage :
- Destination : ${trip.destination}
- Dates : du $start au $end (${trip.durationDays} jour${trip.durationDays > 1 ? 's' : ''})
- Aujourd'hui : $todayIso
- Heure actuelle : ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}
- $userLocationBlock
- Dates à proposer : UNIQUEMENT entre $effectiveStart et $end inclus (pas de date passée, pas de date postérieure à la fin du voyage)
- Pour AUJOURD'HUI ($todayIso) : la première activité ne doit PAS démarrer avant $earliestTimeToday (on tient compte du trajet réel depuis la position du voyageur + 15 min de préparation). Pour les jours suivants, pas de contrainte d'heure minimum.
- Voyageurs : $travelers${hasKids ? ' (enfants présents, activités adaptées obligatoires)' : ''}

Profil (IMPORTANT : tes propositions doivent coller à ce profil, pas juste le "prendre en compte") :
- Type de voyageur : $travelerTypeDescribed
- Centres d'intérêt — chaque item listé doit se traduire en activités concrètes dans le planning :
$interestsStr

Activités DÉJÀ VÉCUES lors des jours précédents (à NE JAMAIS reproposer, ni en doublon, ni en variante évidente — le voyageur les a déjà faites) :
$pastBlock

Activités déjà planifiées pour aujourd'hui ou les jours suivants (créneaux à ne pas écraser, et à ne pas dupliquer) :
$upcomingBlock

$accommodationBlock

Consigne :
$modeIntro
- **PRIORITÉ AUX CRÉNEAUX LIBRES** : si un jour a déjà plusieurs activités planifiées mais qu'il reste des trous (soir libre après la dernière activité, gap de plus de 2 heures en milieu de journée, matinée vide), **comble ces trous en priorité** avec de nouvelles activités, même si le jour approche déjà 5-6 activités. L'objectif n'est pas de respecter un quota, c'est de remplir utilement le temps disponible. Exemples : dernière activité finit à 18h ET aucune activité ensuite → propose un dîner / un bar / une sortie nocturne en fonction des intérêts. Trou entre 10h et 14h → propose une activité qui tient dans ce créneau.
- Ne propose AUCUNE activité listée dans les blocs ci-dessus (ni celles des jours précédents déjà vécues, ni celles déjà planifiées). Pour les activités des jours précédents, évite aussi les variantes évidentes (ex: si le voyageur a déjà visité un grand musée historique, ne propose pas un autre grand musée historique similaire).
- Varie matin / midi / après-midi / soir.
- **CONTINUITÉ GÉOGRAPHIQUE (priorité absolue)** : quand tu proposes une nouvelle activité pour un créneau, elle doit être le plus proche possible de l'activité qui la précède IMMÉDIATEMENT sur la même journée. Les adresses des activités existantes sont listées entre [📍 ...] dans les blocs ci-dessus — utilise-les pour raisonner par quartier / arrondissement / distance. Exemples : si l'activité de 10h est dans le 7e arrondissement, le déjeuner à 12h30 doit être dans le 7e, éventuellement 6e ou 8e. JAMAIS à l'autre bout de la ville. Pour les voyages multi-quartiers, groupe tes suggestions par "journée dans un même secteur" pour éviter les aller-retours inutiles A→B→A→B. Pour les journées sans activité existante, regroupe tes propositions dans 1-2 quartiers max.
- **PÉRIMÈTRE GÉOGRAPHIQUE (contrainte large)** : chaque activité doit aussi être atteignable en **~45 min max de trajet** depuis ${hotels.length > 1 ? "l'hôtel couvrant le jour de l'activité (voir liste ci-dessus)" : hotels.isNotEmpty ? "l'hôtel \"${hotels.first.name}\"" : hotelName != null ? "l'hôtel \"$hotelName\"" : "le centre de ${trip.destination}"}. Pas de day-trips à 2h de route (hors voyage longue durée). Pour AUJOURD'HUI spécifiquement, privilégie des lieux proches de la position actuelle du voyageur si elle est fournie.
- Nomme des lieux précis (restos, quartiers, musées, spots), pas des généralités.
- Les dates doivent être comprises entre $effectiveStart et $end inclus. NE PROPOSE JAMAIS d'activité à une date déjà passée (< $todayIso).
- **IMPORTANT : respecte les horaires d'ouverture RÉELS du type de lieu dans cette destination.** Exemples repères (à adapter aux coutumes locales) :
  - Musées / monuments culturels : généralement 9h-17h, souvent fermés le lundi ou mardi
  - Temples (Asie du sud-est) : 6h-18h
  - Restaurants : déjeuner 12h-14h, dîner 19h-22h (plus tôt en Espagne/Italie, plus tard en Asie)
  - Bars / clubs / nightlife : à partir de 21h, rarement avant 19h
  - Marchés diurnes : 7h-14h
  - Marchés nocturnes : 18h-minuit
  - Shopping / centres commerciaux : 10h-20h
  - Activités nature (rando, parcs) : 8h-17h
  - Plage : 9h-18h
  Ne propose JAMAIS une visite de musée à 22h, un restaurant à 7h, ou un bar à 10h. Adapte à la destination (Thaïlande, Japon, Espagne, etc. ont des rythmes différents).
- Donne une durée estimée (en minutes) et un prix estimé par personne dans la devise locale (ou "Gratuit" si accès libre).$transportConsigne

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
$outputFormat
''';
  }
}
