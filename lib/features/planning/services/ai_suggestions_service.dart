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
  'En famille': 'kid-friendly, parcs d\'attractions, zoos, aquariums, musées interactifs pour enfants, activités éducatives et ludiques, trajets courts, menus enfants. Pas d\'activités nightlife/clubs/bars (incompatibles avec enfants)',
  'Voyage pro': 'restaurants business, lieux courts à visiter entre deux réunions, bars d\'hôtels, cafés coworking, options sans bagage, efficacité, ambiance calme',
  'Couple': 'restaurants romantiques avec ambiance, bars à cocktails et rooftops, spas pour couple, points de vue / coucher de soleil, hébergements de charme, balades à 2 dans des quartiers pittoresques, expériences intimes',
  'Chill': 'rythme lent (1-2 activités max par jour), beaucoup de temps libre, spas, parcs et jardins botaniques, cafés tranquilles, plages, lieux apaisants, peu de transport, pas d\'agenda chargé',
  'Fun': 'lieux animés et photogéniques, bars/clubs, fin de journée et soirée, food halls, marchés nocturnes, parcs d\'attractions, plages festives, expériences fun en groupe, lieux Instagrammables',
  'Senior': 'rythme tranquille, peu de marche entre activités (≤300m idéal), pauses fréquentes, musées avec sièges, restaurants confortables (pas trop bruyants), parcs accessibles, monuments historiques, éviter activités physiques intenses et fortes chaleurs',
};

/// Formate les préférences voyageur (type + intérêts) avec leurs descriptions
/// concrètes pour Gemini. Utilisé par `suggestAlternatives` (alternatives pour
/// remplacer une activité).
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
  /// [destinationKind] : `city` / `country` / `region` / `place` / `unknown`.
  /// Quand la destination est un pays ou une région, on bascule sur un prompt
  /// adapté : Gemini propose des villes DANS la destination (au lieu de
  /// l'inclure elle-même comme étape, ce qui produit "États-Unis 3 jours" en
  /// première card — non-sens UX). On filtre aussi côté code pour les rares cas
  /// où Gemini retombe sur le nom du pays.
  ///
  /// [selectedRegion] : si fourni (cas pays large/travel_region où l'utilisateur
  /// a choisi une région via [CountryRegionsSheet]), Gemini reçoit un cadre plus
  /// strict : "circuit dans la région X (villes principales : Y, Z)" au lieu de
  /// "boucle autour du pays Y". Le radius vient de la région et `sameCountryOnly`
  /// est forcé à true (une région = un seul pays). Tags fournis comme contexte
  /// pour aider Gemini à orienter ses propositions.
  Future<List<({String city, String country, int days, String description})>> suggestRegionalItinerary({
    required String mainDestination,
    required int durationDays,
    String? travelerType,
    List<String> interests = const [],
    int radiusKm = 150,
    bool sameCountryOnly = false,
    List<String> excludeCities = const [],
    int daysAlreadyPlaced = 0,
    String? destinationKind,
    ({String regionName, String label, List<String> tags})? selectedRegion,
  }) async {
    // Si une région est choisie, on force le contexte : radius depuis la région,
    // sameCountryOnly forcé à true (une région = un seul pays).
    if (selectedRegion != null) {
      sameCountryOnly = true;
    }
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
      (k: 'kind', v: GeminiCacheService.normKey(destinationKind ?? '')),
      (k: 'region', v: GeminiCacheService.normKey(selectedRegion?.regionName ?? '')),
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
    // Si la destination est un pays/région, on NE l'inclut PAS comme étape
    // (sinon Gemini propose "États-Unis 3 jours" comme première card → non-sens).
    // Sinon (city/place/unknown) on garde la consigne d'inclusion historique,
    // sauf si l'utilisateur l'a déjà ajoutée manuellement comme étape.
    final isLargeDestination =
        destinationKind == 'country' || destinationKind == 'region';
    final mustIncludeMain = selectedRegion != null
        ? '- ⚠️ Cible UNIQUEMENT la région **${selectedRegion.regionName}** dans $mainDestination. Villes principales de cette région : ${selectedRegion.label}. Tu peux inclure des villes voisines proches (dans le rayon de $radiusKm km) si elles enrichissent le circuit, mais reste DANS cette région — ne propose pas de villes d\'autres régions du pays.'
        : (isLargeDestination
            ? '- ⚠️ $mainDestination est un ${destinationKind == 'country' ? 'pays' : 'une région'} — ne le propose JAMAIS comme étape. Propose UNIQUEMENT des villes précises situées DANS $mainDestination (et villes frontalières si transfrontalier autorisé).'
            : (excludeCities
                    .map((c) => c.trim().toLowerCase())
                    .contains(mainDestination.trim().toLowerCase())
                ? '- ⚠️ $mainDestination est déjà dans les étapes du voyageur — NE LA REPROPOSE PAS, propose UNIQUEMENT des villes voisines.'
                : '- Inclus OBLIGATOIREMENT $mainDestination dans la boucle (avec assez de jours pour la visiter, 2-3 jours typiquement).'));
    // Si une région ciblée, on enrichit le contexte avec ses tags pour orienter
    // les choix Gemini (mais sans imposer — Gemini reste libre du choix de villes
    // précises, on cadre juste le périmètre).
    final regionTagsBlock = selectedRegion != null && selectedRegion.tags.isNotEmpty
        ? '\n- Mots-clés thématiques de cette région : ${selectedRegion.tags.join(", ")}. Privilégie des villes qui collent à cette ambiance.'
        : '';
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
$mustIncludeMain$regionTagsBlock
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
    // Gemini peut ajouter un préambule type "Voici votre itinéraire :\n```json\n{...}```"
    // → après _stripCodeFences il reste "Voici votre itinéraire :\n{...}". On extrait
    // le 1er bloc {...} ou [...] valide pour ne pas exploser sur un FormatException.
    final jsonStr = _extractJsonBlock(cleaned);
    dynamic parsed;
    try {
      parsed = jsonDecode(jsonStr);
    } catch (e) {
      developer.log('Gemini regional itinerary parse error: $e\nReponse brute (200 premiers car.): ${raw.substring(0, raw.length.clamp(0, 200))}', name: 'ai');
      throw Exception('Réponse Gemini invalide. Réessaie ou simplifie la destination.');
    }
    final segs = (parsed is Map) ? (parsed['segments'] as List?) ?? const [] : const [];
    final result = <({String city, String country, int days, String description})>[];
    final mainDestNorm = mainDestination.trim().toLowerCase();
    for (final s in segs) {
      if (s is! Map<String, dynamic>) continue;
      final city = (s['city'] as String?)?.trim() ?? '';
      final country = (s['country'] as String?)?.trim() ?? '';
      // Lecture tolérante : on accepte `days` (nouveau prompt) OU `nights` (au cas
      // où Gemini retombe sur l'ancien vocabulaire malgré la consigne).
      final days = ((s['days'] as num?) ?? (s['nights'] as num?))?.toInt() ?? 0;
      final desc = (s['description'] as String?)?.trim() ?? '';
      if (city.isEmpty || days < 1) continue;
      // Garde-fou : pour les destinations pays/région, Gemini retombe parfois
      // sur le nom de la destination malgré la consigne. On filtre.
      if (isLargeDestination && city.trim().toLowerCase() == mainDestNorm) {
        developer.log('Gemini regional itinerary: skipping suggestion "$city" matching $destinationKind destination "$mainDestination"', name: 'ai');
        continue;
      }
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

  /// Appel Gemini brut pour les prompts custom (typiquement les prompts
  /// Places-first construits dans `places_first_pipeline.dart`). Retourne
  /// le texte JSON brut. Le caller est responsable du parsing et de la
  /// validation. Cache via `gemini_cache` (action paramétrable) si dispo.
  ///
  /// Le `cacheKey` doit être déterministe pour le même prompt (typiquement
  /// hash du prompt complet). Si null, pas de cache pour cet appel.
  Future<String> generateRaw({
    required String prompt,
    String cacheAction = 'raw',
    String? cacheKey,
    double temperature = 0.7,
  }) async {
    if (cacheKey != null) {
      final cached = await _cache?.get(cacheAction, cacheKey);
      final raw = cached?['raw'] as String?;
      if (raw != null && raw.isNotEmpty) return raw;
    }
    final model = _buildModel(temperature: temperature);
    final response = await model.generateContent([Content.text(prompt)]);
    final raw = response.text;
    if (raw == null || raw.isEmpty) {
      throw Exception('Réponse Gemini vide.');
    }
    if (cacheKey != null) {
      await _cache?.put(cacheAction, cacheKey, {'raw': raw});
    }
    return raw;
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

  String _stripCodeFences(String text) {
    var t = text.trim();
    // enlève ```json ... ``` ou ``` ... ```
    final fence = RegExp(r'^```(?:json)?\s*|\s*```$', multiLine: true);
    t = t.replaceAll(fence, '').trim();
    return t;
  }

  /// Extrait le 1er bloc JSON valide ({...} ou [...]) d'une string. Robustifie
  /// le parsing quand Gemini ajoute un préambule explicatif avant le JSON
  /// (ex: "Voici votre itinéraire :\n{...}"). Si aucun bloc clair n'est
  /// détecté, retourne la string telle quelle (jsonDecode plantera, le caller
  /// gère).
  String _extractJsonBlock(String text) {
    final firstObj = text.indexOf('{');
    final firstArr = text.indexOf('[');
    final start = (firstObj == -1)
        ? firstArr
        : (firstArr == -1 ? firstObj : (firstObj < firstArr ? firstObj : firstArr));
    if (start < 0) return text;
    final lastObj = text.lastIndexOf('}');
    final lastArr = text.lastIndexOf(']');
    final end = lastObj > lastArr ? lastObj : lastArr;
    if (end <= start) return text;
    return text.substring(start, end + 1);
  }
}
