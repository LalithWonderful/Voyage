class ActivitySuggestion {
  final DateTime dayDate;
  final String startTime;
  final String title;
  final String? detail;
  final String tag;
  final int? durationMinutes;
  final String? priceEstimate;
  /// Phrase courte expliquant pourquoi cette option matche le profil voyageur
  /// (ex: "Matche ton intérêt 'Hors circuit' + budget Backpack"). Affichée dans
  /// les cartes en mode coPilot pour aider le voyageur à choisir entre les 3
  /// options d'un même créneau. Optionnel (mode auto ne le génère pas).
  final String? matchReason;

  const ActivitySuggestion({
    required this.dayDate,
    required this.startTime,
    required this.title,
    this.detail,
    required this.tag,
    this.durationMinutes,
    this.priceEstimate,
    this.matchReason,
  });

  factory ActivitySuggestion.fromJson(Map<String, dynamic> json) => ActivitySuggestion(
    dayDate: DateTime.parse(json['day_date'] as String),
    startTime: json['start_time'] as String? ?? '',
    title: json['title'] as String,
    detail: json['detail'] as String?,
    tag: json['tag'] as String? ?? 'Activité',
    durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
    priceEstimate: json['price_estimate'] as String?,
    matchReason: (json['match_reason'] as String?)?.trim().isEmpty == true
        ? null
        : json['match_reason'] as String?,
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

/// Un créneau (jour + plage horaire) avec plusieurs options alternatives.
/// Utilisé en mode coPilot où Gemini propose 3 options par créneau, et le
/// voyageur coche celle(s) qui lui plaisent (multi-select). En mode auto on
/// reste sur une liste plate d'`ActivitySuggestion` (1 par créneau, tout coché).
///
/// `slotLabel` : étiquette humaine du créneau ("Matin", "Déjeuner", "Soirée"...).
/// Sert d'en-tête de section dans la sheet de prévisualisation.
/// `startTime` : heure de référence du créneau (HH:MM). Si Gemini propose des
/// options à des heures légèrement différentes (10h vs 10h30), on garde l'heure
/// de chaque option, ce champ sert juste au tri et à l'affichage.
class SuggestionGroup {
  final DateTime dayDate;
  final String slotLabel;
  final String startTime;
  final List<ActivitySuggestion> options;

  const SuggestionGroup({
    required this.dayDate,
    required this.slotLabel,
    required this.startTime,
    required this.options,
  });

  SuggestionGroup copyWith({List<ActivitySuggestion>? options}) => SuggestionGroup(
        dayDate: dayDate,
        slotLabel: slotLabel,
        startTime: startTime,
        options: options ?? this.options,
      );

  factory SuggestionGroup.fromJson(Map<String, dynamic> json) {
    final opts = (json['options'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) {
              // Gemini renvoie les options sans day_date (héritée du groupe)
              // → on l'injecte avant de parser pour respecter le contrat ActivitySuggestion.
              final merged = Map<String, dynamic>.from(e);
              merged.putIfAbsent('day_date', () => json['day_date']);
              merged.putIfAbsent('start_time', () => e['start_time'] ?? json['start_time']);
              return ActivitySuggestion.fromJson(merged);
            })
            .toList() ??
        const <ActivitySuggestion>[];
    return SuggestionGroup(
      dayDate: DateTime.parse(json['day_date'] as String),
      slotLabel: (json['slot_label'] as String?)?.trim().isEmpty == true
          ? 'Créneau'
          : (json['slot_label'] as String? ?? 'Créneau'),
      startTime: json['start_time'] as String? ?? '',
      options: opts,
    );
  }
}

String formatDuration(int? minutes) {
  if (minutes == null || minutes <= 0) return '';
  if (minutes < 60) return '${minutes}min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
}
