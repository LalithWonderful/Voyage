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

/// V6 (Lalith 2026-05-10 — Lot E TODO 3) — état de planification d'une
/// activité par rapport à l'itinéraire courant. Persisté en DB via la
/// colonne `trip_activities.planning_status` (cf. migration SQL).
///
/// `planned` est le défaut implicite pour les anciennes lignes (avant
/// la migration) — `_parsePlanningStatus` retombe dessus pour toute
/// valeur inconnue.
enum PlanningStatus {
  /// Activité valide dans l'itinéraire courant.
  planned,

  /// Générée par Lunao puis l'itinéraire a muté → masquée du planning
  /// principal mais conservée pour permettre une restauration.
  stale,

  /// Activité utilisateur dont la date est sortie des segments
  /// (cf. Lot E TODO 1). Pas encore persisté côté DB — calculé à
  /// la volée par `findOrphanedActivities`.
  toReposition,

  /// Activité importée d'un doc dont la ville n'est plus dans
  /// l'itinéraire (cf. Lot E TODO 2). Pas encore persisté.
  conflict,
}

PlanningStatus _parsePlanningStatus(dynamic raw) {
  if (raw is! String) return PlanningStatus.planned;
  switch (raw) {
    case 'stale':
      return PlanningStatus.stale;
    case 'to_reposition':
      return PlanningStatus.toReposition;
    case 'conflict':
      return PlanningStatus.conflict;
    case 'planned':
    default:
      return PlanningStatus.planned;
  }
}

String _planningStatusToColumn(PlanningStatus s) {
  switch (s) {
    case PlanningStatus.planned:
      return 'planned';
    case PlanningStatus.stale:
      return 'stale';
    case PlanningStatus.toReposition:
      return 'to_reposition';
    case PlanningStatus.conflict:
      return 'conflict';
  }
}

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

  /// V6 (Lalith 2026-05-10 — Lot E TODO 3) — état de planification :
  /// `planned` par défaut, `stale` quand l'itinéraire a muté et que
  /// l'activité générée n'est plus auto-validée.
  final PlanningStatus planningStatus;

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
    this.planningStatus = PlanningStatus.planned,
  });

  bool get hasCoordinates => latitude != null && longitude != null;
  bool get isLogistic => kind == ActivityKind.logistic;
  bool get isStale => planningStatus == PlanningStatus.stale;

  /// Sérialisation de la `kind` vers la colonne SQL `activity_kind`. À utiliser
  /// dans tout INSERT/UPDATE qui touche `trip_activities` pour rester cohérent.
  static String kindColumnValue(ActivityKind k) => _kindToColumn(k);

  /// Sérialisation de `planningStatus` vers la colonne SQL
  /// `planning_status` (V6 Lot E TODO 3).
  static String planningStatusColumnValue(PlanningStatus s) =>
      _planningStatusToColumn(s);

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
    planningStatus: _parsePlanningStatus(json['planning_status']),
  );
}
