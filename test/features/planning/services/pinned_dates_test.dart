/// Tests unitaires `pinned_dates.dart` (V2.1).
///
/// Couvre :
/// - `analyzePinnedDates` : dates calculées, détection start/end pinned,
///   collecte des hôtels par ville.
/// - `validateInsertionDate` : chaque contrainte rejetée en isolation +
///   chemin valide.
/// - `validInsertionStartDates` : énumération des dates valides en
///   présence des contraintes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/services/pinned_dates.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────

TripSegment _seg(String city, int days) => TripSegment(city: city, days: days);

TripDocument _flight({
  required String fromCity,
  required String toCity,
  required String date,
}) =>
    TripDocument(
      id: 'flight-$fromCity-$toCity-$date',
      userId: 'u1',
      tripId: 't1',
      category: DocumentCategory.flight,
      name: 'Vol $fromCity → $toCity',
      metadata: {
        'from_city': fromCity,
        'to_city': toCity,
        'date': date,
      },
      createdAt: DateTime(2026, 1, 1),
    );

TripDocument _train({
  required String fromCity,
  required String toCity,
  required String date,
}) =>
    TripDocument(
      id: 'train-$fromCity-$toCity-$date',
      userId: 'u1',
      tripId: 't1',
      category: DocumentCategory.train,
      name: 'Train $fromCity → $toCity',
      metadata: {
        'from_city': fromCity,
        'to_city': toCity,
        'date': date,
      },
      createdAt: DateTime(2026, 1, 1),
    );

TripDocument _hotel({
  required String city,
  required String checkIn,
  required String checkOut,
}) =>
    TripDocument(
      id: 'hotel-$city-$checkIn',
      userId: 'u1',
      tripId: 't1',
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

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

void main() {
  // Cas type V2 : Bangkok (11n) → Phú Quốc (5n) → Hanoï (3n).
  // Vol Lux→BKK le 21/06, vol BKK→PQC le 02/07, vol PQC→HAN le 07/07.
  final tripStart = _d(2026, 6, 21);

  group('analyzePinnedDates — dates et flags', () {
    test('calcule les ranges enchaînés à partir de tripStartDate', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Phú Quốc', 5), _seg('Hanoï', 3)],
        tripStartDate: tripStart,
        docs: const [],
      );

      expect(analysis.segments.length, 3);

      final bkk = analysis.segments[0];
      expect(bkk.city, 'Bangkok');
      expect(bkk.startDate, _d(2026, 6, 21));
      expect(bkk.endDateExclusive, _d(2026, 7, 2));
      expect(bkk.days, 11);

      final pqc = analysis.segments[1];
      expect(pqc.startDate, _d(2026, 7, 2));
      expect(pqc.endDateExclusive, _d(2026, 7, 7));

      final han = analysis.segments[2];
      expect(han.startDate, _d(2026, 7, 7));
      expect(han.endDateExclusive, _d(2026, 7, 10));
    });

    test('startPinned = true quand un vol arrive à la ville à startDate', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: [
          _flight(fromCity: 'Luxembourg', toCity: 'Bangkok', date: '2026-06-21'),
        ],
      );
      expect(analysis.segments.first.startPinned, isTrue);
      expect(analysis.segments.first.endPinned, isFalse);
    });

    test('endPinned = true quand un vol part de la ville à endDateExclusive',
        () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Phú Quốc', 5)],
        tripStartDate: tripStart,
        docs: [
          _flight(fromCity: 'Bangkok', toCity: 'Phú Quốc', date: '2026-07-02'),
        ],
      );
      // Le vol 02/07 ancre simultanément la fin de Bangkok et le début de PQC.
      expect(analysis.segments[0].endPinned, isTrue);
      expect(analysis.segments[0].startPinned, isFalse);
      expect(analysis.segments[1].startPinned, isTrue);
      expect(analysis.segments[1].endPinned, isFalse);
    });

    test('train compte comme transport pinned', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Chiang Mai', 4)],
        tripStartDate: tripStart,
        docs: [
          _train(fromCity: 'Bangkok', toCity: 'Chiang Mai', date: '2026-07-02'),
        ],
      );
      expect(analysis.segments[0].endPinned, isTrue);
      expect(analysis.segments[1].startPinned, isTrue);
    });

    test('vol à une date qui ne matche pas startDate/endDateExclusive '
        '→ ne pin rien', () {
      // Vol BKK→PQC daté le 03/07 alors que segment Bangkok finit le 02/07.
      // Cas suspect mais non pinné selon la règle stricte.
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: [
          _flight(fromCity: 'Bangkok', toCity: 'Phú Quốc', date: '2026-07-03'),
        ],
      );
      expect(analysis.segments.first.endPinned, isFalse);
    });

    test('hotelRanges collecte les hôtels rattachés à la ville', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: [
          _hotel(city: 'Bangkok', checkIn: '2026-06-21', checkOut: '2026-06-25'),
          _hotel(city: 'Bangkok', checkIn: '2026-06-28', checkOut: '2026-07-02'),
          _hotel(city: 'Phú Quốc', checkIn: '2026-07-02', checkOut: '2026-07-07'),
        ],
      );
      expect(analysis.segments.first.hotelRanges.length, 2);
      expect(analysis.segments.first.hotelRanges[0].checkIn, _d(2026, 6, 21));
      expect(
        analysis.segments.first.hotelRanges[0].checkOutExclusive,
        _d(2026, 6, 25),
      );
    });

    test('matching ville insensible aux accents/casse', () {
      // Segment "Hanoï", doc avec "hanoi".
      final analysis = analyzePinnedDates(
        segments: [_seg('Hanoï', 3)],
        tripStartDate: _d(2026, 7, 7),
        docs: [
          _flight(fromCity: 'Phú Quốc', toCity: 'hanoi', date: '2026-07-07'),
        ],
      );
      expect(analysis.segments.first.startPinned, isTrue);
    });

    test('forCity retourne le segment matchant (casse + accents simples)', () {
      // Note : le _normalize couvre les diacritiques latins courants
      // (à/é/î/ñ/ô/ü/ý etc.) mais PAS les marques tonales vietnamiennes
      // (ố, ợ, ằ…). Aligné sur sub_trip_conflict_detector.
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Hanoï', 3)],
        tripStartDate: tripStart,
        docs: const [],
      );
      expect(analysis.forCity('Bangkok')?.segmentIndex, 0);
      expect(analysis.forCity('BANGKOK')?.segmentIndex, 0);
      expect(analysis.forCity('hanoi')?.segmentIndex, 1);
      expect(analysis.forCity('Tokyo'), isNull);
    });
  });

  group('validateInsertionDate — contraintes', () {
    PinnedDatesAnalysis basicAnalysis({List<TripDocument> docs = const []}) {
      return analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Phú Quốc', 5)],
        tripStartDate: tripStart,
        docs: docs,
      );
    }

    test('chemin valide → null', () {
      final analysis = basicAnalysis();
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 26),
        insertionDays: 3,
        analysis: analysis,
      );
      expect(reason, isNull);
    });

    test('ancrage introuvable → message explicite', () {
      final reason = validateInsertionDate(
        anchorCity: 'Tokyo',
        insertionStartDate: _d(2026, 6, 26),
        insertionDays: 3,
        analysis: basicAnalysis(),
      );
      expect(reason, contains('Tokyo'));
    });

    test('insertionDays ≤ 0 → invalide', () {
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 26),
        insertionDays: 0,
        analysis: basicAnalysis(),
      );
      expect(reason, isNotNull);
    });

    test('contrainte 1 — date avant le début du segment → rejet', () {
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 20),
        insertionDays: 3,
        analysis: basicAnalysis(),
      );
      expect(reason, contains('avant le début'));
    });

    test('contrainte 2 — insertion dépasse la fin du segment → rejet', () {
      // Bangkok finit le 02/07 (excl). Insertion le 01/07 pour 3 nuits → fin
      // au 04/07 > 02/07.
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 7, 1),
        insertionDays: 3,
        analysis: basicAnalysis(),
      );
      expect(reason, contains('dépasse'));
    });

    test('startPinned + pre=0 → autorisé (Lalith 2026-05-08 : pas de '
        'nuit forcée avant l\'insertion)', () {
      final analysis = basicAnalysis(docs: [
        _flight(fromCity: 'Luxembourg', toCity: 'Bangkok', date: '2026-06-21'),
      ]);
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 21),
        insertionDays: 3,
        analysis: analysis,
      );
      expect(reason, isNull);
    });

    test('endPinned + post=0 → autorisé (insertion finit exactement au jour '
        'du départ pinné)', () {
      final analysis = basicAnalysis(docs: [
        _flight(fromCity: 'Bangkok', toCity: 'Phú Quốc', date: '2026-07-02'),
      ]);
      // pre=8 (29/06), insertionDays=3 → fin au 02/07, post=0.
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 29),
        insertionDays: 3,
        analysis: analysis,
      );
      expect(reason, isNull);
    });

    test('contrainte 5 — overlap avec hôtel à anchor → rejet', () {
      final analysis = basicAnalysis(docs: [
        _hotel(city: 'Bangkok', checkIn: '2026-06-24', checkOut: '2026-06-28'),
      ]);
      // Insertion 26/06 pour 3 nuits → [26,29). Hôtel [24,28). Overlap.
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 26),
        insertionDays: 3,
        analysis: analysis,
      );
      expect(reason, contains('hôtel'));
    });

    test('contrainte 5 — insertion qui touche le check-in d\'un hôtel '
        '(insertEnd == checkIn) → OK', () {
      final analysis = basicAnalysis(docs: [
        _hotel(city: 'Bangkok', checkIn: '2026-06-29', checkOut: '2026-07-02'),
      ]);
      // Insertion [26,29), hôtel [29,02). Pas d'overlap.
      final reason = validateInsertionDate(
        anchorCity: 'Bangkok',
        insertionStartDate: _d(2026, 6, 26),
        insertionDays: 3,
        analysis: analysis,
      );
      expect(reason, isNull);
    });
  });

  group('validInsertionStartDates', () {
    test('segment ancrage introuvable → liste vide', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: const [],
      );
      expect(
        validInsertionStartDates(
          anchorCity: 'Tokyo',
          insertionDays: 3,
          analysis: analysis,
        ),
        isEmpty,
      );
    });

    test('insertionDays > anchor.days → liste vide', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 3)],
        tripStartDate: tripStart,
        docs: const [],
      );
      expect(
        validInsertionStartDates(
          anchorCity: 'Bangkok',
          insertionDays: 4,
          analysis: analysis,
        ),
        isEmpty,
      );
    });

    test('sans ancres : énumère du 1er jour au dernier jour possible', () {
      // Bangkok 11n du 21/06 au 02/07 (excl). Insertion 3n → dernière date
      // possible = 02/07 - 3 = 29/06. → 9 dates : 21,22,...,29.
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: const [],
      );
      final dates = validInsertionStartDates(
        anchorCity: 'Bangkok',
        insertionDays: 3,
        analysis: analysis,
      );
      expect(dates.length, 9);
      expect(dates.first, _d(2026, 6, 21));
      expect(dates.last, _d(2026, 6, 29));
    });

    test('avec startPinned : 1er jour reste sélectionnable', () {
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: [
          _flight(fromCity: 'Luxembourg', toCity: 'Bangkok', date: '2026-06-21'),
        ],
      );
      final dates = validInsertionStartDates(
        anchorCity: 'Bangkok',
        insertionDays: 3,
        analysis: analysis,
      );
      expect(dates.first, _d(2026, 6, 21));
      expect(dates.contains(_d(2026, 6, 21)), isTrue);
    });

    test('avec endPinned : dernier jour possible reste sélectionnable', () {
      // Bangkok finit le 02/07 (excl). Insertion 3n → dernière start = 29/06
      // (insertion 29/06→02/07, post=0 autorisé).
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Phú Quốc', 5)],
        tripStartDate: tripStart,
        docs: [
          _flight(fromCity: 'Bangkok', toCity: 'Phú Quốc', date: '2026-07-02'),
        ],
      );
      final dates = validInsertionStartDates(
        anchorCity: 'Bangkok',
        insertionDays: 3,
        analysis: analysis,
      );
      expect(dates.last, _d(2026, 6, 29));
      expect(dates.contains(_d(2026, 6, 29)), isTrue);
      expect(dates.contains(_d(2026, 6, 30)), isFalse); // dépasserait 02/07
    });

    test('avec hôtel au milieu : exclut les dates qui chevauchent', () {
      // Hôtel Bangkok [25,28). Insertion 3n. Sont overlap si insertStart in
      // [23,27] (insertEnd ∈ [26,30) recoupe [25,28)). Donc 23,24,25,26,27
      // sont exclus.
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11)],
        tripStartDate: tripStart,
        docs: [
          _hotel(city: 'Bangkok', checkIn: '2026-06-25', checkOut: '2026-06-28'),
        ],
      );
      final dates = validInsertionStartDates(
        anchorCity: 'Bangkok',
        insertionDays: 3,
        analysis: analysis,
      );
      expect(dates.contains(_d(2026, 6, 22)), isTrue);
      expect(dates.contains(_d(2026, 6, 23)), isFalse);
      expect(dates.contains(_d(2026, 6, 24)), isFalse);
      expect(dates.contains(_d(2026, 6, 25)), isFalse);
      expect(dates.contains(_d(2026, 6, 26)), isFalse);
      expect(dates.contains(_d(2026, 6, 27)), isFalse);
      expect(dates.contains(_d(2026, 6, 28)), isTrue);
    });

    test('cas E2E V2 — Rayong+Koh Samet 3n dans Bangkok 11n (start+end pinned)',
        () {
      // Lalith 2026-05-08 — règle révisée : pas de nuits forcées à l'ancrage.
      // Bornes brutes du segment ancrage suffisent + filtre hôtel.
      final analysis = analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Phú Quốc', 5), _seg('Hanoï', 3)],
        tripStartDate: tripStart,
        docs: [
          _flight(fromCity: 'Luxembourg', toCity: 'Bangkok', date: '2026-06-21'),
          _flight(fromCity: 'Bangkok', toCity: 'Phú Quốc', date: '2026-07-02'),
          _flight(fromCity: 'Phú Quốc', toCity: 'Hanoï', date: '2026-07-07'),
        ],
      );
      final dates = validInsertionStartDates(
        anchorCity: 'Bangkok',
        insertionDays: 3,
        analysis: analysis,
      );
      // start ≥ 21/06 (anchor.startDate, même si startPinned).
      // start + 3 ≤ 02/07 (anchor.endDateExclusive) → start ≤ 29/06.
      // → 21, 22, 23, 24, 25, 26, 27, 28, 29 = 9 dates.
      expect(dates.length, 9);
      expect(dates.first, _d(2026, 6, 21));
      expect(dates.last, _d(2026, 6, 29));
    });
  });
}
