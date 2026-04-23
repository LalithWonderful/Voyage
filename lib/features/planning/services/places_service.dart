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
  final List<PlaceReview>? reviews;
  final OpeningHours? openingHours;

  const PlaceInfo({
    this.photos = const [],
    this.rating,
    this.ratingsCount,
    this.priceLevel,
    this.placeId,
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
        'fields': 'photos,place_id,name,rating,user_ratings_total,price_level',
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
