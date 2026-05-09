/// Tests unitaires `activity_staleness_service`.
///
/// V4 (Lalith 2026-05-10) — couvre le helper pur `segmentsStructurallyDiffer`
/// utilisé pour décider si on supprime les activités générées par Lunao
/// (`suggested = true`) lors d'une mutation de l'itinéraire.
///
/// Hors scope (touche Supabase) : `clearGeneratedActivitiesForTrip`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/services/activity_staleness_service.dart';
import 'package:voyage/features/planning/services/document_to_activity.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

TripSegment _seg(String city, int days, {String? country, String? source}) =>
    TripSegment(
      city: city,
      days: days,
      country: country,
      sourceAnchorCity: source,
    );

void main() {
  group('segmentsStructurallyDiffer — vrai pour les changements '
      'structurels qui invalident le planning', () {
    test('listes identiques → false', () {
      final a = [_seg('Bangkok', 11), _seg('Hanoï', 5)];
      final b = [_seg('Bangkok', 11), _seg('Hanoï', 5)];
      expect(segmentsStructurallyDiffer(a, b), isFalse);
    });

    test('ajout d\'un segment → true', () {
      final a = [_seg('Bangkok', 11)];
      final b = [_seg('Bangkok', 11), _seg('Hanoï', 5)];
      expect(segmentsStructurallyDiffer(a, b), isTrue);
    });

    test('suppression d\'un segment → true', () {
      final a = [_seg('Bangkok', 11), _seg('Hanoï', 5)];
      final b = [_seg('Bangkok', 11)];
      expect(segmentsStructurallyDiffer(a, b), isTrue);
    });

    test('réordonnancement → true', () {
      final a = [_seg('Bangkok', 11), _seg('Hanoï', 5)];
      final b = [_seg('Hanoï', 5), _seg('Bangkok', 11)];
      expect(segmentsStructurallyDiffer(a, b), isTrue);
    });

    test('changement de durée d\'un segment → true', () {
      final a = [_seg('Bangkok', 11)];
      final b = [_seg('Bangkok', 12)];
      expect(segmentsStructurallyDiffer(a, b), isTrue);
    });

    test('changement de ville d\'un segment (même position) → true', () {
      final a = [_seg('Bangkok', 11)];
      final b = [_seg('Hanoï', 11)];
      expect(segmentsStructurallyDiffer(a, b), isTrue);
    });
  });

  group('segmentsStructurallyDiffer — false pour les changements non '
      'structurels qui ne doivent PAS invalider le planning', () {
    test('changement de pays seul (même city/days) → false', () {
      // Les activités sont indexées sur la ville et la date, le pays ne
      // change pas l'expérience temporelle. Pas de raison de jeter le
      // planning si le voyageur précise juste le pays.
      final a = [_seg('Bangkok', 11)];
      final b = [_seg('Bangkok', 11, country: 'Thaïlande')];
      expect(segmentsStructurallyDiffer(a, b), isFalse);
    });

    test('changement de sourceAnchorCity seul → false', () {
      // Le marqueur "source d'ancrage" n'affecte pas le planning, juste
      // le drag-lock UI. Inutile de blast les activités.
      final a = [_seg('Bangkok', 11), _seg('Krabi', 3)];
      final b = [_seg('Bangkok', 11), _seg('Krabi', 3, source: 'Bangkok')];
      expect(segmentsStructurallyDiffer(a, b), isFalse);
    });

    test('listes vides identiques → false', () {
      expect(segmentsStructurallyDiffer(const [], const []), isFalse);
    });

    test('vide vs non-vide → true', () {
      expect(segmentsStructurallyDiffer(const [], [_seg('Bangkok', 11)]),
          isTrue);
    });
  });

  group('findOrphanedActivities — V6 Lot E TODO 1', () {
    DateTime d(int y, int m, int day) => DateTime(y, m, day);
    TripActivity act({
      required String id,
      required DateTime dayDate,
      bool suggested = false,
      String title = 'Activity',
    }) =>
        TripActivity(
          id: id,
          tripId: 't1',
          dayDate: dayDate,
          startTime: '12:00',
          title: title,
          tag: 'Activité',
          suggested: suggested,
        );

    test('activité dans la plage → non orpheline', () {
      final segments = [_seg('Bangkok', 11)];
      final acts = [act(id: 'a1', dayDate: d(2026, 6, 25))];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans, isEmpty);
    });

    test('activité avant le début du voyage → orpheline', () {
      final segments = [_seg('Bangkok', 11)];
      final acts = [act(id: 'a1', dayDate: d(2026, 6, 20))];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans.length, 1);
    });

    test('activité après la fin du voyage → orpheline', () {
      final segments = [_seg('Bangkok', 5)];
      final acts = [act(id: 'a1', dayDate: d(2026, 7, 10))];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans.length, 1);
    });

    test('activité sur le jour de fin (exclusive) → orpheline', () {
      // segments end exclusive : Bangkok 22-27/06 = 5 jours, le 27/06
      // est le jour de DÉPART (n'est plus dans le segment).
      final segments = [_seg('Bangkok', 5)];
      final acts = [act(id: 'a1', dayDate: d(2026, 6, 27))];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans.length, 1);
    });

    test('activités générées par Lunao (suggested=true) → ignorées '
        '(elles sont supprimées par clearGenerated)', () {
      final segments = [_seg('Bangkok', 5)];
      final acts = [
        act(id: 'a1', dayDate: d(2026, 7, 10), suggested: true),
      ];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans, isEmpty);
    });

    test('activités virtuelles (id "doc:…") → ignorées (gérées par '
        'document_consistency)', () {
      final segments = [_seg('Bangkok', 5)];
      final acts = [
        act(
          id: '${virtualActivityPrefix}xyz:checkin',
          dayDate: d(2026, 7, 10),
        ),
      ];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans, isEmpty);
    });

    test('itinéraire avec gap entre 2 segments → activité dans le gap '
        'ne devrait PAS arriver (les segments sont contigus par '
        'construction du modèle)', () {
      // Sanity check : les segments cumulent à partir de tripStartDate
      // sans gap. Une activité au milieu est forcément dans un seg.
      final segments = [_seg('Bangkok', 3), _seg('Phú Quốc', 3)];
      final acts = [act(id: 'a1', dayDate: d(2026, 6, 24))];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans, isEmpty);
    });

    test('aucun segment → orphelins = liste vide (rien à comparer)', () {
      final acts = [act(id: 'a1', dayDate: d(2026, 6, 25))];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: const [],
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans, isEmpty);
    });

    test('plusieurs activités, certaines orphelines → seul le subset '
        'hors-plage est retourné', () {
      final segments = [_seg('Bangkok', 5)];
      final acts = [
        act(id: 'in', dayDate: d(2026, 6, 24)),
        act(id: 'before', dayDate: d(2026, 6, 20)),
        act(id: 'after', dayDate: d(2026, 7, 1)),
      ];
      final orphans = findOrphanedActivities(
        activities: acts,
        segments: segments,
        tripStartDate: d(2026, 6, 22),
      );
      expect(orphans.map((a) => a.id).toSet(), {'before', 'after'});
    });
  });
}
