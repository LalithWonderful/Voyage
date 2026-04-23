class TripActivity {
  final String id;
  final String tripId;
  final DateTime dayDate;
  final String startTime;
  final String title;
  final String? detail;
  final String tag;
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

  factory TripActivity.fromJson(Map<String, dynamic> json) => TripActivity(
    id: json['id'] as String,
    tripId: json['trip_id'] as String,
    dayDate: DateTime.parse(json['day_date'] as String),
    startTime: json['start_time'] as String? ?? '',
    title: json['title'] as String,
    detail: json['detail'] as String?,
    tag: json['tag'] as String? ?? 'Activité',
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
