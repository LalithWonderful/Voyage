import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/planning/services/place_components.dart';

class PlacePhoto {
  final String url;
  final String attribution;
  const PlacePhoto({required this.url, this.attribution = ''});
}

class OpeningPeriod {
  final int openDay;    // 0 = dimanche, 1 = lundi, ... 6 = samedi (convention Google)
  final String openTime; // "0830"
  final int? closeDay;
  final String? closeTime;

  const OpeningPeriod({required this.openDay, required this.openTime, this.closeDay, this.closeTime});

  factory OpeningPeriod.fromJson(Map<String, dynamic> json) {
    final open = json['open'] as Map<String, dynamic>?;
    final close = json['close'] as Map<String, dynamic>?;
    return OpeningPeriod(
      openDay: (open?['day'] as num?)?.toInt() ?? 0,
      openTime: open?['time'] as String? ?? '0000',
      closeDay: (close?['day'] as num?)?.toInt(),
      closeTime: close?['time'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'open': {'day': openDay, 'time': openTime},
    if (closeDay != null && closeTime != null) 'close': {'day': closeDay, 'time': closeTime},
  };
}

class OpeningHours {
  final List<String> weekdayText; // "lundi: 08:30 – 18:30", etc.
  final List<OpeningPeriod> periods;

  const OpeningHours({this.weekdayText = const [], this.periods = const []});

  factory OpeningHours.fromJson(Map<String, dynamic> json) => OpeningHours(
    weekdayText: (json['weekday_text'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    periods: (json['periods'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((p) => OpeningPeriod.fromJson(p))
            .toList() ??
        const [],
  );

  Map<String, dynamic> toJson() => {
    'weekday_text': weekdayText,
    'periods': periods.map((p) => p.toJson()).toList(),
  };

  /// Retourne true si le lieu est ouvert à l'instant [when]. Calcul local, pas de cache
  /// du statut (volontaire : toujours à jour).
  bool isOpenAt(DateTime when) {
    if (periods.isEmpty) return false;
    // Cas 24/7 : Google renvoie un unique period avec open.day=0, time=0000 et pas de close
    if (periods.length == 1 && periods.first.closeDay == null) return true;

    // Convertit DateTime.weekday (1=lundi..7=dimanche) → convention Google (0=dimanche..6=samedi)
    final googleDay = when.weekday == 7 ? 0 : when.weekday;
    final minutes = when.hour * 60 + when.minute;

    for (final p in periods) {
      final openMin = _hhmmToMin(p.openTime);
      final closeMin = p.closeTime != null ? _hhmmToMin(p.closeTime!) : null;
      if (p.closeDay == null || closeMin == null) continue;

      if (p.openDay == p.closeDay) {
        // Même jour
        if (p.openDay == googleDay && minutes >= openMin && minutes < closeMin) return true;
      } else {
        // Traverse minuit
        if (p.openDay == googleDay && minutes >= openMin) return true;
        if (p.closeDay == googleDay && minutes < closeMin) return true;
      }
    }
    return false;
  }

  /// Retourne l'horaire du jour courant (lundi, mardi...) sous forme lisible, ou null si
  /// fermé ce jour-là.
  String? todayText(DateTime when) {
    if (weekdayText.isEmpty) return null;
    // weekdayText est ordonné lundi..dimanche (Google avec language=fr)
    final idx = (when.weekday - 1).clamp(0, weekdayText.length - 1);
    return weekdayText[idx];
  }

  static int _hhmmToMin(String hhmm) {
    final h = int.tryParse(hhmm.substring(0, 2)) ?? 0;
    final m = int.tryParse(hhmm.substring(2, 4)) ?? 0;
    return h * 60 + m;
  }
}

class PlaceReview {
  final String authorName;
  final double rating;
  final String text;
  final String relativeTime;
  final String? profilePhotoUrl;

  const PlaceReview({
    required this.authorName,
    required this.rating,
    required this.text,
    required this.relativeTime,
    this.profilePhotoUrl,
  });

  factory PlaceReview.fromJson(Map<String, dynamic> json) => PlaceReview(
    authorName: json['author_name'] as String? ?? 'Anonyme',
    rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
    text: json['text'] as String? ?? '',
    relativeTime: json['relative_time_description'] as String? ?? '',
    profilePhotoUrl: json['profile_photo_url'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'author_name': authorName,
    'rating': rating,
    'text': text,
    'relative_time_description': relativeTime,
    if (profilePhotoUrl != null) 'profile_photo_url': profilePhotoUrl,
  };
}

class PlaceInfo {
  final List<PlacePhoto> photos;
  final double? rating;
  final int? ratingsCount;
  final int? priceLevel;
  final String? placeId;
  final String? address;
  /// Nom canonique du lieu retourné par Google Places (ex: "Place Stanislas",
  /// "Brasserie Excelsior"). Sert au filtre anti-hallucination : on rejette
  /// une suggestion Gemini si aucun token significatif de son titre ne matche
  /// ce name. Null si Places n'a pas trouvé le lieu ou cache pré-migration.
  final String? name;
  final List<PlaceReview>? reviews;
  final OpeningHours? openingHours;

  const PlaceInfo({
    this.photos = const [],
    this.rating,
    this.ratingsCount,
    this.priceLevel,
    this.placeId,
    this.address,
    this.name,
    this.reviews,
    this.openingHours,
  });

  static const empty = PlaceInfo();

  String? get priceLevelLabel {
    if (priceLevel == null || priceLevel! < 1) return null;
    return '€' * priceLevel!.clamp(1, 4);
  }
}

class PlacesService {
  static const _maxPhotos = 3;
  static const _photoMaxWidth = 800;

  /// Recherche les infos d'un lieu : photos, rating, nombre d'avis.
  Future<PlaceInfo> findInfo({
    required String query,
    double? latitude,
    double? longitude,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    if (key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return PlaceInfo.empty;
    final trimmed = query.trim();
    if (trimmed.isEmpty) return PlaceInfo.empty;

    try {
      final params = {
        'input': trimmed,
        'inputtype': 'textquery',
        'fields': 'photos,place_id,name,rating,user_ratings_total,price_level,formatted_address',
        'key': key,
      };
      if (latitude != null && longitude != null) {
        params['locationbias'] = 'circle:5000@$latitude,$longitude';
      }

      final findUri = Uri.https('maps.googleapis.com', '/maps/api/place/findplacefromtext/json', params);
      final findResp = await http.get(findUri);
      if (findResp.statusCode != 200) {
        developer.log('Places HTTP ${findResp.statusCode}', name: 'places');
        return PlaceInfo.empty;
      }
      final findData = jsonDecode(findResp.body) as Map<String, dynamic>;
      final status = findData['status'] as String?;
      if (status != 'OK') {
        developer.log('Places status=$status pour "$trimmed"', name: 'places');
        return PlaceInfo.empty;
      }
      final candidates = findData['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return PlaceInfo.empty;
      final first = candidates.first as Map<String, dynamic>;

      final photos = <PlacePhoto>[];
      final photosData = first['photos'] as List?;
      if (photosData != null) {
        for (final p in photosData.take(_maxPhotos)) {
          final ref = (p as Map<String, dynamic>)['photo_reference'] as String?;
          if (ref == null) continue;
          final url = Uri.https('maps.googleapis.com', '/maps/api/place/photo', {
            'maxwidth': '$_photoMaxWidth',
            'photo_reference': ref,
            'key': key,
          }).toString();
          final attr = (p['html_attributions'] as List?)?.join(' · ') ?? '';
          photos.add(PlacePhoto(url: url, attribution: attr));
        }
      }

      return PlaceInfo(
        photos: photos,
        rating: (first['rating'] as num?)?.toDouble(),
        ratingsCount: (first['user_ratings_total'] as num?)?.toInt(),
        priceLevel: (first['price_level'] as num?)?.toInt(),
        placeId: first['place_id'] as String?,
        address: first['formatted_address'] as String?,
        name: (first['name'] as String?)?.trim(),
      );
    } catch (e) {
      developer.log('Erreur Places : $e', name: 'places');
      return PlaceInfo.empty;
    }
  }

  /// Compat : retourne juste les photos (ancienne signature utilisée par les suggestions).
  Future<List<PlacePhoto>> findPhotos({
    required String query,
    double? latitude,
    double? longitude,
  }) async {
    final info = await findInfo(query: query, latitude: latitude, longitude: longitude);
    return info.photos;
  }

  /// Autocomplete de noms d'étapes touristiques (villes ET îles, archipels,
  /// presqu'îles, sites touristiques majeurs) pour un widget de saisie.
  /// `language=fr` pour des noms en français quand dispo.
  ///
  /// **3 calls** `(cities)` + `geocode` + `establishment`, fusion par
  /// `placeId`. Justification :
  /// - `(cities)` : villes classiques (locality / admin_3) — priorisées par
  ///   Google, rangées en 1er.
  /// - `geocode` : autres geocoded results (admin_2, sublocality, certains
  ///   natural_feature).
  /// - `establishment` : tourist_attraction et natural_feature classées
  ///   "business result" par Google. Cas Lalith 2026-05-02 : Ko Samet (île
  ///   thaï touristique) ne remontait pas car classée `establishment` →
  ///   exclue de `(cities)` ET `geocode`. Idem Mont Saint-Michel, certains
  ///   archipels, parcs nationaux, etc.
  ///
  /// Le filtre côté client `_allowedEtapeTypes` (whitelist) garantit qu'on
  /// ne ramène que ce qui est sémantiquement une étape de voyage : villes,
  /// quartiers connus, îles, archipels, attractions majeures. Pas de restos,
  /// hôtels, écoles, etc. (qui sont aussi des `establishment` mais pas
  /// `tourist_attraction`).
  ///
  /// Coût : 3 appels Autocomplete (~$8.49/1000 saisies au lieu de $2.83).
  /// À cacher en backlog `places_autocomplete_cache` pour rendre
  /// asymptotiquement gratuit (cf. `project_open_improvements.md`).
  ///
  /// `countryCode` (ISO 2 lowercase, ex: 'th') restreint aux résultats du
  /// pays — sécurise les étapes sur les voyages "Pays".
  Future<List<({String description, String mainText, String placeId})>> autocompleteCities(String query, {String? countryCode}) async {
    final key = AiConstants.googleMapsApiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return const [];
    // 3 appels en parallèle pour latence constante (3 round-trips simultanés).
    final results = await Future.wait([
      _autocompleteEtape(trimmed, '(cities)', countryCode, key),
      _autocompleteEtape(trimmed, 'geocode', countryCode, key),
      _autocompleteEtape(trimmed, 'establishment', countryCode, key),
    ]);
    // Dédup par placeId. Ordre : (cities) en premier (priorité villes),
    // puis geocode, puis establishment (tourist_attraction / natural_feature
    // après les vraies villes pour ne pas saturer le top de la liste).
    final seen = <String>{};
    final merged = <({String description, String mainText, String placeId})>[];
    for (final list in results) {
      for (final item in list) {
        if (item.placeId.isEmpty) continue;
        if (seen.add(item.placeId)) merged.add(item);
      }
    }
    return merged;
  }

  Future<List<({String description, String mainText, String placeId})>> _autocompleteEtape(
    String trimmed,
    String typesParam,
    String? countryCode,
    String key,
  ) async {
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', {
        'input': trimmed,
        'types': typesParam,
        'language': 'fr',
        if (countryCode != null && countryCode.isNotEmpty) 'components': 'country:$countryCode',
        'key': key,
      });
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log('Autocomplete[$typesParam] status=${data['status']}', name: 'places');
        return const [];
      }
      final preds = (data['predictions'] as List?) ?? const [];
      // Whitelist côté client : on garde uniquement les types pertinents pour
      // une étape de voyage. Filtre les commerces individuels (restos,
      // hôtels) qui remonteraient via `establishment`.
      return preds.whereType<Map<String, dynamic>>().where((p) {
        final types = ((p['types'] as List?) ?? const []).whereType<String>().toSet();
        return types.any(_allowedEtapeTypes.contains);
      }).map((p) {
        final desc = (p['description'] as String?) ?? '';
        final structured = p['structured_formatting'] as Map<String, dynamic>?;
        final main = (structured?['main_text'] as String?) ?? desc.split(',').first.trim();
        return (
          description: desc,
          mainText: main,
          placeId: (p['place_id'] as String?) ?? '',
        );
      }).where((r) => r.description.isNotEmpty).toList();
    } catch (e) {
      developer.log('Erreur Autocomplete[$typesParam] : $e', name: 'places');
      return const [];
    }
  }

  /// Types Google considérés comme **valides** pour une étape de voyage.
  /// Whitelist plutôt que blacklist : on garantit que rien d'inattendu ne
  /// passe (genre un resto individuel ou un quartier ultra-précis), et on
  /// enrichit la liste explicitement quand on découvre un cas légitime
  /// manquant. Couvre villes, sous-divisions touristiques connues, îles,
  /// archipels, et attractions majeures (Ko Samet, Mont Saint-Michel,
  /// parcs nationaux).
  static const _allowedEtapeTypes = <String>{
    'locality',
    'postal_town',
    'sublocality',
    'sublocality_level_1',
    'neighborhood',
    'administrative_area_level_2',
    'administrative_area_level_3',
    'colloquial_area',
    'natural_feature',
    'archipelago',
    'tourist_attraction',
  };

  /// Variante d'`autocompleteCities` qui n'applique PAS le filtre `(cities)` :
  /// renvoie aussi les pays et régions (administrative_area_level_*). Utilisé
  /// pour la destination principale du voyage où l'utilisateur peut taper
  /// "Maroc" ou "Bali" → on récupère le `kind` (`city`/`country`/`region`)
  /// pour ensuite imposer le découpage en étapes si la destination n'est pas
  /// une ville. Cf. project_next_priority Niveau 2.
  Future<List<({String description, String mainText, String placeId, String kind})>> autocompleteDestinations(String query) async {
    final key = AiConstants.googleMapsApiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return const [];
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', {
        'input': trimmed,
        // `types=geocode` exclut les établissements (hôpitaux, restos, hôtels...)
        // tout en laissant passer pays/régions/villes/adresses précises. Sans
        // ce filtre, taper "Chine" remontait "Chinese General Hospital and
        // Medical Center" en 1ère suggestion (bug observé Lalith 28/04).
        'types': 'geocode',
        'language': 'fr',
        'key': key,
      });
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log('Autocomplete dest status=${data['status']}', name: 'places');
        return const [];
      }
      final preds = (data['predictions'] as List?) ?? const [];
      return preds.whereType<Map<String, dynamic>>().map((p) {
        final desc = (p['description'] as String?) ?? '';
        final structured = p['structured_formatting'] as Map<String, dynamic>?;
        final main = (structured?['main_text'] as String?) ?? desc.split(',').first.trim();
        final types = ((p['types'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false);
        // Mapping types Google → kind métier :
        // - 'country' → country
        // - 'administrative_area_level_1/2' (région/État/département) → region
        // - 'natural_feature' (île, archipel, parc, montagne) → region (Bali,
        //   Sicile, etc. peuvent revenir avec ce type SANS administrative_area)
        // - 'locality' / 'sublocality' / 'postal_town' → city
        // - sinon → 'place' (POI, adresse précise). Côté UI on bloque save sur
        //   country/region uniquement, pas sur 'place' (laisse passer même
        //   si l'utilisateur tape une adresse précise).
        final String kind;
        if (types.contains('country')) {
          kind = 'country';
        } else if (types.contains('locality') ||
            types.contains('postal_town') ||
            types.contains('sublocality')) {
          kind = 'city';
        } else if (types.contains('administrative_area_level_1') ||
            types.contains('administrative_area_level_2') ||
            types.contains('natural_feature') ||
            types.contains('archipelago')) {
          kind = 'region';
        } else {
          kind = 'place';
        }
        return (
          description: desc,
          mainText: main,
          placeId: (p['place_id'] as String?) ?? '',
          kind: kind,
        );
      }).where((r) => r.description.isNotEmpty).toList();
    } catch (e) {
      developer.log('Erreur Autocomplete dest : $e', name: 'places');
      return const [];
    }
  }

  /// Autocomplete d'aéroports OU de gares pour les docs de transport.
  ///
  /// `type` doit être `'airport'` ou `'train_station'` (types Google Places
  /// supportés). Filtre les suggestions aux hubs de transport correspondants
  /// — l'user voit uniquement des aéroports/gares valides et choisit dans la
  /// liste, plus de saisie libre type "bkkooo".
  ///
  /// `sessionToken` doit être un UUID stable durant le burst de saisie (du
  /// premier keystroke jusqu'au pick d'une suggestion). Permet à Google de
  /// facturer 1 session = N keystrokes + 1 Place Details, au lieu de billing
  /// par requête. À régénérer après chaque pick (voir
  /// `TransportAutocompleteField`).
  ///
  /// `language=fr` retourne des noms en français quand dispo (ex: "Aéroport
  /// Charles-de-Gaulle" plutôt que "Charles de Gaulle Airport").
  Future<List<({String description, String mainText, String placeId})>>
      autocompleteTransport(
    String query, {
    required String type,
    String? sessionToken,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return const [];
    if (type != 'airport' && type != 'train_station') return const [];
    try {
      final params = <String, String>{
        'input': trimmed,
        'types': type,
        'language': 'fr',
        'key': key,
      };
      if (sessionToken != null && sessionToken.isNotEmpty) {
        params['sessiontoken'] = sessionToken;
      }
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', params);
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log('Autocomplete transport status=${data['status']}', name: 'places');
        return const [];
      }
      final preds = (data['predictions'] as List?) ?? const [];
      return preds.whereType<Map<String, dynamic>>().map((p) {
        final desc = (p['description'] as String?) ?? '';
        final structured = p['structured_formatting'] as Map<String, dynamic>?;
        final main = (structured?['main_text'] as String?) ?? desc.split(',').first.trim();
        return (
          description: desc,
          mainText: main,
          placeId: (p['place_id'] as String?) ?? '',
        );
      }).where((r) => r.description.isNotEmpty).toList();
    } catch (e) {
      developer.log('Erreur Autocomplete transport : $e', name: 'places');
      return const [];
    }
  }

  /// Résout un placeId Google → coords (lat/lng) + nom officiel + code pays
  /// ISO 2 + ville (locality) via Place Details. À utiliser après un pick
  /// d'autocomplete ; passe le même `sessionToken` que l'autocomplete pour
  /// rester en tarif "session".
  ///
  /// Coût : 1 appel Place Details (~$0.005 avec champs Basic uniquement —
  /// `geometry/location,name,address_components`). Le `country_code` permet
  /// de signaler les vols/trains incohérents avec la destination du voyage
  /// (ex: BKK→CNX = TH dans un voyage Chine). Le `city` permet de déduire
  /// l'étape voyage depuis un aéroport (CNX → "Chiang Mai"). À combiner avec
  /// `place_lookup_cache` côté Supabase pour rendre asymptotiquement gratuit.
  Future<({double lat, double lng, String name, String? countryCode, String? city})?> resolvePlaceCoords(
    String placeId, {
    String? sessionToken,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    if (placeId.isEmpty || key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return null;
    try {
      final params = <String, String>{
        'place_id': placeId,
        'fields': 'geometry/location,name,address_components',
        'language': 'fr',
        'key': key,
      };
      if (sessionToken != null && sessionToken.isNotEmpty) {
        params['sessiontoken'] = sessionToken;
      }
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', params);
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;
      final result = data['result'] as Map<String, dynamic>?;
      final geometry = result?['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;
      final lat = (location?['lat'] as num?)?.toDouble();
      final lng = (location?['lng'] as num?)?.toDouble();
      final name = (result?['name'] as String?)?.trim() ?? '';
      if (lat == null || lng == null || name.isEmpty) return null;
      // Extraction du code pays ISO 2 + ville depuis address_components.
      // Cascade gérée par pickCityFromComponents : préfère admin_level_1
      // (province) si locality est une subdivision trop fine (Tambon en
      // Thaïlande). Cf. place_components.dart.
      String? countryCode;
      final components = (result?['address_components'] as List?) ?? const [];
      String? locality;
      String? postalTown;
      String? adminLevel1;
      String? sublocalityLevel1;
      String? adminLevel2;
      for (final comp in components.whereType<Map<String, dynamic>>()) {
        final types = ((comp['types'] as List?) ?? const []).whereType<String>().toSet();
        if (types.contains('country')) {
          final shortName = comp['short_name'] as String?;
          if (shortName != null && shortName.isNotEmpty) {
            countryCode = shortName.toLowerCase();
          }
        }
        final long = comp['long_name'] as String?;
        if (long == null || long.isEmpty) continue;
        if (types.contains('locality')) locality = long;
        if (types.contains('postal_town')) postalTown = long;
        if (types.contains('administrative_area_level_1')) adminLevel1 = long;
        if (types.contains('sublocality_level_1') || types.contains('sublocality')) {
          sublocalityLevel1 = long;
        }
        if (types.contains('administrative_area_level_2')) adminLevel2 = long;
      }
      // Override pour les aéroports majeurs : si les coords matchent un aéroport
      // connu (haversine < 5 km), on prend la ville touristique attendue par le
      // voyageur (BKK→Bangkok, CDG→Paris, NRT→Tokyo) au lieu de la subdivision
      // administrative locale (Samut Prakan, Roissy-en-France, Chiba). Si pas
      // d'override, fallback sur la cascade address_components standard.
      final city = overrideCityForAirportLatLng(lat, lng) ??
          pickCityFromComponents(
            locality: locality,
            postalTown: postalTown,
            adminLevel1: adminLevel1,
            sublocalityLevel1: sublocalityLevel1,
            adminLevel2: adminLevel2,
          );
      return (lat: lat, lng: lng, name: name, countryCode: countryCode, city: city);
    } catch (e) {
      developer.log('Erreur resolvePlaceCoords : $e', name: 'places');
      return null;
    }
  }

  /// Récupère le code ISO 2 lettres du pays correspondant à un placeId Google.
  /// Utilisé pour restreindre l'autocomplete des étapes au pays choisi en
  /// destination (Thaïlande → 'th', les étapes proposées seront thaï
  /// uniquement). Marche aussi pour les régions (administrative_area_level_*) :
  /// remonte au pays parent.
  ///
  /// Coût : 1 appel Place Details (~$0.017). Stocker le résultat côté caller
  /// pour ne pas re-payer à chaque ouverture du dialog d'étape.
  Future<String?> getCountryCodeFromPlaceId(String placeId) async {
    final key = AiConstants.googleMapsApiKey;
    if (placeId.isEmpty || key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return null;
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
        'place_id': placeId,
        'fields': 'address_component',
        'language': 'fr',
        'key': key,
      });
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;
      final components = ((data['result'] as Map<String, dynamic>?)?['address_components'] as List?) ?? const [];
      for (final comp in components.whereType<Map<String, dynamic>>()) {
        final types = ((comp['types'] as List?) ?? const []).whereType<String>();
        if (types.contains('country')) {
          final shortName = comp['short_name'] as String?;
          if (shortName != null && shortName.isNotEmpty) {
            return shortName.toLowerCase();
          }
        }
      }
      return null;
    } catch (e) {
      developer.log('Erreur getCountryCode : $e', name: 'places');
      return null;
    }
  }

  /// Résout une ville en coordonnées (lat/lng du centre) + adresse formatée pour
  /// vérification manuelle. Utilise Places "Find Place from Text" plutôt que la
  /// Geocoding API : meilleur sur les requêtes "Ville, Pays" libres (notamment
  /// pour des villes ambiguës comme "Bouillon" qui peut matcher un POI vs la
  /// vraie ville en Belgique).
  /// Coût : ~$0.017/req. Retourne null si l'API échoue ou si la clé est absente.
  Future<({double lat, double lng, String formattedAddress})?> findCityCoords(
    String city, {
    String? country,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    if (key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return null;
    final query = country != null && country.isNotEmpty ? '$city, $country' : city;
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/findplacefromtext/json', {
        'input': query,
        'inputtype': 'textquery',
        'fields': 'geometry,formatted_address',
        'language': 'fr',
        'key': key,
      });
      final resp = await http.get(uri);
      if (resp.statusCode != 200) {
        developer.log('FindPlace city HTTP ${resp.statusCode} pour "$query"', name: 'places');
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      if (status != 'OK') {
        developer.log('FindPlace city status=$status pour "$query"', name: 'places');
        return null;
      }
      final candidates = (data['candidates'] as List?) ?? const [];
      if (candidates.isEmpty) return null;
      final first = candidates.first as Map<String, dynamic>;
      final loc = (first['geometry'] as Map<String, dynamic>?)?['location'] as Map<String, dynamic>?;
      final lat = (loc?['lat'] as num?)?.toDouble();
      final lng = (loc?['lng'] as num?)?.toDouble();
      final addr = (first['formatted_address'] as String?) ?? '';
      if (lat == null || lng == null) return null;
      developer.log('FindPlace "$query" → $lat,$lng ($addr)', name: 'places');
      return (lat: lat, lng: lng, formattedAddress: addr);
    } catch (e) {
      developer.log('Erreur FindPlace city : $e', name: 'places');
      return null;
    }
  }

  /// Récupère reviews + horaires d'ouverture en un seul appel Places Details.
  Future<({List<PlaceReview> reviews, OpeningHours? openingHours})> getDetails(String placeId) async {
    final key = AiConstants.googleMapsApiKey;
    if (key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return (reviews: const <PlaceReview>[], openingHours: null);
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
        'place_id': placeId,
        'fields': 'reviews,opening_hours',
        'language': 'fr',
        'reviews_sort': 'newest',
        'key': key,
      });
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return (reviews: const <PlaceReview>[], openingHours: null);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return (reviews: const <PlaceReview>[], openingHours: null);
      final result = data['result'] as Map<String, dynamic>?;
      final reviewsData = result?['reviews'] as List?;
      final hoursData = result?['opening_hours'] as Map<String, dynamic>?;
      final reviews = reviewsData
              ?.whereType<Map<String, dynamic>>()
              .map((r) => PlaceReview.fromJson(r))
              .toList() ??
          const <PlaceReview>[];
      final openingHours = hoursData != null ? OpeningHours.fromJson(hoursData) : null;
      return (reviews: reviews, openingHours: openingHours);
    } catch (e) {
      developer.log('Erreur Places details : $e', name: 'places');
      return (reviews: const <PlaceReview>[], openingHours: null);
    }
  }
}
