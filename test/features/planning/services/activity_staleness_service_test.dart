/// Tests unitaires `activity_staleness_service`.
///
/// V4 (Lalith 2026-05-10) — couvre le helper pur `segmentsStructurallyDiffer`
/// utilisé pour décider si on supprime les activités générées par Lunao
/// (`suggested = true`) lors d'une mutation de l'itinéraire.
///
/// Hors scope (touche Supabase) : `clearGeneratedActivitiesForTrip`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/services/activity_staleness_service.dart';
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
}
