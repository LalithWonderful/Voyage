class TransportOption {
  final String mode; // walk, taxi, metro, bus, bike, car, train
  final int durationMinutes;
  final String priceEstimate;
  final String? detail;

  const TransportOption({
    required this.mode,
    required this.durationMinutes,
    required this.priceEstimate,
    this.detail,
  });

  factory TransportOption.fromJson(Map<String, dynamic> json) => TransportOption(
    mode: json['mode'] as String? ?? 'walk',
    durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 0,
    priceEstimate: json['price_estimate'] as String? ?? 'Gratuit',
    detail: json['detail'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'duration_minutes': durationMinutes,
    'price_estimate': priceEstimate,
    if (detail != null) 'detail': detail,
  };
}

class TripTransport {
  final String id;
  final String tripId;
  final String fromActivityId;
  final String toActivityId;
  final String selectedMode;
  final int selectedDurationMinutes;
  final String selectedPriceEstimate;
  final List<TransportOption> options;

  const TripTransport({
    required this.id,
    required this.tripId,
    required this.fromActivityId,
    required this.toActivityId,
    required this.selectedMode,
    required this.selectedDurationMinutes,
    required this.selectedPriceEstimate,
    this.options = const [],
  });

  factory TripTransport.fromJson(Map<String, dynamic> json) => TripTransport(
    id: json['id'] as String,
    tripId: json['trip_id'] as String,
    fromActivityId: json['from_activity_id'] as String,
    toActivityId: json['to_activity_id'] as String,
    selectedMode: json['selected_mode'] as String? ?? 'walk',
    selectedDurationMinutes: (json['selected_duration_minutes'] as num?)?.toInt() ?? 0,
    selectedPriceEstimate: json['selected_price_estimate'] as String? ?? 'Gratuit',
    options: (json['options'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => TransportOption.fromJson(e))
            .toList() ??
        const [],
  );
}

const transportModeEmojis = {
  'walk': '🚶',
  'taxi': '🚕',
  'transit': '🚍',
  'metro': '🚇',
  'tram': '🚊',
  'bus': '🚌',
  'bike': '🚴',
  'car': '🚗',
  'train': '🚆',
  'boat': '⛴️',
  'tuktuk': '🛺',
  'plane': '✈️',
};

const transportModeLabels = {
  'walk': 'À pied',
  'taxi': 'Taxi',
  // `transit` = mode générique des transports en commun retourné par Routes API
  // quand on ne sait pas le réseau exact (métro, tram, bus selon la ville). Évite
  // d'afficher "Métro" à Nancy qui n'en a pas, ou "Bus" à Paris où ce serait le métro.
  'transit': 'Transports en commun',
  'metro': 'Métro',
  'tram': 'Tram',
  'bus': 'Bus',
  'bike': 'Vélo',
  'car': 'Voiture',
  'train': 'Train',
  'boat': 'Bateau',
  'tuktuk': 'Tuk-tuk',
  'plane': 'Avion',
};

String transportModeLabel(String mode) => transportModeLabels[mode] ?? mode;
String transportModeEmoji(String mode) => transportModeEmojis[mode] ?? '🚀';
