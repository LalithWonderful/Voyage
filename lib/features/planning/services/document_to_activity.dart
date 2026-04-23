import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Préfixe reconnu sur l'id d'une activité virtuelle (synthétisée depuis un document).
const virtualActivityPrefix = 'doc:';

/// Extrait l'id du document d'origine depuis une activité virtuelle, ou null si l'activité est réelle.
String? extractDocumentId(String activityId) {
  if (!activityId.startsWith(virtualActivityPrefix)) return null;
  final parts = activityId.split(':');
  if (parts.length < 3) return null;
  return parts[1];
}

bool isVirtualActivity(String activityId) => activityId.startsWith(virtualActivityPrefix);

/// Convertit un document en une ou plusieurs "activités virtuelles" pour affichage dans le planning.
/// Retourne une liste vide si le doc n'a pas de date exploitable ou n'est pas rattaché à un voyage.
List<TripActivity> virtualActivitiesFromDocument(TripDocument doc) {
  final tripId = doc.tripId;
  if (tripId == null || tripId.isEmpty) return const [];

  final m = doc.metadata;
  DateTime? parseDate(dynamic v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }
  String parseTime(dynamic v, String fallback) =>
      (v is String && v.isNotEmpty) ? v : fallback;

  switch (doc.category) {
    case DocumentCategory.hotel:
      final result = <TripActivity>[];
      final checkIn = parseDate(m['check_in']);
      final checkOut = parseDate(m['check_out']);
      // Fallback si doc.name est vide (édition incomplète, import raté...) pour
      // ne pas afficher un card avec un titre vide dans le planning.
      final hotelLabel = doc.name.trim().isNotEmpty ? doc.name.trim() : 'hébergement';
      if (checkIn != null) {
        result.add(_make(
          id: '$virtualActivityPrefix${doc.id}:checkin',
          tripId: tripId,
          dayDate: checkIn,
          startTime: '15:00',
          title: '🏨 Arrivée · $hotelLabel',
          detail: m['address'] as String?,
          tag: 'Hébergement',
          durationMinutes: 30,
        ));
      }
      if (checkOut != null) {
        result.add(_make(
          id: '$virtualActivityPrefix${doc.id}:checkout',
          tripId: tripId,
          dayDate: checkOut,
          startTime: '11:00',
          title: '🏨 Départ · $hotelLabel',
          detail: m['address'] as String?,
          tag: 'Hébergement',
          durationMinutes: 30,
        ));
      }
      return result;

    case DocumentCategory.flight:
      final date = parseDate(m['date']);
      if (date == null) return const [];
      final parts = <String>[];
      if (m['airline'] != null) parts.add(m['airline'] as String);
      if (m['flight_number'] != null) parts.add(m['flight_number'] as String);
      final line1 = parts.isEmpty ? doc.name : 'Vol ${parts.join(' ')}';
      final route = (m['from'] != null && m['to'] != null) ? ' : ${m['from']} → ${m['to']}' : '';
      return [_make(
        id: '$virtualActivityPrefix${doc.id}:flight',
        tripId: tripId,
        dayDate: date,
        startTime: parseTime(m['departure_time'], '00:00'),
        title: '$line1$route',
        detail: _flightDetail(m),
        tag: 'Transport',
        durationMinutes: _computeDurationFromTimes(m['departure_time'], m['arrival_time']) ?? 180,
      )];

    case DocumentCategory.train:
      final date = parseDate(m['date']);
      if (date == null) return const [];
      final parts = <String>[];
      if (m['company'] != null) parts.add(m['company'] as String);
      if (m['train_number'] != null) parts.add(m['train_number'] as String);
      final line1 = parts.isEmpty ? doc.name : 'Train ${parts.join(' ')}';
      final route = (m['from'] != null && m['to'] != null) ? ' : ${m['from']} → ${m['to']}' : '';
      return [_make(
        id: '$virtualActivityPrefix${doc.id}:train',
        tripId: tripId,
        dayDate: date,
        startTime: parseTime(m['departure_time'], '00:00'),
        title: '$line1$route',
        detail: _trainDetail(m),
        tag: 'Transport',
        durationMinutes: _computeDurationFromTimes(m['departure_time'], m['arrival_time']) ?? 120,
      )];

    case DocumentCategory.carRental:
      final result = <TripActivity>[];
      final pickup = parseDate(m['pickup_date']);
      final ret = parseDate(m['return_date']);
      if (pickup != null) {
        result.add(_make(
          id: '$virtualActivityPrefix${doc.id}:pickup',
          tripId: tripId,
          dayDate: pickup,
          startTime: parseTime(m['pickup_time'], '10:00'),
          title: 'Prise en charge ${doc.name}',
          detail: m['pickup_location'] as String?,
          tag: 'Transport',
          durationMinutes: 30,
        ));
      }
      if (ret != null) {
        result.add(_make(
          id: '$virtualActivityPrefix${doc.id}:return',
          tripId: tripId,
          dayDate: ret,
          startTime: parseTime(m['return_time'], '10:00'),
          title: 'Retour voiture ${doc.name}',
          detail: m['return_location'] as String?,
          tag: 'Transport',
          durationMinutes: 20,
        ));
      }
      return result;

    case DocumentCategory.ticket:
      final date = parseDate(m['date']);
      if (date == null) return const [];
      return [_make(
        id: '$virtualActivityPrefix${doc.id}:ticket',
        tripId: tripId,
        dayDate: date,
        startTime: parseTime(m['time'], '19:00'),
        title: doc.name,
        detail: (m['venue'] as String?) ?? (m['address'] as String?),
        tag: 'Billet',
        durationMinutes: 120,
      )];

    default:
      final date = parseDate(m['date']);
      if (date == null) return const [];
      return [_make(
        id: '$virtualActivityPrefix${doc.id}:other',
        tripId: tripId,
        dayDate: date,
        startTime: '12:00',
        title: doc.name,
        detail: m['description'] as String?,
        tag: 'Activité',
        durationMinutes: 60,
      )];
  }
}

TripActivity _make({
  required String id,
  required String tripId,
  required DateTime dayDate,
  required String startTime,
  required String title,
  String? detail,
  required String tag,
  required int durationMinutes,
}) {
  return TripActivity(
    id: id,
    tripId: tripId,
    dayDate: dayDate,
    startTime: startTime,
    title: title,
    detail: detail,
    tag: tag,
    suggested: false,
    durationMinutes: durationMinutes,
  );
}

String? _flightDetail(Map<String, dynamic> m) {
  final parts = <String>[];
  if (m['departure_time'] != null && m['arrival_time'] != null) {
    parts.add('${m['departure_time']} → ${m['arrival_time']}');
  }
  if (m['seat'] != null) parts.add('siège ${m['seat']}');
  if (m['reservation_number'] != null) parts.add('résa ${m['reservation_number']}');
  return parts.isEmpty ? null : parts.join(' · ');
}

String? _trainDetail(Map<String, dynamic> m) {
  final parts = <String>[];
  if (m['departure_time'] != null && m['arrival_time'] != null) {
    parts.add('${m['departure_time']} → ${m['arrival_time']}');
  }
  if (m['car'] != null && m['seat'] != null) parts.add('voiture ${m['car']} · place ${m['seat']}');
  if (m['class'] != null) parts.add('${m['class']}');
  return parts.isEmpty ? null : parts.join(' · ');
}

// Si les deux heures sont fournies, calcule la durée en minutes (fallback null)
int? _computeDurationFromTimes(dynamic from, dynamic to) {
  if (from is! String || to is! String) return null;
  final fromParts = from.split(':');
  final toParts = to.split(':');
  if (fromParts.length != 2 || toParts.length != 2) return null;
  final fh = int.tryParse(fromParts[0]);
  final fm = int.tryParse(fromParts[1]);
  final th = int.tryParse(toParts[0]);
  final tm = int.tryParse(toParts[1]);
  if (fh == null || fm == null || th == null || tm == null) return null;
  final diff = (th * 60 + tm) - (fh * 60 + fm);
  // Si négatif (vol passant minuit), on ajoute 24h
  return diff < 0 ? diff + 24 * 60 : diff;
}
