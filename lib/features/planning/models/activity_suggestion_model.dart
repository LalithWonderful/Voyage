class ActivitySuggestion {
  final DateTime dayDate;
  final String startTime;
  final String title;
  final String? detail;
  final String tag;
  final int? durationMinutes;
  final String? priceEstimate;

  const ActivitySuggestion({
    required this.dayDate,
    required this.startTime,
    required this.title,
    this.detail,
    required this.tag,
    this.durationMinutes,
    this.priceEstimate,
  });

  factory ActivitySuggestion.fromJson(Map<String, dynamic> json) => ActivitySuggestion(
    dayDate: DateTime.parse(json['day_date'] as String),
    startTime: json['start_time'] as String? ?? '',
    title: json['title'] as String,
    detail: json['detail'] as String?,
    tag: json['tag'] as String? ?? 'Activité',
    durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
    priceEstimate: json['price_estimate'] as String?,
  );

  Map<String, dynamic> toInsertJson(String tripId) => {
    'trip_id': tripId,
    'day_date': dayDate.toIso8601String().split('T').first,
    'start_time': startTime,
    'title': title,
    'detail': detail,
    'tag': tag,
    'suggested': true,
    'duration_minutes': durationMinutes,
    'price_estimate': priceEstimate,
  };
}

String formatDuration(int? minutes) {
  if (minutes == null || minutes <= 0) return '';
  if (minutes < 60) return '${minutes}min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
}
