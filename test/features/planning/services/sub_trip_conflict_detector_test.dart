/// Tests unitaires `sub_trip_conflict_detector.dart` (Lot 2.2).
///
/// Couverture `preflightDatePrecise` : 3 modes (APPEND/SPLIT/REPLACE) ×
/// (avec/sans hôtel à l'anchor city) × overlap calendaire des nuits.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/planning/services/sub_trip_conflict_detector.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────

TripSegment _seg(String city, int days, {String? country}) =>
    TripSegment(city: city, days: days, country: country);

TripDocument _hotel({
  required String city,
  required String checkIn,
  required String checkOut,
  String? addressCity,
}) =>
    TripDocument(
      id: 'hotel-$city-$checkIn',
      userId: 'u1',
      tripId: 't1',
      category: DocumentCategory.hotel,
      name: 'Hôtel $city',
      metadata: {
        'address': '$city, Country',
        'address_city': ?addressCity,
        'check_in': checkIn,
        'check_out': checkOut,
      },
      createdAt: DateTime(2026, 1, 1),
    );

SubTripSuggestion _replace(String anchor, String city, int days) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: days)],
      insertionMode: InsertionMode.replaceAnchorGateway,
    );

SubTripSuggestion _split(String anchor, String city, int days, int minKeep) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: days)],
      insertionMode: InsertionMode.splitGatewaySequence,
      minAnchorDaysToKeep: minKeep,
    );

SubTripSuggestion _dayTrip(String anchor, String city) => SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: 1)],
      insertionMode: InsertionMode.dayTrip,
    );

void main() {
  // Voyage Vietnam : 2026-06-01 → 2026-06-10 (10 jours).
  final tripStart = DateTime.utc(2026, 6, 1);

  group('preflightDatePrecise — APPEND', () {
    test('dayTrip : aucune nuit retirée → ALLOW même avec hôtel à l\'anchor',
        () {
      final result = preflightDatePrecise(
        suggestion: _dayTrip('Bangkok', 'Ayutthaya'),
        currentSegments: [_seg('Bangkok', 4)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Bangkok',
            checkIn: '2026-06-01',
            checkOut: '2026-06-05',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });
  });

  group('preflightDatePrecise — REPLACE', () {
    test('Da Nang sans hôtel → ALLOW', () {
      final result = preflightDatePrecise(
        suggestion: _replace('Da Nang', 'Hội An', 3),
        currentSegments: [_seg('Da Nang', 3)],
        tripStartDate: tripStart,
        docs: [],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });

    test('Da Nang avec hôtel à Hội An (anchor sans hôtel) → ALLOW '
        '(le date-precise s\'occupe pas de la suggested city)', () {
      final result = preflightDatePrecise(
        suggestion: _replace('Da Nang', 'Hội An', 3),
        currentSegments: [_seg('Da Nang', 3)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Hội An',
            checkIn: '2026-06-01',
            checkOut: '2026-06-04',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });

    test('Hanoï avec hôtel à Hanoï qui couvre toutes les nuits → BLOCK', () {
      // Trip : Hanoï du 01/06 au 04/06 (3 nuits 01-02-03, checkout 04).
      final result = preflightDatePrecise(
        suggestion: _replace('Hanoï', 'Ninh Bình', 3),
        currentSegments: [_seg('Hanoï', 3)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Hanoï',
            checkIn: '2026-06-01',
            checkOut: '2026-06-04',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.block);
      expect(result.notice, contains('Hanoï'));
      expect(result.notice, contains('hôtel'));
    });

    test('Hanoï avec hôtel partiel (1 nuit) → BLOCK quand même', () {
      // Hôtel uniquement pour la nuit du 02. Mais REPLACE retire les 3
      // nuits 01,02,03 → conflit sur la nuit 02.
      final result = preflightDatePrecise(
        suggestion: _replace('Hanoï', 'Ninh Bình', 3),
        currentSegments: [_seg('Hanoï', 3)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Hanoï',
            checkIn: '2026-06-02',
            checkOut: '2026-06-03',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.block);
    });
  });

  group('preflightDatePrecise — SPLIT', () {
    test('Hanoï 4 + Ninh Bình 3 (minKeep 1) sans hôtel → ALLOW', () {
      final result = preflightDatePrecise(
        suggestion: _split('Hanoï', 'Ninh Bình', 3, 1),
        currentSegments: [_seg('Hanoï', 4)],
        tripStartDate: tripStart,
        docs: [],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });

    test('Hanoï 4 + hôtel pour les 3 premières nuits → BLOCK '
        '(les 3 premières nuits sont retirées par le SPLIT)', () {
      final result = preflightDatePrecise(
        suggestion: _split('Hanoï', 'Ninh Bình', 3, 1),
        currentSegments: [_seg('Hanoï', 4)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Hanoï',
            checkIn: '2026-06-01',
            checkOut: '2026-06-04', // 3 nuits 01,02,03
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.block);
    });

    test('Hanoï 4 + hôtel uniquement la 4e nuit → ALLOW '
        '(seule la 4e nuit reste à Hanoï après SPLIT, pas de conflit)', () {
      final result = preflightDatePrecise(
        suggestion: _split('Hanoï', 'Ninh Bình', 3, 1),
        currentSegments: [_seg('Hanoï', 4)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Hanoï',
            checkIn: '2026-06-04', // nuit 04
            checkOut: '2026-06-05',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });

    test('Hanoï 4 + hôtel 2 premières nuits → BLOCK '
        '(les 3 premières nuits sont retirées par SPLIT)', () {
      final result = preflightDatePrecise(
        suggestion: _split('Hanoï', 'Ninh Bình', 3, 1),
        currentSegments: [_seg('Hanoï', 4)],
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Hanoï',
            checkIn: '2026-06-02',
            checkOut: '2026-06-04', // nuits 02, 03
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.block);
    });
  });

  group('preflightDatePrecise — multi-segments', () {
    test('anchor au milieu : dates calculées via cumul', () {
      // Trip : Phú Quốc 2 (01-02) + Da Nang 3 (03-05) + Bangkok 2 (06-07)
      final segments = [
        _seg('Phú Quốc', 2),
        _seg('Da Nang', 3),
        _seg('Bangkok', 2),
      ];
      // Hôtel à Da Nang couvrant les 3 nuits du segment Da Nang.
      // REPLACE Da Nang par Hội An → BLOCK.
      final result = preflightDatePrecise(
        suggestion: _replace('Da Nang', 'Hội An', 3),
        currentSegments: segments,
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Da Nang',
            checkIn: '2026-06-03',
            checkOut: '2026-06-06',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.block);
    });

    test('hôtel à Da Nang pendant le segment Bangkok → ALLOW '
        '(cas improbable mais le check est strictement par dates)', () {
      // L'hôtel est tagué Da Nang mais sa résa tombe sur les nuits
      // 06-07 qui sont en réalité Bangkok dans le voyage. Pour
      // REPLACE Da Nang : on regarde uniquement les nuits du segment
      // Da Nang (03-05). Pas de conflit.
      final segments = [
        _seg('Phú Quốc', 2),
        _seg('Da Nang', 3),
        _seg('Bangkok', 2),
      ];
      final result = preflightDatePrecise(
        suggestion: _replace('Da Nang', 'Hội An', 3),
        currentSegments: segments,
        tripStartDate: tripStart,
        docs: [
          _hotel(
            city: 'Da Nang',
            checkIn: '2026-06-06',
            checkOut: '2026-06-08',
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });
  });

  group('preflightDatePrecise — anchor introuvable', () {
    test('anchor city absente des segments → ALLOW '
        '(computeMutation s\'occupe de l\'erreur)', () {
      final result = preflightDatePrecise(
        suggestion: _replace('Tokyo', 'Kyoto', 3),
        currentSegments: [_seg('Paris', 4), _seg('Lyon', 2)],
        tripStartDate: tripStart,
        docs: [],
      );
      expect(result.verdict, SuggestionVerdict.allow);
    });
  });

  group('preflightDatePrecise — match accent-insensible', () {
    test('hôtel "Hanoi" sans accent matche anchor "Hanoï"', () {
      final result = preflightDatePrecise(
        suggestion: _replace('Hanoï', 'Ninh Bình', 3),
        currentSegments: [_seg('Hanoï', 3)],
        tripStartDate: tripStart,
        docs: [
          TripDocument(
            id: 'h',
            userId: 'u1',
            tripId: 't1',
            category: DocumentCategory.hotel,
            name: 'Hôtel Hanoi',
            metadata: const {
              'address': 'Hanoi, Vietnam',
              'check_in': '2026-06-01',
              'check_out': '2026-06-04',
            },
            createdAt: DateTime(2026, 1, 1),
          ),
        ],
      );
      expect(result.verdict, SuggestionVerdict.block);
    });
  });

  group('hasReliableArrivalAnchor', () {
    TripDocument flightTo(String city, String? date) => TripDocument(
          id: 'flt-$city-${date ?? "nodate"}',
          userId: 'u1',
          tripId: 't1',
          category: DocumentCategory.flight,
          name: 'Vol $city',
          metadata: {
            'to_city': city,
            'date': ?date,
          },
          createdAt: DateTime(2026, 1, 1),
        );

    test('aucun doc → false', () {
      expect(hasReliableArrivalAnchor('Bangkok', const []), isFalse);
    });

    test('flight to Bangkok avec date → true', () {
      expect(
        hasReliableArrivalAnchor('Bangkok', [flightTo('Bangkok', '2026-06-21')]),
        isTrue,
      );
    });

    test('flight to Bangkok SANS date parseable → false', () {
      expect(
        hasReliableArrivalAnchor('Bangkok', [flightTo('Bangkok', null)]),
        isFalse,
      );
    });

    test('flight to autre ville → false (pas un anchor pour Bangkok)', () {
      expect(
        hasReliableArrivalAnchor('Bangkok', [flightTo('Phuket', '2026-06-21')]),
        isFalse,
      );
    });

    test('hôtel à Bangkok avec check_in → true (anchor indicatif)', () {
      expect(
        hasReliableArrivalAnchor('Bangkok', [
          _hotel(
            city: 'Bangkok',
            checkIn: '2026-06-21',
            checkOut: '2026-06-23',
          ),
        ]),
        isTrue,
      );
    });

    test('match accent-insensible : flight Hanoi vs anchor Hanoï', () {
      expect(
        hasReliableArrivalAnchor('Hanoï', [flightTo('Hanoi', '2026-06-21')]),
        isTrue,
      );
    });

    test('train aussi accepté comme anchor', () {
      final train = TripDocument(
        id: 'tr1',
        userId: 'u1',
        tripId: 't1',
        category: DocumentCategory.train,
        name: 'Train Hanoï',
        metadata: const {
          'to_city': 'Hanoi',
          'date': '2026-06-21',
        },
        createdAt: DateTime(2026, 1, 1),
      );
      expect(hasReliableArrivalAnchor('Hanoï', [train]), isTrue);
    });
  });
}
