// Phase 0 / Tâche 0.4 — Comparateur de snapshots planning.
//
// Self-check Singapour : compare le baseline officiel contre lui-même
// → verdict PASS attendu (deltas tous 0). Sert aussi d'exemple
// d'utilisation pour les phases ultérieures.
//
// 5 tests fixtures fictifs vérifient :
//   1. Self-check identique → PASS
//   2. Petite variation → PASS ou WARN selon seuil
//   3. Forte chute coverage → FAIL
//   4. JSON sans champs optionnels → ne crash pas, not_available
//   5. Détection lieux added/removed via normalisation titres
//
// Run :
//   flutter test test/snapshots/compare_snapshot.dart
//
// Aucun accès réseau / Google Places / Supabase requis. Les
// fixtures sont en mémoire. Le self-check Singapour lit le fichier
// `test/snapshots/singapore_baseline.json` déjà committé.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/quality/snapshot_comparator.dart';

// Chemins par défaut (baseline officiel Singapour). Modifier ici
// pour pointer vers un autre snapshot (pas d'arguments CLI dans
// `flutter test`).
const String _kBaselinePath = 'test/snapshots/singapore_baseline.json';
const String _kCurrentPath = 'test/snapshots/singapore_baseline.json';

/// Sortie Markdown du self-check Singapour. Écrasée à chaque run.
const String _kSingaporeReportPath =
    'test/snapshots/singapore_diff_report.md';

Map<String, dynamic> _readJsonFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Snapshot introuvable', path);
  }
  final raw = file.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('Snapshot JSON doit être un objet, pas $decoded');
  }
  return decoded;
}

void main() {
  // ─── Self-check Singapour (baseline officiel vs lui-même) ───────────

  test('Self-check Singapour : baseline vs baseline → PASS', () {
    final baseline = _readJsonFile(_kBaselinePath);
    final current = _readJsonFile(_kCurrentPath);

    final report = compareSnapshots(
      baseline: baseline,
      current: current,
      baselinePath: _kBaselinePath,
      currentPath: _kCurrentPath,
    );

    // Imprime le rapport console (visible dans la sortie `flutter test`).
    // ignore: avoid_print
    print(report.toConsoleString());

    // Écrit le rapport Markdown à côté du baseline.
    final mdFile = File(_kSingaporeReportPath);
    mdFile.writeAsStringSync(report.toMarkdown());
    // ignore: avoid_print
    print('✔ Markdown diff report écrit → $_kSingaporeReportPath');

    // Verdict attendu : PASS (mêmes deltas partout).
    expect(report.verdict, equals(SnapshotVerdict.pass),
        reason: 'Self-check identique doit produire PASS '
            '(verdict obtenu : ${report.verdict.label}). '
            'Fail reasons: ${report.failReasons}. '
            'Warn reasons: ${report.warnReasons}.');
    expect(report.failReasons, isEmpty);
    expect(report.warnReasons, isEmpty);
    expect(report.volume.deltaVisits, equals(0));
    expect(report.places.added, isEmpty);
    expect(report.places.removed, isEmpty);
    for (final s in report.scoreDiffs) {
      if (s.delta != null) {
        expect(s.delta, equals(0.0),
            reason: 'Score ${s.name} delta != 0 sur self-check');
      }
    }
  });

  // ─── Fixtures fictives ───────────────────────────────────────────────

  group('compareSnapshots — fixtures fictives', () {
    /// Snapshot synthétique minimal utilisé comme baseline dans les
    /// fixtures. Contient les sections nécessaires aux comparaisons.
    Map<String, dynamic> baselineSyn() => {
          'metadata': {
            'pipeline_version': 'V8.28c',
          },
          'summary': {
            'total_visits': 20,
            'total_meals': 8,
            'total_generated_days': 8,
            'free_days_count': 0,
            'avg_inter_slot_distance_meters': 1500.0,
          },
          'quality_report': {
            'overall_score': 80.0,
            'scores': {
              'coherence': 75.0,
              'diversity': 60.0,
              'repetition': 100.0,
              'transition': 90.0,
              'coverage': 100.0,
            },
            'by_day': [
              {
                'date': '2026-05-18',
                'total_slots': 5,
                'visits_count': 3,
                'meals_count': 2,
                'max_inter_slot_meters': 1800,
              },
              {
                'date': '2026-05-19',
                'total_slots': 4,
                'visits_count': 2,
                'meals_count': 2,
                'max_inter_slot_meters': 1500,
              },
            ],
          },
          'visits': [
            {'title': 'Marina Bay Sands', 'day_date': '2026-05-18'},
            {'title': 'Gardens by the Bay', 'day_date': '2026-05-18'},
            {'title': 'Sentosa Island', 'day_date': '2026-05-19'},
          ],
          'meals': [
            {'title': 'Some Restaurant', 'day_date': '2026-05-18'},
          ],
        };

    test('1. Self-check fixture identique → PASS', () {
      final base = baselineSyn();
      final report = compareSnapshots(
        baseline: base,
        current: Map<String, dynamic>.from(base),
      );
      expect(report.verdict, SnapshotVerdict.pass);
      expect(report.failReasons, isEmpty);
      expect(report.warnReasons, isEmpty);
    });

    test('2. Petite variation acceptable → PASS', () {
      // overall -5 (sous seuil WARN 10), pas de chute coverage.
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 75.0,
        'scores': {
          'coherence': 73.0,
          'diversity': 60.0,
          'repetition': 100.0,
          'transition': 88.0,
          'coverage': 100.0,
        },
        'by_day': (base['quality_report'] as Map)['by_day'],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.pass,
          reason: 'Petites variations < seuils WARN → PASS '
              '(obtenu ${report.verdict.label}, '
              'fails=${report.failReasons}, warns=${report.warnReasons})');
    });

    test('2b. Variation WARN-zone (overall -12) → WARN', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 68.0, // -12 → WARN (≥10, <20)
        'scores': {
          'coherence': 73.0,
          'diversity': 60.0,
          'repetition': 100.0,
          'transition': 90.0,
          'coverage': 100.0,
        },
        'by_day': (base['quality_report'] as Map)['by_day'],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.warn);
      expect(report.failReasons, isEmpty);
      expect(report.warnReasons, isNotEmpty);
    });

    test('3. Forte chute coverage (-30) → FAIL', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 70.0,
        'scores': {
          'coherence': 75.0,
          'diversity': 60.0,
          'repetition': 100.0,
          'transition': 90.0,
          'coverage': 70.0, // -30 → FAIL (≥25 drop)
        },
        'by_day': (base['quality_report'] as Map)['by_day'],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.fail);
      expect(report.failReasons, isNotEmpty);
      expect(
          report.failReasons.any((r) => r.toLowerCase().contains('coverage')),
          isTrue);
    });

    test('3b. Coverage absolue < 60 → FAIL', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 65.0,
        'scores': {
          'coherence': 75.0,
          'diversity': 60.0,
          'repetition': 100.0,
          'transition': 90.0,
          'coverage': 55.0, // < 60 → FAIL
        },
        'by_day': (base['quality_report'] as Map)['by_day'],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.fail);
    });

    test('3c. Repetition < 70 → FAIL', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 75.0,
        'scores': {
          'coherence': 75.0,
          'diversity': 60.0,
          'repetition': 50.0, // < 70 → FAIL
          'transition': 90.0,
          'coverage': 100.0,
        },
        'by_day': (base['quality_report'] as Map)['by_day'],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.fail);
    });

    test('3d. Forte chute overall (-25) → FAIL', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 55.0, // -25 → FAIL (≥20)
        'scores': {
          'coherence': 60.0,
          'diversity': 50.0,
          'repetition': 80.0,
          'transition': 70.0,
          'coverage': 80.0,
        },
        'by_day': (base['quality_report'] as Map)['by_day'],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.fail);
      expect(
          report.failReasons.any((r) => r.toLowerCase().contains('overall')),
          isTrue);
    });

    test('3e. Visites drop > 40% → FAIL', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['summary'] = {
        ...base['summary'] as Map<String, dynamic>,
        'total_visits': 10, // -50% par rapport à 20
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.fail);
      expect(
          report.failReasons.any((r) => r.toLowerCase().contains('visits')),
          isTrue);
    });

    test('3f. Run quasi vide (1 visite) alors que baseline ≥ 5 → FAIL',
        () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['summary'] = {
        ...base['summary'] as Map<String, dynamic>,
        'total_visits': 1,
      };
      // Aussi mettre à jour coverage pour éviter double-fail.
      current['quality_report'] = {
        ...base['quality_report'] as Map<String, dynamic>,
        'overall_score': 80.0,
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.verdict, SnapshotVerdict.fail);
      expect(
          report.failReasons
              .any((r) => r.toLowerCase().contains('nearly empty')),
          isTrue);
    });

    test('4. JSON sans champs optionnels → ne crashe pas, '
        'not_available propagé', () {
      final minimalBase = <String, dynamic>{};
      final minimalCur = <String, dynamic>{};
      final report = compareSnapshots(
        baseline: minimalBase,
        current: minimalCur,
      );
      // Aucun champ lisible → pas de FAIL, juste une note informative.
      expect(report.verdict, SnapshotVerdict.pass,
          reason: 'JSON vide → pas de signal de régression, juste notes. '
              'Verdict obtenu : ${report.verdict.label}, '
              'fails=${report.failReasons}, warns=${report.warnReasons}');
      expect(report.notes.any((n) => n.contains('quality_report absent')),
          isTrue);
      // toConsoleString et toMarkdown ne crashent pas.
      expect(report.toConsoleString(), contains('not_available'));
      expect(report.toMarkdown(), contains('not_available'));
    });

    test('4b. Snapshot partiel : summary présent, quality_report absent',
        () {
      final partial = <String, dynamic>{
        'summary': {
          'total_visits': 10,
          'total_meals': 5,
        },
      };
      final report = compareSnapshots(
        baseline: partial,
        current: Map<String, dynamic>.from(partial),
      );
      expect(report.verdict, SnapshotVerdict.pass);
      expect(report.volume.baselineVisits, 10);
      expect(report.volume.currentVisits, 10);
      // Les scores sont null car quality_report absent.
      for (final s in report.scoreDiffs) {
        expect(s.baseline, isNull);
        expect(s.current, isNull);
        expect(s.delta, isNull);
      }
    });

    test('5. Lieux added/removed détectés via normalisation', () {
      final base = baselineSyn();
      final current = Map<String, dynamic>.from(base);
      current['visits'] = [
        // Variante casse + ponctuation → MÊME titre normalisé que baseline.
        {'title': 'MARINA BAY SANDS!!', 'day_date': '2026-05-18'},
        // Ajout
        {'title': 'Universal Studios', 'day_date': '2026-05-19'},
        // Sentosa Island absent → "removed"
        // Gardens by the Bay absent → "removed"
      ];
      current['meals'] = base['meals'];

      final report = compareSnapshots(baseline: base, current: current);
      // "marina bay sands" normalisé identique → pas dans removed ni added.
      expect(
          report.places.added,
          contains('universal studios'),
          reason: 'Universal Studios ajouté');
      expect(
          report.places.removed,
          containsAll(['sentosa island', 'gardens by the bay']),
          reason: 'Sentosa et Gardens retirés');
      expect(
          report.places.added.contains('marina bay sands'),
          isFalse,
          reason: 'Marina Bay Sands variant casse/ponct → '
              'normalisé identique, pas dans added');
      expect(
          report.places.removed.contains('marina bay sands'),
          isFalse);
    });

    test('5b. Normalisation : diacritiques, espaces multiples', () {
      // Test la normalisation isolément via le résultat add/remove.
      final base = <String, dynamic>{
        'visits': [{'title': 'Eiffel Tower', 'day_date': '2026-05-18'}],
        'meals': [],
      };
      final current = <String, dynamic>{
        // Diacritiques + espaces multiples → même titre normalisé.
        'visits': [{'title': '  Éïffèl  Tower  ', 'day_date': '2026-05-18'}],
        'meals': [],
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.places.added, isEmpty,
          reason: 'Diacritiques + whitespace → même normalisation');
      expect(report.places.removed, isEmpty);
    });

    test('toMarkdown produit une string non vide avec sections', () {
      final base = baselineSyn();
      final report = compareSnapshots(
        baseline: base,
        current: Map<String, dynamic>.from(base),
      );
      final md = report.toMarkdown();
      expect(md, contains('# Singapore snapshot comparison'));
      expect(md, contains('## Volume'));
      expect(md, contains('## Quality scores'));
      expect(md, contains('## Places'));
      expect(md, contains('## Days'));
      expect(md, contains('Note Google Places'));
    });
  });

  // ─── Jour devient vide ───────────────────────────────────────────

  group('compareSnapshots — détection journées vides', () {
    test('Day devenu vide → WARN', () {
      final base = <String, dynamic>{
        'quality_report': {
          'by_day': [
            {'date': '2026-05-18', 'total_slots': 3, 'visits_count': 2,
             'meals_count': 1},
            {'date': '2026-05-19', 'total_slots': 4, 'visits_count': 3,
             'meals_count': 1},
          ],
        },
      };
      final current = <String, dynamic>{
        'quality_report': {
          'by_day': [
            {'date': '2026-05-18', 'total_slots': 3, 'visits_count': 2,
             'meals_count': 1},
            // 19/05 disparu → became_empty
          ],
        },
      };
      final report = compareSnapshots(baseline: base, current: current);
      expect(report.days.emptyDates, contains('2026-05-19'));
      expect(report.verdict, SnapshotVerdict.warn);
    });
  });
}
