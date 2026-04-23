import 'dart:developer' as developer;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Service singleton pour les notifications locales.
/// Initialisation à faire au démarrage via `NotificationService.instance.init()`.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'voyage_reminders';
  static const _channelName = 'Rappels Voyage';
  static const _channelDescription = 'Rappels d\'activités, vols, check-in…';

  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      final localName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localName));
    } catch (e) {
      developer.log('TZ fallback UTC : $e', name: 'notif');
    }

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  /// Demande les permissions utilisateur (Android 13+ et iOS).
  Future<bool> requestPermissions() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final androidOk = await android?.requestNotificationsPermission() ?? true;
    await android?.requestExactAlarmsPermission();
    final iosOk = await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? true;
    return androidOk && iosOk;
  }

  /// Programme un rappel à la date/heure indiquée (dans l'avenir, sinon no-op).
  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    await init();
    final scheduled = tz.TZDateTime.from(when, tz.local);
    if (scheduled.isBefore(tz.TZDateTime.now(tz.local))) return;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduled,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      developer.log('Notif planifiée id=$id le $scheduled : $title', name: 'notif');
    } catch (e) {
      developer.log('Erreur planification notif : $e', name: 'notif');
    }
  }

  /// Convertit un id UUID en int 32-bit (pour l'identifiant de notif).
  int _idFromString(String input) {
    return input.hashCode & 0x7FFFFFFF;
  }

  // ----- ACTIVITÉS -----

  Future<void> scheduleForActivity(TripActivity a) async {
    final when = _combineDateAndTime(a.dayDate, a.startTime);
    if (when == null) return;
    final reminderAt = when.subtract(const Duration(minutes: 15));
    await _schedule(
      id: _idFromString(a.id),
      title: '📍 ${a.title}',
      body: 'Commence dans 15 min${a.detail != null ? ' · ${a.detail}' : ''}',
      when: reminderAt,
    );
  }

  Future<void> cancelForActivity(String activityId) async {
    await init();
    await _plugin.cancel(_idFromString(activityId));
  }

  // ----- DOCUMENTS -----

  /// Programme les rappels pour un document selon sa catégorie.
  /// Peut générer plusieurs notifs (ex. check-in + check-out pour un hôtel).
  Future<void> scheduleForDocument(TripDocument doc) async {
    final m = doc.metadata;
    switch (doc.category) {
      case DocumentCategory.flight:
        final when = _combineDateAndTime(m['date'], m['departure_time']);
        if (when == null) return;
        // 2h avant
        await _schedule(
          id: _idFromString('${doc.id}:flight-2h'),
          title: '✈️ Vol dans 2h',
          body: doc.name,
          when: when.subtract(const Duration(hours: 2)),
        );
        // 30 min avant
        await _schedule(
          id: _idFromString('${doc.id}:flight-30m'),
          title: '✈️ Embarquement imminent',
          body: '${doc.name} décolle dans 30 min',
          when: when.subtract(const Duration(minutes: 30)),
        );
        return;

      case DocumentCategory.train:
        final when = _combineDateAndTime(m['date'], m['departure_time']);
        if (when == null) return;
        await _schedule(
          id: _idFromString('${doc.id}:train-30m'),
          title: '🚆 Train dans 30 min',
          body: doc.name,
          when: when.subtract(const Duration(minutes: 30)),
        );
        return;

      case DocumentCategory.hotel:
        final checkIn = _combineDateAndTime(m['check_in'], '15:00');
        if (checkIn != null) {
          await _schedule(
            id: _idFromString('${doc.id}:checkin'),
            title: '🏨 Check-in aujourd\'hui',
            body: doc.name,
            when: checkIn.subtract(const Duration(hours: 1)),
          );
        }
        final checkOut = _combineDateAndTime(m['check_out'], '11:00');
        if (checkOut != null) {
          await _schedule(
            id: _idFromString('${doc.id}:checkout'),
            title: '🏨 Check-out dans 1h',
            body: doc.name,
            when: checkOut.subtract(const Duration(hours: 1)),
          );
        }
        return;

      case DocumentCategory.carRental:
        final pickup = _combineDateAndTime(m['pickup_date'], m['pickup_time']);
        if (pickup != null) {
          await _schedule(
            id: _idFromString('${doc.id}:pickup'),
            title: '🚗 Prise en charge dans 30 min',
            body: doc.name,
            when: pickup.subtract(const Duration(minutes: 30)),
          );
        }
        return;

      case DocumentCategory.ticket:
        final when = _combineDateAndTime(m['date'], m['time']);
        if (when == null) return;
        await _schedule(
          id: _idFromString('${doc.id}:ticket'),
          title: '🎫 ${doc.name}',
          body: 'Dans 30 min',
          when: when.subtract(const Duration(minutes: 30)),
        );
        return;

      default:
        return;
    }
  }

  Future<void> cancelForDocument(String docId) async {
    await init();
    // Annule toutes les variantes potentielles
    for (final suffix in ['flight-2h', 'flight-30m', 'train-30m', 'checkin', 'checkout', 'pickup', 'ticket']) {
      await _plugin.cancel(_idFromString('$docId:$suffix'));
    }
  }

  /// Annule toutes les notifications planifiées.
  Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }

  /// Reprogramme toutes les notifications pour un voyage (utile au démarrage).
  Future<void> rescheduleForTrip({
    required List<TripActivity> activities,
    required List<TripDocument> documents,
  }) async {
    for (final a in activities) {
      await scheduleForActivity(a);
    }
    for (final d in documents) {
      await scheduleForDocument(d);
    }
  }

  DateTime? _combineDateAndTime(dynamic date, dynamic time) {
    if (date == null) return null;
    DateTime? day;
    if (date is DateTime) {
      day = date;
    } else if (date is String) {
      day = DateTime.tryParse(date);
    }
    if (day == null) return null;

    int h = 12, m = 0;
    if (time is String && time.contains(':')) {
      final parts = time.split(':');
      h = int.tryParse(parts[0]) ?? 12;
      m = int.tryParse(parts[1]) ?? 0;
    }
    return DateTime(day.year, day.month, day.day, h, m);
  }
}
