import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';

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

  /// Autocomplete de noms de villes pour un widget de saisie.
  /// Filtre les résultats sur le type "(cities)" → exclut régions/pays/POI.
  /// Le `description` retourné est ce qu'on affiche dans le dropdown ("Gérardmer, France").
  /// Utilise `language=fr` pour des noms en français quand disponible.
  /// Retourne une liste vide en cas d'erreur (silencieux, pas d'exception).
  /// Autocomplete villes avec restriction optionnelle à un pays. `countryCode`
  /// est le code ISO 2 lettres en minuscules (ex: 'th' pour Thaïlande, 'ma'
  /// pour Maroc). Quand fourni, Google ne renvoie QUE les villes du pays — ce
  /// qui sécurise la saisie d'étapes sur les voyages "Pays" (ex: voyage
  /// Thaïlande → étapes proposées : Bangkok, Chiang Mai, Phuket, pas Paris).
  Future<List<({String description, String mainText, String placeId})>> autocompleteCities(String query, {String? countryCode}) async {
    final key = AiConstants.googleMapsApiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return const [];
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', {
        'input': trimmed,
        'types': '(cities)',
        'language': 'fr',
        if (countryCode != null && countryCode.isNotEmpty) 'components': 'country:$countryCode',
        'key': key,
      });
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log('Autocomplete status=${data['status']}', name: 'places');
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
      developer.log('Erreur Autocomplete : $e', name: 'places');
      return const [];
    }
  }

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
