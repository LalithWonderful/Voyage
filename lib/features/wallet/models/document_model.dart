class DocumentCategory {
  static const hotel = 'hotel';
  static const flight = 'flight';
  static const train = 'train';
  static const carRental = 'car_rental';
  static const ticket = 'ticket';
  static const other = 'other';

  static const all = [hotel, flight, train, carRental, ticket, other];
}

const Map<String, String> _categoryLabels = {
  DocumentCategory.hotel: 'Hébergement',
  DocumentCategory.flight: 'Vol',
  DocumentCategory.train: 'Train',
  DocumentCategory.carRental: 'Location',
  DocumentCategory.ticket: 'Billet',
  DocumentCategory.other: 'Autre',
};

const Map<String, String> _categoryEmojis = {
  DocumentCategory.hotel: '🏨',
  DocumentCategory.flight: '✈️',
  DocumentCategory.train: '🚆',
  DocumentCategory.carRental: '🚗',
  DocumentCategory.ticket: '🎫',
  DocumentCategory.other: '📄',
};

String categoryLabel(String c) => _categoryLabels[c] ?? 'Autre';
String categoryEmoji(String c) => _categoryEmojis[c] ?? '📄';

class TripDocument {
  final String id;
  final String userId;
  final String? tripId;
  final String category;
  final String name;
  final Map<String, dynamic> metadata;
  final String? fileUrl;
  final DateTime createdAt;

  const TripDocument({
    required this.id,
    required this.userId,
    this.tripId,
    required this.category,
    required this.name,
    this.metadata = const {},
    this.fileUrl,
    required this.createdAt,
  });

  factory TripDocument.fromJson(Map<String, dynamic> json) => TripDocument(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    tripId: json['trip_id'] as String?,
    category: json['category'] as String? ?? DocumentCategory.other,
    name: json['name'] as String,
    metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
    fileUrl: json['file_url'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  Map<String, dynamic> toInsertJson() => {
    'user_id': userId,
    if (tripId != null) 'trip_id': tripId,
    'category': category,
    'name': name,
    'metadata': metadata,
    if (fileUrl != null) 'file_url': fileUrl,
  };

  static String _fmtDate(dynamic v) {
    if (v == null) return '';
    try {
      final d = DateTime.parse(v as String);
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return v.toString();
    }
  }

  /// Sous-titre court pour l'affichage en liste, selon la catégorie
  String get subtitle {
    final m = metadata;
    switch (category) {
      case DocumentCategory.hotel:
        final parts = <String>[];
        if (m['check_in'] != null && m['check_out'] != null) {
          parts.add('${_fmtDate(m['check_in'])} → ${_fmtDate(m['check_out'])}');
        }
        if (m['address'] != null && (m['address'] as String).isNotEmpty) parts.add(m['address'] as String);
        return parts.join(' · ');
      case DocumentCategory.flight:
        final parts = <String>[];
        if (m['from'] != null && m['to'] != null) parts.add('${m['from']} → ${m['to']}');
        if (m['date'] != null) parts.add(_fmtDate(m['date']));
        if (m['flight_number'] != null) parts.add(m['flight_number'] as String);
        return parts.join(' · ');
      case DocumentCategory.train:
        final parts = <String>[];
        if (m['from'] != null && m['to'] != null) parts.add('${m['from']} → ${m['to']}');
        if (m['date'] != null) parts.add(_fmtDate(m['date']));
        if (m['departure_time'] != null) parts.add(m['departure_time'] as String);
        return parts.join(' · ');
      case DocumentCategory.carRental:
        final parts = <String>[];
        if (m['company'] != null) parts.add(m['company'] as String);
        if (m['pickup_date'] != null && m['return_date'] != null) {
          parts.add('${_fmtDate(m['pickup_date'])} → ${_fmtDate(m['return_date'])}');
        }
        return parts.join(' · ');
      case DocumentCategory.ticket:
        final parts = <String>[];
        if (m['venue'] != null) parts.add(m['venue'] as String);
        if (m['date'] != null) parts.add(_fmtDate(m['date']));
        if (m['time'] != null) parts.add(m['time'] as String);
        return parts.join(' · ');
      default:
        return (m['description'] as String?) ?? '';
    }
  }

  String? get reservationNumber => metadata['reservation_number'] as String?;
}
