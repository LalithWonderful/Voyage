/// Tests unitaires `autoPlacePreservedSegments` (V5.4 2026-05-10).
///
/// Couvre les règles d'auto-placement des étapes préservées par dates
/// d'origine quand `applyTimelineDiff` reconstruit le squelette
/// doc-derived. Acceptance criteria de la spec produit Lalith :
///  1. Les étapes mises de côté conservent startDate/endDateExclusive.
///  2-5. Replacement aux dates d'origine si le squelette les couvre.
///  6. Conflit de dates → reste dans leftovers.
///  7. Le bandeau ne montre que les non replacées.
///  8-10. Squelette doc-derived intact, durée totale ok, pas de 0-jour.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/preserved_segments.dart';

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

PreservedSegmentInfo _p({
  required String city,
  required int days,
  required DateTime startDate,
  String? anchor,
  int originalIndex = 0,
}) =>
    PreservedSegmentInfo(
      city: city,
      days: days,
      startDate: startDate,
      endDateExclusive: startDate.add(Duration(days: days)),
      originalIndex: originalIndex,
      source: anchor != null
          ? PreservedSegmentSource.windowLinked
          : PreservedSegmentSource.manual,
      sourceAnchorCity: anchor,
    );

void main() {
  group('autoPlacePreservedSegments — replacement par dates d\'origine',
      () {
    test('AC2 — Tokyo manuel 16/07-21/07 dans Bangkok 15/07-06/08 → '
        'replacé automatiquement, Bangkok splitté autour', () {
      // Squelette doc-derived = Bangkok 22 jours (15/07-06/08)
      final skeleton = [
        const TripSegment(city: 'Bangkok', days: 22),
      ];
      final tripStart = _d(2026, 7, 15);
      final preserved = [
        _p(city: 'Tokyo', days: 5, startDate: _d(2026, 7, 16)),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Bangkok(1) + Tokyo(5) + Bangkok(16) = 22 jours
      expect(result.placed.map((s) => s.city).toList(),
          ['Bangkok', 'Tokyo', 'Bangkok']);
      expect(result.placed.map((s) => s.days).toList(), [1, 5, 16]);
      expect(result.placed.fold<int>(0, (a, s) => a + s.days), 22);
      expect(result.leftovers, isEmpty);
    });

    test('AC3 — Rayong + Koh Samet manuel dans Bangkok 22/06-03/07 → '
        'tous les deux replacés, total préservé', () {
      // Squelette = Bangkok(11) Phú Quốc(5) Hanoï(4) Da Nang(3) Bangkok(22) = 45j
      final skeleton = [
        const TripSegment(city: 'Bangkok', days: 11),
        const TripSegment(city: 'Phú Quốc', days: 5),
        const TripSegment(city: 'Hanoï', days: 4),
        const TripSegment(city: 'Da Nang', days: 3),
        const TripSegment(city: 'Bangkok', days: 22),
      ];
      final tripStart = _d(2026, 6, 22);
      final preserved = [
        _p(city: 'Rayong', days: 1, startDate: _d(2026, 6, 29),
            anchor: 'Bangkok'),
        _p(city: 'Koh Samet', days: 2, startDate: _d(2026, 6, 30),
            anchor: 'Bangkok'),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Attendu : Bangkok(7) Rayong(1) Koh Samet(2) Bangkok(1) Phú Quốc(5)…
      expect(result.placed.map((s) => s.city).toList(),
          ['Bangkok', 'Rayong', 'Koh Samet', 'Bangkok',
           'Phú Quốc', 'Hanoï', 'Da Nang', 'Bangkok']);
      expect(result.placed.map((s) => s.days).toList(),
          [7, 1, 2, 1, 5, 4, 3, 22]);
      expect(result.placed.fold<int>(0, (a, s) => a + s.days), 45);
      expect(result.leftovers, isEmpty);
    });

    test('AC4 — Ninh Bình window-linked Hanoï dans Hanoï 08/07-12/07 → '
        'replacée, Hanoï resté en buffer 1 jour', () {
      final skeleton = [
        const TripSegment(city: 'Hanoï', days: 4),
      ];
      final tripStart = _d(2026, 7, 8);
      final preserved = [
        _p(city: 'Ninh Bình', days: 3, startDate: _d(2026, 7, 8),
            anchor: 'Hanoï'),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Ninh Bình prend les 3 premiers jours, Hanoï garde 1 jour à la fin
      expect(result.placed.map((s) => s.city).toList(),
          ['Ninh Bình', 'Hanoï']);
      expect(result.placed.map((s) => s.days).toList(), [3, 1]);
      expect(result.leftovers, isEmpty);
    });

    test('AC5 — Hội An window-linked Da Nang remplit Da Nang 12/07-15/07 '
        '→ Da Nang gateway disparaît, Hội An prend la fenêtre, '
        'PAS de segment 0-jour', () {
      final skeleton = [
        const TripSegment(city: 'Da Nang', days: 3),
      ];
      final tripStart = _d(2026, 7, 12);
      final preserved = [
        _p(city: 'Hội An', days: 3, startDate: _d(2026, 7, 12),
            anchor: 'Da Nang'),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Hội An prend toute la fenêtre. Da Nang n'apparaît plus comme
      // segment de séjour, mais Hội An.sourceAnchorCity = Da Nang
      // permet à Lot B (`document_consistency`) de couvrir les vols
      // Da Nang via la fenêtre Hội An.
      expect(result.placed.map((s) => s.city).toList(), ['Hội An']);
      expect(result.placed.first.days, 3);
      expect(result.placed.first.sourceAnchorCity, 'Da Nang');
      expect(result.leftovers, isEmpty);
    });
  });

  group('autoPlacePreservedSegments — leftovers (cas non auto-replaçables)',
      () {
    test('AC6 — étape qui chevauche 2 segments du squelette → leftover',
        () {
      final skeleton = [
        const TripSegment(city: 'Bangkok', days: 5),
        const TripSegment(city: 'Phú Quốc', days: 5),
      ];
      final tripStart = _d(2026, 7, 1);
      // Étape qui démarre dans Bangkok (4 juillet) mais s'étire 4 jours
      // → tombe sur le 7 juillet qui est déjà Phú Quốc → conflit.
      final preserved = [
        _p(city: 'Tokyo', days: 4, startDate: _d(2026, 7, 4)),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Squelette inchangé, Tokyo en leftover.
      expect(result.placed.map((s) => s.city).toList(),
          ['Bangkok', 'Phú Quốc']);
      expect(result.placed.map((s) => s.days).toList(), [5, 5]);
      expect(result.leftovers.length, 1);
      expect(result.leftovers.first.city, 'Tokyo');
    });

    test('étape avec dates hors voyage → leftover', () {
      final skeleton = [const TripSegment(city: 'Bangkok', days: 5)];
      final tripStart = _d(2026, 7, 1);
      final preserved = [
        _p(city: 'Tokyo', days: 2, startDate: _d(2026, 8, 1)),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      expect(result.placed.map((s) => s.city), ['Bangkok']);
      expect(result.leftovers.length, 1);
    });

    test('2 préservées sur les MÊMES jours → la 1ère gagne, la 2ᵉ '
        'leftover', () {
      final skeleton = [const TripSegment(city: 'Bangkok', days: 10)];
      final tripStart = _d(2026, 7, 1);
      final preserved = [
        _p(city: 'Tokyo', days: 3, startDate: _d(2026, 7, 3)),
        _p(city: 'Kyoto', days: 3, startDate: _d(2026, 7, 3)),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Tri par date asc → Tokyo placé en 1er, Kyoto en conflit → leftover.
      expect(result.placed.any((s) => s.city == 'Tokyo'), isTrue);
      expect(result.placed.any((s) => s.city == 'Kyoto'), isFalse);
      expect(result.leftovers.map((p) => p.city), ['Kyoto']);
    });
  });

  group('autoPlacePreservedSegments — invariants (hard rules)', () {
    test('AC8/9/10 — la durée totale est strictement préservée et '
        'aucun segment 0-jour n\'est créé, même avec multiples '
        'replacements', () {
      final skeleton = [
        const TripSegment(city: 'Bangkok', days: 11),
        const TripSegment(city: 'Phú Quốc', days: 5),
        const TripSegment(city: 'Hanoï', days: 4),
        const TripSegment(city: 'Da Nang', days: 3),
        const TripSegment(city: 'Bangkok', days: 22),
      ];
      final tripStart = _d(2026, 6, 22);
      final preserved = [
        _p(city: 'Rayong', days: 1, startDate: _d(2026, 6, 29),
            anchor: 'Bangkok'),
        _p(city: 'Koh Samet', days: 2, startDate: _d(2026, 6, 30),
            anchor: 'Bangkok'),
        _p(city: 'Ninh Bình', days: 3, startDate: _d(2026, 7, 8),
            anchor: 'Hanoï'),
        _p(city: 'Hội An', days: 3, startDate: _d(2026, 7, 12),
            anchor: 'Da Nang'),
        _p(city: 'Tokyo', days: 5, startDate: _d(2026, 7, 16)),
        _p(city: 'Kyoto', days: 3, startDate: _d(2026, 7, 23)),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      // Total préservé strictement
      expect(result.placed.fold<int>(0, (a, s) => a + s.days), 45);
      // Aucun segment 0-jour
      expect(result.placed.every((s) => s.days >= 1), isTrue);
      // Toutes les étapes auto-replaçables sont dans le squelette
      final placedCities = result.placed.map((s) => s.city).toSet();
      expect(placedCities, containsAll(
          ['Rayong', 'Koh Samet', 'Ninh Bình', 'Hội An', 'Tokyo', 'Kyoto']));
      // Pas de leftover (tout a été replacé aux dates d'origine)
      expect(result.leftovers, isEmpty);
    });

    test('le squelette est strictement préservé quand AUCUN preserved '
        'ne s\'auto-place', () {
      final skeleton = [
        const TripSegment(city: 'Bangkok', days: 5),
        const TripSegment(city: 'Phú Quốc', days: 3),
      ];
      final tripStart = _d(2026, 7, 1);
      // Toutes les preserved tombent en chevauchement → leftovers
      final preserved = [
        _p(city: 'X', days: 4, startDate: _d(2026, 7, 4)),
        _p(city: 'Y', days: 2, startDate: _d(2026, 8, 1)),
      ];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: tripStart,
        preserved: preserved,
      );
      expect(result.placed.map((s) => s.city), ['Bangkok', 'Phú Quốc']);
      expect(result.placed.map((s) => s.days), [5, 3]);
      expect(result.leftovers.length, 2);
    });

    test('preserved vide → squelette retourné tel quel', () {
      final skeleton = [const TripSegment(city: 'Bangkok', days: 11)];
      final result = autoPlacePreservedSegments(
        skeleton: skeleton,
        tripStartDate: _d(2026, 6, 22),
        preserved: const [],
      );
      expect(result.placed, equals(skeleton));
      expect(result.leftovers, isEmpty);
    });
  });
}
