/// Nature d'une activité dans la timeline d'un voyage.
///
/// `main` couvre les activités "contenu" : visites, restos, expériences — ce que
/// le voyageur veut FAIRE. `logistic` couvre les étapes de déplacement/transit
/// (aéroport, gare, transfert, retour hôtel) — pas un contenu en soi mais une
/// étape qu'il faut accomplir pour passer d'un point à l'autre.
///
/// Les activités `logistic` sont rendues différemment dans la timeline (style
/// distinct, mais info-rich : heures, lieu, durée, itinéraire prominents). Les
/// déplacements sont anxiogènes pour un voyageur, donc on ne les efface jamais.
enum ActivityKind {
  main,
  logistic,
}

ActivityKind _parseActivityKind(dynamic raw) {
  if (raw is String && raw == 'logistic') return ActivityKind.logistic;
  return ActivityKind.main;
}

String _kindToColumn(ActivityKind k) => k == ActivityKind.logistic ? 'logistic' : 'main';

class TripActivity {
  final String id;
  final String tripId;
  final DateTime dayDate;
  final String startTime;
  final String title;
  final String? detail;
  final String tag;
  final ActivityKind kind;
  final bool suggested;
  final int sortOrder;
  final int? durationMinutes;
  final String? priceEstimate;
  final double? latitude;
  final double? longitude;
  final String? description;
  final double? rating;
  final int? ratingsCount;
  final int? priceLevel;
  final List<String> photoUrls;

  const TripActivity({
    required this.id,
    required this.tripId,
    required this.dayDate,
    required this.startTime,
    required this.title,
    this.detail,
    required this.tag,
    this.kind = ActivityKind.main,
    this.suggested = false,
    this.sortOrder = 0,
    this.durationMinutes,
    this.priceEstimate,
    this.latitude,
    this.longitude,
    this.description,
    this.rating,
    this.ratingsCount,
    this.priceLevel,
    this.photoUrls = const [],
  });

  bool get hasCoordinates => latitude != null && longitude != null;
  bool get isLogistic => kind == ActivityKind.logistic;

  /// Sérialisation de la `kind` vers la colonne SQL `activity_kind`. À utiliser
  /// dans tout INSERT/UPDATE qui touche `trip_activities` pour rester cohérent.
  static String kindColumnValue(ActivityKind k) => _kindToColumn(k);

  factory TripActivity.fromJson(Map<String, dynamic> json) => TripActivity(
    id: json['id'] as String,
    tripId: json['trip_id'] as String,
    dayDate: DateTime.parse(json['day_date'] as String),
    startTime: json['start_time'] as String? ?? '',
    title: json['title'] as String,
    detail: json['detail'] as String?,
    tag: json['tag'] as String? ?? 'Activité',
    kind: _parseActivityKind(json['activity_kind']),
    suggested: json['suggested'] as bool? ?? false,
    sortOrder: json['sort_order'] as int? ?? 0,
    durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
    priceEstimate: json['price_estimate'] as String?,
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    description: json['description'] as String?,
    rating: (json['rating'] as num?)?.toDouble(),
    ratingsCount: (json['ratings_count'] as num?)?.toInt(),
    priceLevel: (json['price_level'] as num?)?.toInt(),
    photoUrls: (json['photo_urls'] as List?)?.map((e) => e.toString()).toList() ?? const [],
  );
}
