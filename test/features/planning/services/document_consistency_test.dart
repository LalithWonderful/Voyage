/// Tests unitaires `document_consistency.dart` (Phase B).
///
/// Couvre les 3 types de conflit :
/// 1. `overlappingTransports` — 2 vols/trains qui se chevauchent.
/// 2. `hotelDuringAbsence` — hôtel qui couvre des nuits où l'utilisateur
///    est ailleurs selon les transports.
/// 3. `segmentArrivalMismatch` — segment.startDate ≠ effectiveStartDate.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/services/document_consistency.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

TripSegment _seg(String city, int days, {String? country}) =>
    TripSegment(city: city, days: days, country: country);

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

TripDocument _flight({
  required String id,
  required String fromCity,
  required String toCity,
  required String date,
  String? arrivalDate,
}) =>
    TripDocument(
      id: id,
      userId: 'u',
      tripId: 't',
      category: DocumentCategory.flight,
      name: 'Vol $fromCity → $toCity',
      metadata: {
        'from_city': fromCity,
        'to_city': toCity,
        'date': date,
        'arrival_date': ?arrivalDate,
      },
      createdAt: DateTime(2026, 1, 1),
    );

TripDocument _hotel({
  required String id,
  required String city,
  required String checkIn,
  required String checkOut,
}) =>
    TripDocument(
      id: id,
      userId: 'u',
      tripId: 't',
      category: DocumentCategory.hotel,
      name: 'Hôtel $city',
      metadata: {
        'address_city': city,
        'address': '$city, Country',
        'check_in': checkIn,
        'check_out': checkOut,
      },
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  group('detectDocumentConflicts — overlappingTransports', () {
    test('2 vols même jour → conflit', () {
      // Cas typique : import en double ou erreur de saisie.
      final docs = [
        _flight(
          id: 'f1',
          fromCity: 'Paris',
          toCity: 'Bangkok',
          date: '2026-06-21',
        ),
        _flight(
          id: 'f2',
          fromCity: 'Lyon',
          toCity: 'Tokyo',
          date: '2026-06-21',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 21),
      );
      final overlap = conflicts
          .where((c) => c.type == ConflictType.overlappingTransports)
          .toList();
      expect(overlap.length, 1);
      expect(overlap.first.docIds, containsAll(['f1', 'f2']));
      expect(overlap.first.message, contains('21/06/2026'));
    });

    test('vol overnight chevauche un autre vol le lendemain → conflit', () {
      // Vol A : Lux→BKK décolle 21/06 23:30, atterrit 22/06 12:15
      // (arrival_date = 22/06).
      // Vol B : Paris→Tokyo décolle 22/06.
      // Intervalle A = [21/06, 22/06], B = [22/06, 22/06] → chevauche.
      final docs = [
        _flight(
          id: 'a',
          fromCity: 'Luxembourg',
          toCity: 'Bangkok',
          date: '2026-06-21',
          arrivalDate: '2026-06-22',
        ),
        _flight(
          id: 'b',
          fromCity: 'Paris',
          toCity: 'Tokyo',
          date: '2026-06-22',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 21),
      );
      expect(
        conflicts
            .where((c) => c.type == ConflictType.overlappingTransports)
            .length,
        1,
      );
    });

    test('2 vols à dates non overlappantes → pas de conflit', () {
      final docs = [
        _flight(
          id: 'f1',
          fromCity: 'Paris',
          toCity: 'Bangkok',
          date: '2026-06-21',
        ),
        _flight(
          id: 'f2',
          fromCity: 'Bangkok',
          toCity: 'Phú Quốc',
          date: '2026-07-02',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 21),
      );
      expect(
        conflicts
            .where((c) => c.type == ConflictType.overlappingTransports)
            .toList(),
        isEmpty,
      );
    });

    test('1 transport seul → pas de conflit', () {
      final docs = [
        _flight(
          id: 'f1',
          fromCity: 'Paris',
          toCity: 'Bangkok',
          date: '2026-06-21',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 21),
      );
      expect(conflicts, isEmpty);
    });

    test('docs sans date → ignorés', () {
      final docs = [
        _flight(
          id: 'f1',
          fromCity: 'Paris',
          toCity: 'Bangkok',
          date: 'invalid-date',
        ),
        _flight(
          id: 'f2',
          fromCity: 'Lyon',
          toCity: 'Tokyo',
          date: '2026-06-21',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 21),
      );
      expect(conflicts, isEmpty);
    });
  });

  group('detectDocumentConflicts — hotelDuringAbsence', () {
    test('hôtel qui couvre des nuits pendant un voyage hors de la ville → '
        'conflit', () {
      // Cas typique : appart Bangkok 22/06→06/08 + voyage Phú Quốc
      // 02/07→07/07. Les nuits 02-06 sont "phantom" (utilisateur à PQC).
      final docs = [
        _hotel(
          id: 'h1',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _flight(
          id: 'arrival',
          fromCity: 'Luxembourg',
          toCity: 'Bangkok',
          date: '2026-06-22',
        ),
        _flight(
          id: 'go',
          fromCity: 'Bangkok',
          toCity: 'Phú Quốc',
          date: '2026-07-02',
        ),
        _flight(
          id: 'back',
          fromCity: 'Phú Quốc',
          toCity: 'Bangkok',
          date: '2026-07-07',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 22),
      );
      final phantom = conflicts
          .where((c) => c.type == ConflictType.hotelDuringAbsence)
          .toList();
      expect(phantom.length, 1);
      expect(phantom.first.docIds, contains('h1'));
      expect(phantom.first.message, contains('Bangkok'));
    });

    test('hôtel court qui colle exactement à la période sur place → '
        'pas de conflit', () {
      // Hôtel Phú Quốc 02/07→07/07 + transports cohérents.
      final docs = [
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
        _flight(
          id: 'arrival',
          fromCity: 'Bangkok',
          toCity: 'Phú Quốc',
          date: '2026-07-02',
        ),
        _flight(
          id: 'depart',
          fromCity: 'Phú Quốc',
          toCity: 'Hanoï',
          date: '2026-07-07',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 7, 2),
      );
      expect(
        conflicts
            .where((c) => c.type == ConflictType.hotelDuringAbsence)
            .toList(),
        isEmpty,
      );
    });

    test('hôtel sans aucun transport → ignoré (pas de signal)', () {
      final docs = [
        _hotel(
          id: 'h1',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-06-25',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 22),
      );
      expect(conflicts, isEmpty);
    });

    test('hôtel sans address_city → ignoré', () {
      final hotelNoCity = TripDocument(
        id: 'h1',
        userId: 'u',
        tripId: 't',
        category: DocumentCategory.hotel,
        name: 'Hôtel mystère',
        metadata: const {
          'check_in': '2026-06-22',
          'check_out': '2026-06-25',
        },
        createdAt: DateTime(2026, 1, 1),
      );
      final docs = [
        hotelNoCity,
        _flight(
          id: 'f1',
          fromCity: 'Paris',
          toCity: 'Tokyo',
          date: '2026-06-22',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 22),
      );
      // Pas de hotelDuringAbsence (city manquante).
      expect(
        conflicts
            .where((c) => c.type == ConflictType.hotelDuringAbsence)
            .toList(),
        isEmpty,
      );
    });
  });

  group('detectDocumentConflicts — segmentArrivalMismatch', () {
    test('segment 21/06 mais arrival_date 22/06 → conflit', () {
      // Trip Bangkok 21/06 (cumulatif) mais le vol arrive 22/06.
      // effectiveStartDate Bangkok = 22/06 ≠ startDate 21/06.
      final segments = [_seg('Bangkok', 11)];
      final docs = [
        _flight(
          id: 'arrival',
          fromCity: 'Luxembourg',
          toCity: 'Bangkok',
          date: '2026-06-21',
          arrivalDate: '2026-06-22',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: segments,
        tripStartDate: _d(2026, 6, 21),
      );
      final mismatch = conflicts
          .where((c) => c.type == ConflictType.segmentArrivalMismatch)
          .toList();
      expect(mismatch.length, 1);
      expect(mismatch.first.segmentIndex, 0);
      expect(mismatch.first.message, contains('Bangkok'));
      expect(mismatch.first.message, contains('21/06/2026'));
      expect(mismatch.first.message, contains('22/06/2026'));
    });

    test('segment qui colle au transport → pas de conflit', () {
      final segments = [_seg('Bangkok', 11)];
      final docs = [
        _flight(
          id: 'arrival',
          fromCity: 'Luxembourg',
          toCity: 'Bangkok',
          date: '2026-06-21',
          // pas d'arrival_date → assume same-day (effectiveStartDate = startDate)
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: segments,
        tripStartDate: _d(2026, 6, 21),
      );
      expect(
        conflicts
            .where((c) => c.type == ConflictType.segmentArrivalMismatch)
            .toList(),
        isEmpty,
      );
    });

    test('segments sans aucun transport → pas de conflit', () {
      final segments = [_seg('Paris', 5)];
      final conflicts = detectDocumentConflicts(
        docs: const [],
        segments: segments,
        tripStartDate: _d(2026, 6, 21),
      );
      expect(conflicts, isEmpty);
    });
  });

  group('detectDocumentConflicts — combinaisons', () {
    test('voyage cohérent multi-villes → 0 conflit', () {
      final segments = [
        _seg('Bangkok', 11),
        _seg('Phú Quốc', 5),
        _seg('Hanoï', 3),
      ];
      final docs = [
        _flight(
          id: 'a',
          fromCity: 'Luxembourg',
          toCity: 'Bangkok',
          date: '2026-06-21',
        ),
        _flight(
          id: 'b',
          fromCity: 'Bangkok',
          toCity: 'Phú Quốc',
          date: '2026-07-02',
        ),
        _flight(
          id: 'c',
          fromCity: 'Phú Quốc',
          toCity: 'Hanoï',
          date: '2026-07-07',
        ),
        _hotel(
          id: 'h-bkk',
          city: 'Bangkok',
          checkIn: '2026-06-21',
          checkOut: '2026-07-02',
        ),
        _hotel(
          id: 'h-pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
        _hotel(
          id: 'h-han',
          city: 'Hanoï',
          checkIn: '2026-07-07',
          checkOut: '2026-07-10',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: segments,
        tripStartDate: _d(2026, 6, 21),
      );
      expect(conflicts, isEmpty);
    });

    test('voyage avec base longue durée + side-trip → 1 hotelDuringAbsence',
        () {
      // Le pattern qu'Option D du wallet résout silencieusement, mais
      // la consistency check le SIGNALE quand même comme "à vérifier"
      // (l'utilisateur peut confirmer que c'est volontaire = appart base).
      final docs = [
        _hotel(
          id: 'base',
          city: 'Bangkok',
          checkIn: '2026-06-22',
          checkOut: '2026-08-06',
        ),
        _flight(
          id: 'arr',
          fromCity: 'Luxembourg',
          toCity: 'Bangkok',
          date: '2026-06-22',
        ),
        _flight(
          id: 'go',
          fromCity: 'Bangkok',
          toCity: 'Phú Quốc',
          date: '2026-07-02',
        ),
        _flight(
          id: 'back',
          fromCity: 'Phú Quốc',
          toCity: 'Bangkok',
          date: '2026-07-07',
        ),
        _hotel(
          id: 'pqc',
          city: 'Phú Quốc',
          checkIn: '2026-07-02',
          checkOut: '2026-07-07',
        ),
      ];
      final conflicts = detectDocumentConflicts(
        docs: docs,
        segments: const [],
        tripStartDate: _d(2026, 6, 22),
      );
      // L'appart Bangkok est flaggé pour les nuits 02→06/07.
      final phantom = conflicts
          .where((c) =>
              c.type == ConflictType.hotelDuringAbsence &&
              c.docIds.contains('base'))
          .toList();
      expect(phantom.length, 1);
    });
  });
}
