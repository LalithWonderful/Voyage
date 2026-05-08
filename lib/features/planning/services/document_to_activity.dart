import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';

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
      // Coordonnées géocodées au save du doc (cf. _DocumentFormSheet._geocodeHotelAddress).
      // Permettent au pipeline de calculer les trajets hôtel ↔ activité sans
      // passer par un Places lookup (qui échoue souvent sur le titre "🏨 Arrivée · Hôtel X").
      final hotelLat = (m['latitude'] as num?)?.toDouble();
      final hotelLng = (m['longitude'] as num?)?.toDouble();
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
          latitude: hotelLat,
          longitude: hotelLng,
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
          latitude: hotelLat,
          longitude: hotelLng,
        ));
      }
      return result;

    case DocumentCategory.flight:
      return _splitTransport(
        doc: doc,
        tripId: tripId,
        emoji: '✈️',
        legacyPrefix: 'Vol',
        legacyKey: 'flight',
        carrierKey: 'airline',
        numberKey: 'flight_number',
        fallbackDuration: 180,
        m: m,
        parseDate: parseDate,
        parseTime: parseTime,
        legacyDetailBuilder: _flightDetail,
      );

    case DocumentCategory.train:
      return _splitTransport(
        doc: doc,
        tripId: tripId,
        emoji: '🚆',
        legacyPrefix: 'Train',
        legacyKey: 'train',
        carrierKey: 'company',
        numberKey: 'train_number',
        fallbackDuration: 120,
        m: m,
        parseDate: parseDate,
        parseTime: parseTime,
        legacyDetailBuilder: _trainDetail,
      );

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
          kind: ActivityKind.logistic,
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
          kind: ActivityKind.logistic,
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
  ActivityKind kind = ActivityKind.main,
  required int durationMinutes,
  double? latitude,
  double? longitude,
}) {
  return TripActivity(
    id: id,
    tripId: tripId,
    dayDate: dayDate,
    startTime: startTime,
    title: title,
    detail: detail,
    tag: tag,
    kind: kind,
    suggested: false,
    durationMinutes: durationMinutes,
    latitude: latitude,
    longitude: longitude,
  );
}

/// Génère 1 ou 2 activités virtuelles à partir d'un doc Vol ou Train, selon
/// les endpoints renseignés :
///
/// - `from` ET `to` connus → 2 activités logistic : `:departure` (au point
///   de départ, au `departure_time`, lat/lng = endpoint origine) + `:arrival`
///   (au point d'arrivée, au `arrival_time`, lat/lng = endpoint destination).
///   Si `arrival_time` < `departure_time`, on suppose un trajet de nuit
///   et l'arrivée est posée à J+1 (approximation tant qu'on n'a pas un
///   champ `arrival_date` séparé).
/// - Un seul endpoint → 1 activité (le côté connu uniquement).
/// - Aucun endpoint → 1 activité legacy (titre simple, format avant split).
///
/// Toutes les activités sont `tag: 'Transport'`, `kind: logistic`. Les
/// coords lat/lng viennent de `from_latitude/from_longitude` et
/// `to_latitude/to_longitude` posés par le form au save (cf. Phase 2).
List<TripActivity> _splitTransport({
  required TripDocument doc,
  required String tripId,
  required String emoji,
  required String legacyPrefix,
  required String legacyKey,
  required String carrierKey,
  required String numberKey,
  required int fallbackDuration,
  required Map<String, dynamic> m,
  required DateTime? Function(dynamic) parseDate,
  required String Function(dynamic, String) parseTime,
  required String? Function(Map<String, dynamic>) legacyDetailBuilder,
}) {
  final date = parseDate(m['date']);
  if (date == null) return const [];

  final docId = doc.id;
  final docName = doc.name;

  final from = (m['from'] as String?)?.trim();
  final to = (m['to'] as String?)?.trim();
  final hasFrom = from != null && from.isNotEmpty;
  final hasTo = to != null && to.isNotEmpty;

  // Aucun endpoint → fallback legacy 1 activité (cas import vide ou
  // saisie incomplète sans même les villes).
  if (!hasFrom && !hasTo) {
    final parts = <String>[];
    if (m[carrierKey] != null) parts.add(m[carrierKey] as String);
    if (m[numberKey] != null) parts.add(m[numberKey] as String);
    final title = parts.isEmpty ? docName : '$legacyPrefix ${parts.join(' ')}';
    return [_make(
      id: '$virtualActivityPrefix$docId:$legacyKey',
      tripId: tripId,
      dayDate: date,
      startTime: parseTime(m['departure_time'], '00:00'),
      title: title,
      detail: legacyDetailBuilder(m),
      tag: 'Transport',
      kind: ActivityKind.logistic,
      durationMinutes: _computeDurationFromTimes(m['departure_time'], m['arrival_time']) ?? fallbackDuration,
    )];
  }

  // Construit le label "Vol TG 122" / "Train SNCF 6512" / "Vol" si rien.
  final carrier = (m[carrierKey] as String?)?.trim();
  final number = (m[numberKey] as String?)?.trim();
  final labelParts = <String>[];
  if (carrier != null && carrier.isNotEmpty) labelParts.add(carrier);
  if (number != null && number.isNotEmpty) labelParts.add(number);
  final transportLabel = labelParts.isEmpty ? legacyPrefix : '$legacyPrefix ${labelParts.join(' ')}';

  final fromLat = (m['from_latitude'] as num?)?.toDouble();
  final fromLng = (m['from_longitude'] as num?)?.toDouble();
  final toLat = (m['to_latitude'] as num?)?.toDouble();
  final toLng = (m['to_longitude'] as num?)?.toDouble();

  final result = <TripActivity>[];

  if (hasFrom) {
    final detailParts = <String>[];
    if (hasTo) {
      detailParts.add('$transportLabel pour $to');
    } else {
      detailParts.add(transportLabel);
    }
    if (m['seat'] != null) detailParts.add('siège ${m['seat']}');
    if (m['car'] != null && m['seat'] != null) {
      detailParts
        ..removeWhere((p) => p.startsWith('siège'))
        ..add('voiture ${m['car']} · place ${m['seat']}');
    }
    if (m['class'] != null) detailParts.add('${m['class']}');
    if (m['reservation_number'] != null) detailParts.add('résa ${m['reservation_number']}');
    result.add(_make(
      id: '$virtualActivityPrefix$docId:departure',
      tripId: tripId,
      dayDate: date,
      startTime: parseTime(m['departure_time'], '00:00'),
      title: '$emoji Départ · $from',
      detail: detailParts.join(' · '),
      tag: 'Transport',
      kind: ActivityKind.logistic,
      durationMinutes: 0,
      latitude: fromLat,
      longitude: fromLng,
    ));
  }

  if (hasTo) {
    // Date d'arrivée résolue via le helper partagé `transport_dates`
    // (V2.3 refactor 2026-05-08) : préfère `arrival_date` explicite si
    // présent, sinon infère J+1 quand `arrival_time < departure_time`
    // (overnight). Source de vérité unique partagée avec
    // `pinned_dates.dart` et `flight_timeline_builder.dart`.
    final arrivalDate = arrivalDateFromMetadata(m) ?? date;
    final detailParts = <String>[];
    if (hasFrom) {
      detailParts.add('$transportLabel depuis $from');
    } else {
      detailParts.add(transportLabel);
    }
    result.add(_make(
      id: '$virtualActivityPrefix$docId:arrival',
      tripId: tripId,
      dayDate: arrivalDate,
      startTime: parseTime(m['arrival_time'], '00:00'),
      title: '$emoji Arrivée · $to',
      detail: detailParts.join(' · '),
      tag: 'Transport',
      kind: ActivityKind.logistic,
      durationMinutes: 0,
      latitude: toLat,
      longitude: toLng,
    ));
  }

  return result;
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
