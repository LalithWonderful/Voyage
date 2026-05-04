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

/// Une étape d'un voyage multi-villes : ville + nombre de **jours** sur place.
/// Les dates exactes sont calculées au runtime depuis `trip.startDate` + l'ordre dans
/// la liste + cumul des jours des étapes précédentes.
///
/// Sémantique "jours" (pas "nuits") : pour un voyage 9 jours mono-ville, on entre
/// "Nancy 9 jours" (1 segment qui couvre tout). Le voyageur peut louer un appart
/// pour la durée et faire des day-trips. Somme cible des jours = `trip.durationDays`.
///
/// Avantages vs (from, to) absolu :
/// - Le voyageur peut **réordonner** les étapes sans avoir à recalculer manuellement les dates
/// - L'IA peut suggérer une boucle régionale sans imposer de calendrier strict
/// - Plus simple à saisir (juste "combien de jours ?" au lieu de 2 date pickers)
class TripSegment {
  final String city;
  /// Nombre de jours calendaires que le voyageur passe basé dans cette ville.
  /// Stocké en JSON sous la clé `days` (anciennement `nights` — lecture rétrocompat).
  final int days;
  /// Pays affiché à côté de la ville (ex: "France", "Allemagne"). Sert au visuel
  /// (carte étape) et au prompt IA. Optionnel pour rétrocompat — les anciennes
  /// étapes saisies avant l'ajout du champ n'ont pas de pays.
  final String? country;
  /// Coordonnées du centre-ville, mises en cache après le 1er géocodage.
  /// Évite de re-payer la Places API à chaque clic sur "Optimiser l'ordre".
  final double? latitude;
  final double? longitude;

  const TripSegment({
    required this.city,
    required this.days,
    this.country,
    this.latitude,
    this.longitude,
  });

  factory TripSegment.fromJson(Map<String, dynamic> json) {
    final country = (json['country'] as String?)?.trim();
    final lat = (json['latitude'] as num?)?.toDouble();
    final lng = (json['longitude'] as num?)?.toDouble();
    // Lecture : on accepte `days` (nouveau) ET `nights` (legacy).
    // À la suite de la migration sémantique nuits→jours, on interprète l'ancien
    // entier `nights` comme un nombre de jours (les valeurs étaient sur la même
    // échelle, juste l'étiquette change). Pas de DB migration nécessaire.
    final daysRaw = json['days'] ?? json['nights'];
    if (daysRaw is num) {
      return TripSegment(
        city: json['city'] as String,
        days: daysRaw.toInt(),
        country: country == null || country.isEmpty ? null : country,
        latitude: lat,
        longitude: lng,
      );
    }
    // Rétrocompat ancien format (from + to)
    final fromStr = json['from'] as String?;
    final toStr = json['to'] as String?;
    if (fromStr != null && toStr != null) {
      final from = DateTime.parse(fromStr);
      final to = DateTime.parse(toStr);
      final n = to.difference(from).inDays + 1;
      return TripSegment(
        city: json['city'] as String,
        days: n.clamp(1, 365),
        country: country == null || country.isEmpty ? null : country,
        latitude: lat,
        longitude: lng,
      );
    }
    return TripSegment(
      city: json['city'] as String,
      days: 1,
      country: country == null || country.isEmpty ? null : country,
      latitude: lat,
      longitude: lng,
    );
  }

  Map<String, dynamic> toJson() => {
    'city': city,
    'days': days,
    if (country != null && country!.isNotEmpty) 'country': country,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
  };

  TripSegment copyWith({
    String? city,
    int? days,
    String? country,
    double? latitude,
    double? longitude,
  }) =>
      TripSegment(
        city: city ?? this.city,
        days: days ?? this.days,
        country: country ?? this.country,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
      );
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

  /// ISO 2 du pays détecté à partir de la destination (ex: 'US', 'TH').
  /// Mémorisé à la création/édition pour éviter de re-fetcher Place Details.
  final String? destinationCountryCode;

  /// Nom FR du pays (ex: 'États-Unis'). Utile pour l'UI sans relookup table.
  final String? destinationCountryName;

  /// Type de destination détecté ('city', 'country', 'region', 'place', 'unknown').
  /// Sert à décider du flow de suggestion (régions vs rayon manuel).
  final String? destinationKind;

  /// ID Supabase de la région choisie dans `country_regions` (ou null si
  /// pays non concerné OU "Tout le pays" choisi sur travel_region).
  final int? selectedRegionId;

  /// Nom FR de la région choisie (ex: 'New York & Côte Est'). Dupliqué
  /// pour affichage rapide sans re-lookup.
  final String? selectedRegionName;

  /// Rayon (km) de la région choisie. Pré-rempli depuis
  /// `country_regions.recommended_radius_km` au moment du choix.
  final int? selectedRegionRadiusKm;

  /// Mode de période choisi par l'utilisateur à la création :
  /// - `'exact'` (ou null pour les voyages legacy) : startDate/endDate sont
  ///   les vraies dates choisies. Affichage "du 12 au 18 juin".
  /// - `'month'` : l'utilisateur a indiqué un mois cible sans dates précises.
  ///   startDate/endDate sont synthétisées (1er du mois → +6 jours) pour
  ///   rester exploitables par planning/IA/wallet, mais l'affichage doit
  ///   utiliser `targetPeriod` ("Plutôt en septembre 2026").
  /// - `'recommended'` (commit 3) : période suggérée par l'app sur la base
  ///   de la destination (saison sèche, festival, etc.).
  final String? periodMode;

  /// Mois cible au format `YYYY-MM` (ex: '2026-09'). Renseigné quand
  /// `periodMode` ∈ {'month', 'recommended'}. Null pour les voyages à dates
  /// exactes.
  final String? targetPeriod;

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
    this.destinationCountryCode,
    this.destinationCountryName,
    this.destinationKind,
    this.selectedRegionId,
    this.selectedRegionName,
    this.selectedRegionRadiusKm,
    this.periodMode,
    this.targetPeriod,
  });

  /// True quand le voyage a des dates réelles choisies par l'utilisateur.
  /// False quand il est en mode "mois cible", "saison conseillée" ou "non
  /// spécifié" : dans ce cas startDate/endDate sont synthétiques et
  /// l'affichage doit privilégier `targetPeriodLabel` (ou "Dates à préciser"
  /// pour 'unspecified') plutôt que les dates exactes. Tolère aussi les
  /// valeurs inconnues (= traitées comme exactes par défaut, plus
  /// conservateur que de masquer les dates).
  bool get hasExactDates {
    final mode = periodMode;
    if (mode == null) return true;
    return !{'month', 'unspecified', 'recommended'}.contains(mode);
  }

  /// True quand l'utilisateur a explicitement laissé sa période vide.
  /// Différent de 'month' (mois choisi) — dans ce cas l'affichage doit
  /// montrer "Dates à préciser" plutôt qu'un mois (le mois courant est
  /// stocké en BDD comme fenêtre exploratoire pour le pipeline IA, mais
  /// l'utilisateur ne l'a pas choisi → ne pas le lui afficher).
  bool get hasUnspecifiedPeriod => periodMode == 'unspecified';

  /// True quand la période vient d'une recommandation Lunao (saisonnalité)
  /// acceptée par l'utilisateur via la sheet. À distinguer de 'month' (mois
  /// choisi librement) : l'UI affiche "Recommandé : Mai 2026" pour bien
  /// signaler l'origine du choix.
  bool get hasRecommendedPeriod => periodMode == 'recommended';

  /// Libellé humain du mois cible ("Septembre 2026") dérivé de `targetPeriod`
  /// au format YYYY-MM. Null si dates exactes ou format invalide.
  String? get targetPeriodLabel {
    final raw = targetPeriod;
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('-');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null || month < 1 || month > 12) return null;
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    final name = months[month - 1];
    return '${name[0].toUpperCase()}${name.substring(1)} $year';
  }

  /// Date de début (incluse) calculée pour un segment selon son ordre dans la liste.
  /// Égale à `startDate` + cumul des jours des segments précédents.
  DateTime segmentStart(int segmentIndex) {
    var offset = 0;
    for (var i = 0; i < segmentIndex && i < itinerarySegments.length; i++) {
      offset += itinerarySegments[i].days;
    }
    return startDate.add(Duration(days: offset));
  }

  /// Date de fin (incluse) calculée pour un segment.
  DateTime segmentEnd(int segmentIndex) {
    final start = segmentStart(segmentIndex);
    final n = itinerarySegments[segmentIndex].days;
    return start.add(Duration(days: n - 1));
  }

  /// Retourne la ville à utiliser pour les suggestions/validations sur ce jour précis.
  /// Calcul : on parcourt les segments dans l'ordre, on accumule les jours, et on
  /// retourne la ville du segment qui couvre le jour. Sinon → fallback `destination`
  /// (utile pour les jours résiduels après la dernière étape).
  String cityForDay(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final s = DateTime(startDate.year, startDate.month, startDate.day);
    if (d.isBefore(s)) return destination;
    final dayOffset = d.difference(s).inDays;
    var cumulative = 0;
    for (final seg in itinerarySegments) {
      if (dayOffset >= cumulative && dayOffset < cumulative + seg.days) {
        return seg.city;
      }
      cumulative += seg.days;
    }
    return destination;
  }

  int get durationDays => endDate.difference(startDate).inDays + 1;

  /// Crée une copie en remplaçant uniquement les champs fournis. Utile pour
  /// matérialiser un "trip effectif" en runtime (ex: fallback intérêts/profil
  /// voyageur sur le profil utilisateur global quand le voyage ne les définit
  /// pas) avant de le passer au pipeline de suggestions.
  Trip copyWith({
    String? id,
    String? userId,
    String? title,
    String? destination,
    DateTime? startDate,
    DateTime? endDate,
    String? coverEmoji,
    String? status,
    List<Traveler>? travelers,
    Accommodation? accommodation,
    String? travelerType,
    List<String>? interests,
    PlanningMode? planningMode,
    List<TripSegment>? itinerarySegments,
    DateTime? createdAt,
    String? destinationCountryCode,
    String? destinationCountryName,
    String? destinationKind,
    int? selectedRegionId,
    String? selectedRegionName,
    int? selectedRegionRadiusKm,
    String? periodMode,
    String? targetPeriod,
  }) {
    return Trip(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      destination: destination ?? this.destination,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      coverEmoji: coverEmoji ?? this.coverEmoji,
      status: status ?? this.status,
      travelers: travelers ?? this.travelers,
      accommodation: accommodation ?? this.accommodation,
      travelerType: travelerType ?? this.travelerType,
      interests: interests ?? this.interests,
      planningMode: planningMode ?? this.planningMode,
      itinerarySegments: itinerarySegments ?? this.itinerarySegments,
      createdAt: createdAt ?? this.createdAt,
      destinationCountryCode: destinationCountryCode ?? this.destinationCountryCode,
      destinationCountryName: destinationCountryName ?? this.destinationCountryName,
      destinationKind: destinationKind ?? this.destinationKind,
      selectedRegionId: selectedRegionId ?? this.selectedRegionId,
      selectedRegionName: selectedRegionName ?? this.selectedRegionName,
      selectedRegionRadiusKm: selectedRegionRadiusKm ?? this.selectedRegionRadiusKm,
      periodMode: periodMode ?? this.periodMode,
      targetPeriod: targetPeriod ?? this.targetPeriod,
    );
  }

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
    destinationCountryCode: json['destination_country_code'] as String?,
    destinationCountryName: json['destination_country_name'] as String?,
    destinationKind: json['destination_kind'] as String?,
    selectedRegionId: (json['selected_region_id'] as num?)?.toInt(),
    selectedRegionName: json['selected_region_name'] as String?,
    selectedRegionRadiusKm: (json['selected_region_radius_km'] as num?)?.toInt(),
    periodMode: json['period_mode'] as String?,
    targetPeriod: json['target_period'] as String?,
  );
}
