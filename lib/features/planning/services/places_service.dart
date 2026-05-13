import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/planning/services/autocomplete_guard.dart';
import 'package:voyage/features/planning/services/place_components.dart';

class PlacePhoto {
  final String url;
  final String attribution;
  const PlacePhoto({required this.url, this.attribution = ''});
}

class OpeningPeriod {
  final int
  openDay; // 0 = dimanche, 1 = lundi, ... 6 = samedi (convention Google)
  final String openTime; // "0830"
  final int? closeDay;
  final String? closeTime;

  const OpeningPeriod({
    required this.openDay,
    required this.openTime,
    this.closeDay,
    this.closeTime,
  });

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
    if (closeDay != null && closeTime != null)
      'close': {'day': closeDay, 'time': closeTime},
  };
}

class OpeningHours {
  final List<String> weekdayText; // "lundi: 08:30 – 18:30", etc.
  final List<OpeningPeriod> periods;

  const OpeningHours({this.weekdayText = const [], this.periods = const []});

  factory OpeningHours.fromJson(Map<String, dynamic> json) => OpeningHours(
    weekdayText:
        (json['weekday_text'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    periods:
        (json['periods'] as List?)
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
        if (p.openDay == googleDay &&
            minutes >= openMin &&
            minutes < closeMin) {
          return true;
        }
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
  final LiveApiGuards _guards;
  final http.Client? _httpClient;
  final String _apiKey;
  final AutocompleteGuard _autocompleteGuard;

  PlacesService({
    LiveApiGuards? guards,
    http.Client? httpClient,
    String? apiKey,
    AutocompleteGuard? autocompleteGuard,
  }) : _guards = guards ?? LiveApiGuards.fromEnvironment(),
       _httpClient = httpClient,
       _apiKey = apiKey ?? AiConstants.googleMapsApiKey,
       _autocompleteGuard = autocompleteGuard ?? AutocompleteGuard();

  bool get _hasApiKey =>
      _apiKey.isNotEmpty && _apiKey != 'COLLE_TA_CLE_MAPS_ICI';

  // ─── API-0.6a — Lunao-first destination source ───
  static const _lunaoDestinations = <String, ({
    String description,
    String mainText,
    String placeId,
    String kind,
  })>{
    'lisbon': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon', kind: 'city'),
    'lisbonne': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon', kind: 'city'),
    'lisboa': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon', kind: 'city'),
    'lisbon portugal': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon', kind: 'city'),
    'lisbonne portugal': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon', kind: 'city'),
    'lisboa portugal': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon', kind: 'city'),
  };

  static const _lunaoCities = <String, ({
    String description,
    String mainText,
    String placeId,
  })>{
    'lisbon': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon'),
    'lisbonne': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon'),
    'lisboa': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon'),
    'lisbon portugal': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon'),
    'lisbonne portugal': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon'),
    'lisboa portugal': (description: 'Lisbonne, Portugal', mainText: 'Lisbonne', placeId: 'lunao:lisbon'),
  };

  static ({String description, String mainText, String placeId, String kind})?
  _matchLunaoDestination(String normalized) {
    final exact = _lunaoDestinations[normalized];
    if (exact != null) return exact;
    if (normalized.length < 4) return null;
    for (final entry in _lunaoDestinations.entries) {
      if (entry.key.startsWith(normalized)) return entry.value;
    }
    return null;
  }

  static ({String description, String mainText, String placeId})?
  _matchLunaoCity(String normalized) {
    final exact = _lunaoCities[normalized];
    if (exact != null) return exact;
    if (normalized.length < 4) return null;
    for (final entry in _lunaoCities.entries) {
      if (entry.key.startsWith(normalized)) return entry.value;
    }
    return null;
  }

  // API-0.6b — Local country list prevents Google fallback for country searches.
  static const _lunaoCountries = <String, ({
    String description,
    String mainText,
    String placeId,
    String kind,
  })>{
    // Europe
    'france': (description: 'France', mainText: 'France', placeId: 'lunao:country:fr', kind: 'country'),
    'espagne': (description: 'Espagne', mainText: 'Espagne', placeId: 'lunao:country:es', kind: 'country'),
    'italie': (description: 'Italie', mainText: 'Italie', placeId: 'lunao:country:it', kind: 'country'),
    'portugal': (description: 'Portugal', mainText: 'Portugal', placeId: 'lunao:country:pt', kind: 'country'),
    'grèce': (description: 'Grèce', mainText: 'Grèce', placeId: 'lunao:country:gr', kind: 'country'),
    'grece': (description: 'Grèce', mainText: 'Grèce', placeId: 'lunao:country:gr', kind: 'country'),
    'croatie': (description: 'Croatie', mainText: 'Croatie', placeId: 'lunao:country:hr', kind: 'country'),
    'royaume-uni': (description: 'Royaume-Uni', mainText: 'Royaume-Uni', placeId: 'lunao:country:gb', kind: 'country'),
    'angleterre': (description: 'Angleterre', mainText: 'Angleterre', placeId: 'lunao:country:gb', kind: 'country'),
    'irlande': (description: 'Irlande', mainText: 'Irlande', placeId: 'lunao:country:ie', kind: 'country'),
    'islande': (description: 'Islande', mainText: 'Islande', placeId: 'lunao:country:is', kind: 'country'),
    'norvège': (description: 'Norvège', mainText: 'Norvège', placeId: 'lunao:country:no', kind: 'country'),
    'norvege': (description: 'Norvège', mainText: 'Norvège', placeId: 'lunao:country:no', kind: 'country'),
    'suède': (description: 'Suède', mainText: 'Suède', placeId: 'lunao:country:se', kind: 'country'),
    'suede': (description: 'Suède', mainText: 'Suède', placeId: 'lunao:country:se', kind: 'country'),
    'finlande': (description: 'Finlande', mainText: 'Finlande', placeId: 'lunao:country:fi', kind: 'country'),
    'danemark': (description: 'Danemark', mainText: 'Danemark', placeId: 'lunao:country:dk', kind: 'country'),
    'allemagne': (description: 'Allemagne', mainText: 'Allemagne', placeId: 'lunao:country:de', kind: 'country'),
    'suisse': (description: 'Suisse', mainText: 'Suisse', placeId: 'lunao:country:ch', kind: 'country'),
    'autriche': (description: 'Autriche', mainText: 'Autriche', placeId: 'lunao:country:at', kind: 'country'),
    'belgique': (description: 'Belgique', mainText: 'Belgique', placeId: 'lunao:country:be', kind: 'country'),
    'pays-bas': (description: 'Pays-Bas', mainText: 'Pays-Bas', placeId: 'lunao:country:nl', kind: 'country'),
    'hollande': (description: 'Pays-Bas', mainText: 'Pays-Bas', placeId: 'lunao:country:nl', kind: 'country'),
    'tchéquie': (description: 'Tchéquie', mainText: 'Tchéquie', placeId: 'lunao:country:cz', kind: 'country'),
    'tchequie': (description: 'Tchéquie', mainText: 'Tchéquie', placeId: 'lunao:country:cz', kind: 'country'),
    'hongrie': (description: 'Hongrie', mainText: 'Hongrie', placeId: 'lunao:country:hu', kind: 'country'),
    'pologne': (description: 'Pologne', mainText: 'Pologne', placeId: 'lunao:country:pl', kind: 'country'),
    // Afrique & Moyen-Orient
    'maroc': (description: 'Maroc', mainText: 'Maroc', placeId: 'lunao:country:ma', kind: 'country'),
    'tunisie': (description: 'Tunisie', mainText: 'Tunisie', placeId: 'lunao:country:tn', kind: 'country'),
    'égypte': (description: 'Égypte', mainText: 'Égypte', placeId: 'lunao:country:eg', kind: 'country'),
    'egypte': (description: 'Égypte', mainText: 'Égypte', placeId: 'lunao:country:eg', kind: 'country'),
    'turquie': (description: 'Turquie', mainText: 'Turquie', placeId: 'lunao:country:tr', kind: 'country'),
    'afrique du sud': (description: 'Afrique du Sud', mainText: 'Afrique du Sud', placeId: 'lunao:country:za', kind: 'country'),
    'kenya': (description: 'Kenya', mainText: 'Kenya', placeId: 'lunao:country:ke', kind: 'country'),
    'tanzanie': (description: 'Tanzanie', mainText: 'Tanzanie', placeId: 'lunao:country:tz', kind: 'country'),
    'jordanie': (description: 'Jordanie', mainText: 'Jordanie', placeId: 'lunao:country:jo', kind: 'country'),
    'israël': (description: 'Israël', mainText: 'Israël', placeId: 'lunao:country:il', kind: 'country'),
    'israel': (description: 'Israël', mainText: 'Israël', placeId: 'lunao:country:il', kind: 'country'),
    'émirats arabes unis': (description: 'Émirats arabes unis', mainText: 'Émirats arabes unis', placeId: 'lunao:country:ae', kind: 'country'),
    'emirats arabes unis': (description: 'Émirats arabes unis', mainText: 'Émirats arabes unis', placeId: 'lunao:country:ae', kind: 'country'),
    'dubai': (description: 'Dubaï, Émirats arabes unis', mainText: 'Dubaï', placeId: 'lunao:country:ae', kind: 'country'),
    'dubaï': (description: 'Dubaï, Émirats arabes unis', mainText: 'Dubaï', placeId: 'lunao:country:ae', kind: 'country'),
    'oman': (description: 'Oman', mainText: 'Oman', placeId: 'lunao:country:om', kind: 'country'),
    'qatar': (description: 'Qatar', mainText: 'Qatar', placeId: 'lunao:country:qa', kind: 'country'),
    // Asie
    'thaïlande': (description: 'Thaïlande', mainText: 'Thaïlande', placeId: 'lunao:country:th', kind: 'country'),
    'thailande': (description: 'Thaïlande', mainText: 'Thaïlande', placeId: 'lunao:country:th', kind: 'country'),
    'japon': (description: 'Japon', mainText: 'Japon', placeId: 'lunao:country:jp', kind: 'country'),
    'vietnam': (description: 'Vietnam', mainText: 'Vietnam', placeId: 'lunao:country:vn', kind: 'country'),
    'indonésie': (description: 'Indonésie', mainText: 'Indonésie', placeId: 'lunao:country:id', kind: 'country'),
    'indonesie': (description: 'Indonésie', mainText: 'Indonésie', placeId: 'lunao:country:id', kind: 'country'),
    'malaisie': (description: 'Malaisie', mainText: 'Malaisie', placeId: 'lunao:country:my', kind: 'country'),
    'singapour': (description: 'Singapour', mainText: 'Singapour', placeId: 'lunao:country:sg', kind: 'country'),
    'philippines': (description: 'Philippines', mainText: 'Philippines', placeId: 'lunao:country:ph', kind: 'country'),
    'cambodge': (description: 'Cambodge', mainText: 'Cambodge', placeId: 'lunao:country:kh', kind: 'country'),
    'laos': (description: 'Laos', mainText: 'Laos', placeId: 'lunao:country:la', kind: 'country'),
    'chine': (description: 'Chine', mainText: 'Chine', placeId: 'lunao:country:cn', kind: 'country'),
    'inde': (description: 'Inde', mainText: 'Inde', placeId: 'lunao:country:in', kind: 'country'),
    'sri lanka': (description: 'Sri Lanka', mainText: 'Sri Lanka', placeId: 'lunao:country:lk', kind: 'country'),
    'maldives': (description: 'Maldives', mainText: 'Maldives', placeId: 'lunao:country:mv', kind: 'country'),
    'népal': (description: 'Népal', mainText: 'Népal', placeId: 'lunao:country:np', kind: 'country'),
    'nepal': (description: 'Népal', mainText: 'Népal', placeId: 'lunao:country:np', kind: 'country'),
    // Océanie & Amériques
    'australie': (description: 'Australie', mainText: 'Australie', placeId: 'lunao:country:au', kind: 'country'),
    'nouvelle-zélande': (description: 'Nouvelle-Zélande', mainText: 'Nouvelle-Zélande', placeId: 'lunao:country:nz', kind: 'country'),
    'nouvelle-zelande': (description: 'Nouvelle-Zélande', mainText: 'Nouvelle-Zélande', placeId: 'lunao:country:nz', kind: 'country'),
    'états-unis': (description: 'États-Unis', mainText: 'États-Unis', placeId: 'lunao:country:us', kind: 'country'),
    'etats-unis': (description: 'États-Unis', mainText: 'États-Unis', placeId: 'lunao:country:us', kind: 'country'),
    'etats unis': (description: 'États-Unis', mainText: 'États-Unis', placeId: 'lunao:country:us', kind: 'country'),
    'usa': (description: 'États-Unis', mainText: 'États-Unis', placeId: 'lunao:country:us', kind: 'country'),
    'canada': (description: 'Canada', mainText: 'Canada', placeId: 'lunao:country:ca', kind: 'country'),
    'mexique': (description: 'Mexique', mainText: 'Mexique', placeId: 'lunao:country:mx', kind: 'country'),
    'brésil': (description: 'Brésil', mainText: 'Brésil', placeId: 'lunao:country:br', kind: 'country'),
    'bresil': (description: 'Brésil', mainText: 'Brésil', placeId: 'lunao:country:br', kind: 'country'),
    'argentine': (description: 'Argentine', mainText: 'Argentine', placeId: 'lunao:country:ar', kind: 'country'),
    'pérou': (description: 'Pérou', mainText: 'Pérou', placeId: 'lunao:country:pe', kind: 'country'),
    'perou': (description: 'Pérou', mainText: 'Pérou', placeId: 'lunao:country:pe', kind: 'country'),
    'chili': (description: 'Chili', mainText: 'Chili', placeId: 'lunao:country:cl', kind: 'country'),
    'colombie': (description: 'Colombie', mainText: 'Colombie', placeId: 'lunao:country:co', kind: 'country'),
    'costa rica': (description: 'Costa Rica', mainText: 'Costa Rica', placeId: 'lunao:country:cr', kind: 'country'),
    'cuba': (description: 'Cuba', mainText: 'Cuba', placeId: 'lunao:country:cu', kind: 'country'),
    // DOM-TOM
    'réunion': (description: 'La Réunion', mainText: 'La Réunion', placeId: 'lunao:country:re', kind: 'country'),
    'reunion': (description: 'La Réunion', mainText: 'La Réunion', placeId: 'lunao:country:re', kind: 'country'),
    'guadeloupe': (description: 'Guadeloupe', mainText: 'Guadeloupe', placeId: 'lunao:country:gp', kind: 'country'),
    'martinique': (description: 'Martinique', mainText: 'Martinique', placeId: 'lunao:country:mq', kind: 'country'),
  };

  static ({String description, String mainText, String placeId, String kind})?
  _matchLunaoCountry(String normalized) {
    final exact = _lunaoCountries[normalized];
    if (exact != null) return exact;
    if (normalized.length < 4) return null;
    for (final entry in _lunaoCountries.entries) {
      if (entry.key.startsWith(normalized)) return entry.value;
    }
    return null;
  }

  // API-0.6c — Local region list prevents Google fallback for popular regions.
  static const _lunaoRegions = <String, ({
    String description,
    String mainText,
    String placeId,
    String kind,
  })>{
    'bali': (description: 'Bali, Indonésie', mainText: 'Bali', placeId: 'lunao:region:id:bali', kind: 'region'),
    'bali indonesie': (description: 'Bali, Indonésie', mainText: 'Bali', placeId: 'lunao:region:id:bali', kind: 'region'),
    'bali indonésie': (description: 'Bali, Indonésie', mainText: 'Bali', placeId: 'lunao:region:id:bali', kind: 'region'),
    'toscane': (description: 'Toscane, Italie', mainText: 'Toscane', placeId: 'lunao:region:it:toscane', kind: 'region'),
    'tuscany': (description: 'Toscane, Italie', mainText: 'Toscane', placeId: 'lunao:region:it:toscane', kind: 'region'),
    'andalousie': (description: 'Andalousie, Espagne', mainText: 'Andalousie', placeId: 'lunao:region:es:andalousie', kind: 'region'),
    'andalusia': (description: 'Andalousie, Espagne', mainText: 'Andalousie', placeId: 'lunao:region:es:andalousie', kind: 'region'),
    'île-de-france': (description: 'Île-de-France, France', mainText: 'Île-de-France', placeId: 'lunao:region:fr:idf', kind: 'region'),
    'ile-de-france': (description: 'Île-de-France, France', mainText: 'Île-de-France', placeId: 'lunao:region:fr:idf', kind: 'region'),
    'ile de france': (description: 'Île-de-France, France', mainText: 'Île-de-France', placeId: 'lunao:region:fr:idf', kind: 'region'),
    'provence': (description: 'Provence, France', mainText: 'Provence', placeId: 'lunao:region:fr:provence', kind: 'region'),
    'provence alpes cote d azur': (description: 'Provence, France', mainText: 'Provence', placeId: 'lunao:region:fr:provence', kind: 'region'),
    'sicile': (description: 'Sicile, Italie', mainText: 'Sicile', placeId: 'lunao:region:it:sicile', kind: 'region'),
    'sicily': (description: 'Sicile, Italie', mainText: 'Sicile', placeId: 'lunao:region:it:sicile', kind: 'region'),
  };

  static ({String description, String mainText, String placeId, String kind})?
  _matchLunaoRegion(String normalized) {
    final exact = _lunaoRegions[normalized];
    if (exact != null) return exact;
    if (normalized.length < 4) return null;
    for (final entry in _lunaoRegions.entries) {
      if (entry.key.startsWith(normalized)) return entry.value;
    }
    return null;
  }

  void _assertGooglePlacesAllowed(String operation) {
    _guards.assertAllowed(LiveApiFamily.googlePlaces, operation: operation);
  }

  Future<http.Response> _get(Uri uri) {
    final client = _httpClient;
    if (client != null) {
      return client.get(uri);
    }
    return http.get(uri);
  }

  /// Recherche les infos d'un lieu : photos, rating, nombre d'avis.
  Future<PlaceInfo> findInfo({
    required String query,
    double? latitude,
    double? longitude,
  }) async {
    final key = _apiKey;
    if (!_hasApiKey) return PlaceInfo.empty;
    final trimmed = query.trim();
    if (trimmed.isEmpty) return PlaceInfo.empty;

    _assertGooglePlacesAllowed('PlacesService.findInfo');
    try {
      final params = {
        'input': trimmed,
        'inputtype': 'textquery',
        'fields':
            'photos,place_id,name,rating,user_ratings_total,price_level,formatted_address',
        'key': key,
      };
      if (latitude != null && longitude != null) {
        params['locationbias'] = 'circle:5000@$latitude,$longitude';
      }

      final findUri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/findplacefromtext/json',
        params,
      );
      final findResp = await _get(findUri);
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
          final url = Uri.https(
            'maps.googleapis.com',
            '/maps/api/place/photo',
            {'maxwidth': '$_photoMaxWidth', 'photo_reference': ref, 'key': key},
          ).toString();
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
    final info = await findInfo(
      query: query,
      latitude: latitude,
      longitude: longitude,
    );
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
  Future<List<({String description, String mainText, String placeId})>>
  autocompleteCities(String query, {String? countryCode}) async {
    final normalized = query.trim().toLowerCase();

    // API-0.6a — Lunao-first for covered destinations
    final lunao = _matchLunaoCity(normalized);
    if (lunao != null) {
      // ignore: avoid_print
      print(
        '[autocomplete] source=lunao '
        'query="$normalized" '
        'context=city '
        'results=1',
      );
      return [lunao];
    }

    // API-0.6a — guard: min-length, cache, timeout, error safety
    return _autocompleteGuard.execute(
      query: query,
      context: 'city',
      fallback: () => _autocompleteCitiesImpl(query, countryCode: countryCode),
    );
  }

  Future<List<({String description, String mainText, String placeId})>>
  _autocompleteCitiesImpl(String query, {String? countryCode}) async {
    final key = _apiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || !_hasApiKey) return const [];
    _assertGooglePlacesAllowed('PlacesService.autocompleteCities');
    // Phase 1 : (cities) + geocode couvrent la grande majorité des destinations.
    // Phase 2 (conditionnelle) : establishment uniquement si peu de résultats.
    // Certaines îles touristiques et natural_feature (Ko Samet, Mont Saint-
    // Michel) sont classées establishment par Google et absentes des 2 premiers.
    final phase1 = await Future.wait([
      _autocompleteEtape(trimmed, '(cities)', countryCode, key),
      _autocompleteEtape(trimmed, 'geocode', countryCode, key),
    ]);
    final seen = <String>{};
    final merged = <({String description, String mainText, String placeId})>[];
    for (final list in phase1) {
      for (final item in list) {
        if (item.placeId.isEmpty) continue;
        if (seen.add(item.placeId)) merged.add(item);
      }
    }
    if (merged.length < 3) {
      final establishments =
          await _autocompleteEtape(trimmed, 'establishment', countryCode, key);
      for (final item in establishments) {
        if (item.placeId.isEmpty) continue;
        if (seen.add(item.placeId)) merged.add(item);
      }
    }
    return merged;
  }

  Future<List<({String description, String mainText, String placeId})>>
  _autocompleteEtape(
    String trimmed,
    String typesParam,
    String? countryCode,
    String key,
  ) async {
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        {
          'input': trimmed,
          'types': typesParam,
          'language': 'fr',
          if (countryCode != null && countryCode.isNotEmpty)
            'components': 'country:$countryCode',
          'key': key,
        },
      );
      final resp = await _get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log(
          'Autocomplete[$typesParam] status=${data['status']}',
          name: 'places',
        );
        return const [];
      }
      final preds = (data['predictions'] as List?) ?? const [];
      // Whitelist côté client : on garde uniquement les types pertinents pour
      // une étape de voyage. Filtre les commerces individuels (restos,
      // hôtels) qui remonteraient via `establishment`.
      // Debug : log brut de chaque prédiction (description + types) pour
      // diagnostiquer les cas "X ne remonte pas dans l'autocomplete" (cas
      // Ko Samet 2026-05-03). À garder tant que ces cas surgissent.
      debugPrint(
        '[places] autocomplete[$typesParam] "$trimmed" → ${preds.length} preds',
      );
      for (final p in preds.whereType<Map<String, dynamic>>()) {
        final desc = (p['description'] as String?) ?? '';
        final types = ((p['types'] as List?) ?? const [])
            .whereType<String>()
            .toList();
        debugPrint('[places]   • $desc — types=$types');
      }
      return preds
          .whereType<Map<String, dynamic>>()
          .where((p) {
            final types = ((p['types'] as List?) ?? const [])
                .whereType<String>()
                .toSet();
            // Doit avoir au moins un type "destination valide".
            if (!types.any(_allowedEtapeTypes.contains)) return false;
            // Filtre additionnel : un `point_of_interest` SEUL (sans aucun
            // type qui en fait une vraie destination touristique) est rejeté.
            // Cas Ko Samet 2026-05-03 : Google retourne 3 lieux individuels
            // dans l'île (pier, sentier, autre pier) qui ne sont pas des
            // "étapes" — juste des POIs internes. Seul le parc national qui
            // a aussi `park` + `tourist_attraction` passe.
            if (types.contains('point_of_interest') &&
                !types.any(_destinationGradeTypes.contains)) {
              return false;
            }
            return true;
          })
          .map((p) {
            final desc = (p['description'] as String?) ?? '';
            final structured =
                p['structured_formatting'] as Map<String, dynamic>?;
            final main =
                (structured?['main_text'] as String?) ??
                desc.split(',').first.trim();
            return (
              description: desc,
              mainText: main,
              placeId: (p['place_id'] as String?) ?? '',
            );
          })
          .where((r) => r.description.isNotEmpty)
          .toList();
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
  /// archipels, parcs nationaux, et attractions majeures (Ko Samet via
  /// son parc englobant, Mont Saint-Michel, etc.).
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
    'park',
  };

  /// Sous-ensemble de `_allowedEtapeTypes` qui qualifie un résultat comme
  /// "vraie destination" (vs un POI interne à une destination existante).
  /// Utilisé pour filtrer les `point_of_interest` Google qui seraient
  /// accompagnés UNIQUEMENT d'`establishment` — typiquement les piers,
  /// sentiers, plages individuelles à l'intérieur d'une île. Si le résultat
  /// porte aussi un de ces types, c'est une destination grade-A et on garde.
  static const _destinationGradeTypes = <String>{
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
    'park',
  };

  /// Variante d'`autocompleteCities` qui n'applique PAS le filtre `(cities)` :
  /// renvoie aussi les pays et régions (administrative_area_level_*). Utilisé
  /// pour la destination principale du voyage où l'utilisateur peut taper
  /// "Maroc" ou "Bali" → on récupère le `kind` (`city`/`country`/`region`)
  /// pour ensuite imposer le découpage en étapes si la destination n'est pas
  /// une ville. Cf. project_next_priority Niveau 2.
  Future<
    List<({String description, String mainText, String placeId, String kind})>
  >
  autocompleteDestinations(String query) async {
    final normalized = query.trim().toLowerCase();

    // API-0.6a — Lunao-first for covered destinations
    final lunao = _matchLunaoDestination(normalized);
    if (lunao != null) {
      // ignore: avoid_print
      print(
        '[autocomplete] source=lunao '
        'query="$normalized" '
        'context=destination '
        'results=1',
      );
      return [lunao];
    }

    // API-0.6b — Country-first: local list prevents Google fallback
    final country = _matchLunaoCountry(normalized);
    if (country != null) {
      // ignore: avoid_print
      print(
        '[autocomplete] source=lunao '
        'query="$normalized" '
        'context=destination '
        'results=1',
      );
      return [country];
    }

    // API-0.6c — Region-first: local list prevents Google fallback
    final region = _matchLunaoRegion(normalized);
    if (region != null) {
      // ignore: avoid_print
      print(
        '[autocomplete] source=lunao '
        'query="$normalized" '
        'context=destination '
        'results=1',
      );
      return [region];
    }

    // API-0.6a — guard: min-length, cache, timeout, error safety
    return _autocompleteGuard.execute(
      query: query,
      context: 'destination',
      fallback: () => _autocompleteDestinationsImpl(query),
    );
  }

  Future<
    List<({String description, String mainText, String placeId, String kind})>
  >
  _autocompleteDestinationsImpl(String query) async {
    final key = _apiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || !_hasApiKey) return const [];
    _assertGooglePlacesAllowed('PlacesService.autocompleteDestinations');
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        {
          'input': trimmed,
          // `types=geocode` exclut les établissements (hôpitaux, restos, hôtels...)
          // tout en laissant passer pays/régions/villes/adresses précises. Sans
          // ce filtre, taper "Chine" remontait "Chinese General Hospital and
          // Medical Center" en 1ère suggestion (bug observé Lalith 28/04).
          'types': 'geocode',
          'language': 'fr',
          'key': key,
        },
      );
      final resp = await _get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log(
          'Autocomplete dest status=${data['status']}',
          name: 'places',
        );
        return const [];
      }
      final preds = (data['predictions'] as List?) ?? const [];
      return preds
          .whereType<Map<String, dynamic>>()
          .map((p) {
            final desc = (p['description'] as String?) ?? '';
            final structured =
                p['structured_formatting'] as Map<String, dynamic>?;
            final main =
                (structured?['main_text'] as String?) ??
                desc.split(',').first.trim();
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
          })
          .where((r) => r.description.isNotEmpty)
          .toList();
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
    // API-0.6a — guard: min-length, cache, timeout, error safety
    // No Lunao-first for transport (airport/train station ≠ destination)
    return _autocompleteGuard.execute(
      query: query,
      context: 'transport',
      fallback: () => _autocompleteTransportImpl(
        query,
        type: type,
        sessionToken: sessionToken,
      ),
    );
  }

  Future<List<({String description, String mainText, String placeId})>>
  _autocompleteTransportImpl(
    String query, {
    required String type,
    String? sessionToken,
  }) async {
    final key = _apiKey;
    final trimmed = query.trim();
    if (trimmed.length < 2 || !_hasApiKey) return const [];
    if (type != 'airport' && type != 'train_station') return const [];
    _assertGooglePlacesAllowed('PlacesService.autocompleteTransport');
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
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        params,
      );
      final resp = await _get(uri);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        developer.log(
          'Autocomplete transport status=${data['status']}',
          name: 'places',
        );
        return const [];
      }
      final preds = (data['predictions'] as List?) ?? const [];
      return preds
          .whereType<Map<String, dynamic>>()
          .map((p) {
            final desc = (p['description'] as String?) ?? '';
            final structured =
                p['structured_formatting'] as Map<String, dynamic>?;
            final main =
                (structured?['main_text'] as String?) ??
                desc.split(',').first.trim();
            return (
              description: desc,
              mainText: main,
              placeId: (p['place_id'] as String?) ?? '',
            );
          })
          .where((r) => r.description.isNotEmpty)
          .toList();
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
  Future<
    ({double lat, double lng, String name, String? countryCode, String? city})?
  >
  resolvePlaceCoords(String placeId, {String? sessionToken}) async {
    final key = _apiKey;
    if (placeId.isEmpty || !_hasApiKey) return null;
    _assertGooglePlacesAllowed('PlacesService.resolvePlaceCoords');
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
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/details/json',
        params,
      );
      final resp = await _get(uri);
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
        final types = ((comp['types'] as List?) ?? const [])
            .whereType<String>()
            .toSet();
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
        if (types.contains('sublocality_level_1') ||
            types.contains('sublocality')) {
          sublocalityLevel1 = long;
        }
        if (types.contains('administrative_area_level_2')) adminLevel2 = long;
      }
      // Override pour les aéroports majeurs : si les coords matchent un aéroport
      // connu (haversine < 5 km), on prend la ville touristique attendue par le
      // voyageur (BKK→Bangkok, CDG→Paris, NRT→Tokyo) au lieu de la subdivision
      // administrative locale (Samut Prakan, Roissy-en-France, Chiba). Si pas
      // d'override, fallback sur la cascade address_components standard.
      final city =
          overrideCityForAirportLatLng(lat, lng) ??
          pickCityFromComponents(
            locality: locality,
            postalTown: postalTown,
            adminLevel1: adminLevel1,
            sublocalityLevel1: sublocalityLevel1,
            adminLevel2: adminLevel2,
          );
      return (
        lat: lat,
        lng: lng,
        name: name,
        countryCode: countryCode,
        city: city,
      );
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
    // API-0.6b — Lunao synthetic placeIds carry embedded country codes.
    if (placeId == 'lunao:lisbon') return 'pt';
    if (placeId.startsWith('lunao:country:')) {
      return placeId.substring('lunao:country:'.length).toLowerCase();
    }
    // API-0.6c — Lunao region placeIds: lunao:region:<cc>:<key>
    if (placeId.startsWith('lunao:region:')) {
      final parts = placeId.split(':');
      if (parts.length >= 3 && parts[2].length == 2) {
        return parts[2].toLowerCase();
      }
    }

    final key = _apiKey;
    if (placeId.isEmpty || !_hasApiKey) return null;
    _assertGooglePlacesAllowed('PlacesService.getCountryCodeFromPlaceId');
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/details/json',
        {
          'place_id': placeId,
          'fields': 'address_component',
          'language': 'fr',
          'key': key,
        },
      );
      final resp = await _get(uri);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;
      final components =
          ((data['result'] as Map<String, dynamic>?)?['address_components']
              as List?) ??
          const [];
      for (final comp in components.whereType<Map<String, dynamic>>()) {
        final types = ((comp['types'] as List?) ?? const [])
            .whereType<String>();
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
    final key = _apiKey;
    if (!_hasApiKey) return null;
    final query = country != null && country.isNotEmpty
        ? '$city, $country'
        : city;
    if (query.trim().isEmpty) return null;
    _assertGooglePlacesAllowed('PlacesService.findCityCoords');
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/findplacefromtext/json',
        {
          'input': query,
          'inputtype': 'textquery',
          'fields': 'geometry,formatted_address',
          'language': 'fr',
          'key': key,
        },
      );
      final resp = await _get(uri);
      if (resp.statusCode != 200) {
        developer.log(
          'FindPlace city HTTP ${resp.statusCode} pour "$query"',
          name: 'places',
        );
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      if (status != 'OK') {
        developer.log(
          'FindPlace city status=$status pour "$query"',
          name: 'places',
        );
        return null;
      }
      final candidates = (data['candidates'] as List?) ?? const [];
      if (candidates.isEmpty) return null;
      final first = candidates.first as Map<String, dynamic>;
      final loc =
          (first['geometry'] as Map<String, dynamic>?)?['location']
              as Map<String, dynamic>?;
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
  Future<({List<PlaceReview> reviews, OpeningHours? openingHours})> getDetails(
    String placeId,
  ) async {
    final key = _apiKey;
    if (!_hasApiKey) {
      return (reviews: const <PlaceReview>[], openingHours: null);
    }
    if (placeId.isEmpty) {
      return (reviews: const <PlaceReview>[], openingHours: null);
    }
    _assertGooglePlacesAllowed('PlacesService.getDetails');
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
            'place_id': placeId,
            'fields': 'reviews,opening_hours',
            'language': 'fr',
            'reviews_sort': 'newest',
            'key': key,
          });
      final resp = await _get(uri);
      if (resp.statusCode != 200) {
        return (reviews: const <PlaceReview>[], openingHours: null);
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') {
        return (reviews: const <PlaceReview>[], openingHours: null);
      }
      final result = data['result'] as Map<String, dynamic>?;
      final reviewsData = result?['reviews'] as List?;
      final hoursData = result?['opening_hours'] as Map<String, dynamic>?;
      final reviews =
          reviewsData
              ?.whereType<Map<String, dynamic>>()
              .map((r) => PlaceReview.fromJson(r))
              .toList() ??
          const <PlaceReview>[];
      final openingHours = hoursData != null
          ? OpeningHours.fromJson(hoursData)
          : null;
      return (reviews: reviews, openingHours: openingHours);
    } catch (e) {
      developer.log('Erreur Places details : $e', name: 'places');
      return (reviews: const <PlaceReview>[], openingHours: null);
    }
  }
}
