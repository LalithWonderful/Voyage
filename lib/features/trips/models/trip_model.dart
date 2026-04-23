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
    required this.createdAt,
  });

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
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
