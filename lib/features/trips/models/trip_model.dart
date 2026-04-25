class Traveler {
  final String name;
  final int age;

  const Traveler({required this.name, required this.age});

  factory Traveler.fromJson(Map<String, dynamic> json) => Traveler(
    name: json['name'] as String,
    age: (json['age'] as num).toInt(),
  );

  Map<String, dynamic> toJson() => {'name': name, 'age': age};
}

class Accommodation {
  final String name;
  final String? address;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final String? reservationNumber;

  const Accommodation({
    required this.name,
    this.address,
    this.checkIn,
    this.checkOut,
    this.reservationNumber,
  });

  factory Accommodation.fromJson(Map<String, dynamic> json) => Accommodation(
    name: json['name'] as String? ?? '',
    address: json['address'] as String?,
    checkIn: json['check_in'] != null ? DateTime.parse(json['check_in'] as String) : null,
    checkOut: json['check_out'] != null ? DateTime.parse(json['check_out'] as String) : null,
    reservationNumber: json['reservation_number'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (address != null && address!.isNotEmpty) 'address': address,
    if (checkIn != null) 'check_in': checkIn!.toIso8601String().split('T').first,
    if (checkOut != null) 'check_out': checkOut!.toIso8601String().split('T').first,
    if (reservationNumber != null && reservationNumber!.isNotEmpty) 'reservation_number': reservationNumber,
  };
}

/// Une étape d'un voyage multi-villes : ville + nombre de nuits sur place.
/// Les dates exactes sont calculées au runtime depuis `trip.startDate` + l'ordre dans
/// la liste + cumul des nuits des étapes précédentes.
///
/// Avantages vs (from, to) absolu :
/// - Le voyageur peut **réordonner** les étapes sans avoir à recalculer manuellement les dates
/// - L'IA peut suggérer une boucle régionale sans imposer de calendrier strict
/// - Plus simple à saisir (juste "combien de nuits ?" au lieu de 2 date pickers)
class TripSegment {
  final String city;
  final int nights;

  const TripSegment({required this.city, required this.nights});

  factory TripSegment.fromJson(Map<String, dynamic> json) {
    // Rétrocompat : si l'ancien format (from + to) existe encore en DB, on convertit.
    final nightsRaw = json['nights'];
    if (nightsRaw is num) {
      return TripSegment(city: json['city'] as String, nights: nightsRaw.toInt());
    }
    final fromStr = json['from'] as String?;
    final toStr = json['to'] as String?;
    if (fromStr != null && toStr != null) {
      final from = DateTime.parse(fromStr);
      final to = DateTime.parse(toStr);
      final n = to.difference(from).inDays + 1;
      return TripSegment(city: json['city'] as String, nights: n.clamp(1, 365));
    }
    return TripSegment(city: json['city'] as String, nights: 1);
  }

  Map<String, dynamic> toJson() => {'city': city, 'nights': nights};

  TripSegment copyWith({String? city, int? nights}) =>
      TripSegment(city: city ?? this.city, nights: nights ?? this.nights);
}

/// Mode de planification choisi pour ce voyage par le voyageur.
/// - `auto` : l'IA propose un planning complet, le voyageur ajuste après
/// - `coPilot` : l'IA propose 3 options par créneau, décochées par défaut, le voyageur choisit
/// - `null` (non stocké) : pas encore choisi → poser la question au prochain Suggérer
enum PlanningMode {
  auto,
  coPilot;

  static PlanningMode? fromString(String? raw) {
    switch (raw) {
      case 'auto':
        return PlanningMode.auto;
      case 'co_pilot':
        return PlanningMode.coPilot;
      default:
        return null;
    }
  }

  String get dbValue => switch (this) {
    PlanningMode.auto => 'auto',
    PlanningMode.coPilot => 'co_pilot',
  };
}

class Trip {
  final String id;
  final String userId;
  final String title;
  final String destination;
  final DateTime startDate;
  final DateTime endDate;
  final String coverEmoji;
  final String status;
  final List<Traveler> travelers;
  final Accommodation? accommodation;
  final String? travelerType;
  final List<String>? interests;
  final PlanningMode? planningMode;
  final List<TripSegment> itinerarySegments;
  final DateTime createdAt;

  const Trip({
    required this.id,
    required this.userId,
    required this.title,
    required this.destination,
    required this.startDate,
    required this.endDate,
    this.coverEmoji = '✈️',
    this.status = 'upcoming',
    this.travelers = const [],
    this.accommodation,
    this.travelerType,
    this.interests,
    this.planningMode,
    this.itinerarySegments = const [],
    required this.createdAt,
  });

  /// Date de début (incluse) calculée pour un segment selon son ordre dans la liste.
  /// Égale à `startDate` + cumul des nuits des segments précédents.
  DateTime segmentStart(int segmentIndex) {
    var offset = 0;
    for (var i = 0; i < segmentIndex && i < itinerarySegments.length; i++) {
      offset += itinerarySegments[i].nights;
    }
    return startDate.add(Duration(days: offset));
  }

  /// Date de fin (incluse) calculée pour un segment.
  DateTime segmentEnd(int segmentIndex) {
    final start = segmentStart(segmentIndex);
    final n = itinerarySegments[segmentIndex].nights;
    return start.add(Duration(days: n - 1));
  }

  /// Retourne la ville à utiliser pour les suggestions/validations sur ce jour précis.
  /// Calcul : on parcourt les segments dans l'ordre, on accumule les nuits, et on
  /// retourne la ville du segment qui couvre le jour. Sinon → fallback `destination`
  /// (utile pour les jours résiduels après la dernière étape, ex: jour de retour).
  String cityForDay(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final s = DateTime(startDate.year, startDate.month, startDate.day);
    if (d.isBefore(s)) return destination;
    final dayOffset = d.difference(s).inDays;
    var cumulative = 0;
    for (final seg in itinerarySegments) {
      if (dayOffset >= cumulative && dayOffset < cumulative + seg.nights) {
        return seg.city;
      }
      cumulative += seg.nights;
    }
    return destination;
  }

  int get durationDays => endDate.difference(startDate).inDays + 1;

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    title: json['title'] as String,
    destination: json['destination'] as String,
    startDate: DateTime.parse(json['start_date'] as String),
    endDate: DateTime.parse(json['end_date'] as String),
    coverEmoji: json['cover_emoji'] as String? ?? '✈️',
    status: json['status'] as String? ?? 'upcoming',
    travelers: (json['travelers'] as List?)?.map((e) => Traveler.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
    accommodation: json['accommodation'] != null && (json['accommodation'] as Map).isNotEmpty
        ? Accommodation.fromJson(json['accommodation'] as Map<String, dynamic>)
        : null,
    travelerType: json['traveler_type'] as String?,
    interests: (json['interests'] as List?)?.map((e) => e.toString()).toList(),
    planningMode: PlanningMode.fromString(json['planning_mode'] as String?),
    itinerarySegments: (json['itinerary_segments'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => TripSegment.fromJson(e))
            .toList() ??
        const [],
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
