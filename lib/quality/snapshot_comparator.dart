/// Phase 0 / Tâche 0.4 — Outil de comparaison de snapshots planning.
///
/// Compare 2 `Map<String, dynamic>` JSON produits par
/// `test/snapshots/generate_baseline.dart`. Produit un rapport
/// console + markdown + verdict PASS/WARN/FAIL pour détecter les
/// vraies régressions sans bloquer sur le bruit Google Places.
///
/// **Module pur** : aucun accès réseau, aucune dépendance Supabase.
/// `compareSnapshots(baseline: ..., current: ...)` est une fonction
/// déterministe.
///
/// **Robustesse JSON** : tous les accès sont défensifs. Un snapshot
/// avec champs manquants est comparé sur ce qui est disponible. Pas
/// de crash, juste des `not_available` propagés dans le rapport.
///
/// **Seuils provisoires Phase 0** (à recalibrer au fil des phases).
/// Centralisés en constantes nommées `_kFail*` / `_kWarn*` en haut
/// de fichier.
library;

import 'dart:math' as math;

// ─── Seuils PASS / WARN / FAIL ─────────────────────────────────────────
//
// Provisoires pour Phase 0. À recalibrer dans phases ultérieures
// quand on aura collecté plus de données sur la stabilité des runs
// non-déterministes Google Places.

/// Coverage en chute libre — FAIL.
const double _kFailCoverageDrop = 25.0;
const double _kFailCoverageBelow = 60.0;
const double _kFailRepetitionBelow = 70.0;
const double _kFailOverallDrop = 20.0;
const double _kFailVisitsDropPct = 40.0;

/// Baisses notables — WARN.
const double _kWarnOverallDrop = 10.0;
const double _kWarnCoherenceDrop = 15.0;
const double _kWarnTransitionDrop = 15.0;
const double _kWarnVisitsChangePct = 20.0;
const double _kWarnTitlesDiffPct = 30.0;

/// Marker textuel utilisé partout où une valeur n'est pas lisible
/// depuis le JSON source. Évite de propager `null` dans le rapport
/// (lisibilité console + parsing Markdown).
const String kNotAvailable = 'not_available';

// ─── Helpers de lecture JSON défensifs ─────────────────────────────────

num? _readNum(Map<String, dynamic>? root, List<String> path) {
  dynamic node = root;
  for (final key in path) {
    if (node is! Map<String, dynamic>) return null;
    node = node[key];
  }
  if (node is num) return node;
  if (node is String) {
    final parsed = num.tryParse(node);
    if (parsed != null) return parsed;
  }
  return null;
}

double? _readDouble(Map<String, dynamic>? root, List<String> path) =>
    _readNum(root, path)?.toDouble();

int? _readInt(Map<String, dynamic>? root, List<String> path) =>
    _readNum(root, path)?.toInt();

List<dynamic>? _readList(Map<String, dynamic>? root, List<String> path) {
  dynamic node = root;
  for (final key in path) {
    if (node is! Map<String, dynamic>) return null;
    node = node[key];
  }
  return node is List ? node : null;
}

String _formatNum(num? v, {int decimals = 1}) =>
    v == null ? kNotAvailable : v.toStringAsFixed(decimals);

String _formatInt(int? v) => v == null ? kNotAvailable : v.toString();

String _formatDelta(num? delta, {int decimals = 1}) {
  if (delta == null) return kNotAvailable;
  final sign = delta >= 0 ? '+' : '';
  return '$sign${delta.toStringAsFixed(decimals)}';
}

// ─── Normalisation titres pour comparaison de lieux ────────────────────

/// Normalise un titre pour comparaison cross-snapshot :
/// - lowercase
/// - strip diacritiques (é→e, à→a, ç→c, ō→o, ū→u, etc.)
/// - remplace tout caractère non-alphanumérique par espace
/// - collapse whitespace
///
/// "Marina Bay Sands" et "marina bay sands!!" produisent la même clé.
/// Volontairement permissif — c'est de la comparaison fuzzy de
/// présence, pas d'identité stricte (qui utiliserait `placeId`).
String _normalizeTitle(String s) {
  var n = s.toLowerCase().trim();
  const replacements = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ç': 'c', 'đ': 'd', 'ñ': 'n', 'ý': 'y',
  };
  replacements.forEach((from, to) {
    n = n.replaceAll(from, to);
  });
  // Remplace tout non-alphanumérique par espace (ponctuation,
  // apostrophes, tirets, etc.).
  n = n.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  // Collapse whitespace.
  n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
  return n;
}

/// Extrait les titres normalisés des slots d'un snapshot. Cherche
/// dans `visits` + `meals` (format produit par `generate_baseline.dart`).
/// Retourne une `Map<title, count>` pour permettre la détection de
/// répétitions (count > 1).
Map<String, int> _extractTitleCounts(Map<String, dynamic>? snapshot) {
  final counts = <String, int>{};
  if (snapshot == null) return counts;
  for (final key in const ['visits', 'meals']) {
    final list = snapshot[key];
    if (list is! List) continue;
    for (final item in list) {
      if (item is! Map) continue;
      final title = item['title'];
      if (title is! String || title.isEmpty) continue;
      final n = _normalizeTitle(title);
      if (n.isEmpty) continue;
      counts[n] = (counts[n] ?? 0) + 1;
    }
  }
  return counts;
}

// ─── Modèles de rapport ────────────────────────────────────────────────

/// Verdict global d'une comparaison de snapshots.
///
/// - `PASS` : aucun écart franchit un seuil WARN ou FAIL.
/// - `WARN` : ≥1 écart entre seuil WARN et FAIL. Pas bloquant mais à
///   investiguer.
/// - `FAIL` : ≥1 écart au-delà du seuil FAIL. Régression probable.
enum SnapshotVerdict { pass, warn, fail }

extension SnapshotVerdictX on SnapshotVerdict {
  String get label => switch (this) {
        SnapshotVerdict.pass => 'PASS',
        SnapshotVerdict.warn => 'WARN',
        SnapshotVerdict.fail => 'FAIL',
      };
}

/// Diff d'un score individuel (baseline vs current). Status par score
/// = niveau de la déviation. Le verdict global est l'agrégation des
/// status individuels (max).
class ScoreDiff {
  /// Nom user-facing du score (ex: "overall", "coherence").
  final String name;
  final double? baseline;
  final double? current;
  /// `current - baseline`. Positif = amélioration, négatif = baisse.
  final double? delta;
  /// `OK` | `WARN` | `FAIL`.
  final SnapshotVerdict status;
  /// Raison textuelle si WARN ou FAIL. Null si OK.
  final String? reason;

  const ScoreDiff({
    required this.name,
    required this.baseline,
    required this.current,
    required this.delta,
    required this.status,
    this.reason,
  });
}

class SnapshotVolumeDiff {
  final int? baselineVisits;
  final int? currentVisits;
  /// `currentVisits - baselineVisits`, null si l'un des deux manque.
  final int? deltaVisits;
  /// `(deltaVisits / baselineVisits) * 100`, null si baseline=0 ou
  /// manquant.
  final double? visitsChangePct;
  final int? baselineMeals;
  final int? currentMeals;
  final int? baselineSlots;
  final int? currentSlots;
  final int? baselineActiveDays;
  final int? currentActiveDays;
  final int? baselineFreeDays;
  final int? currentFreeDays;

  const SnapshotVolumeDiff({
    required this.baselineVisits,
    required this.currentVisits,
    required this.deltaVisits,
    required this.visitsChangePct,
    required this.baselineMeals,
    required this.currentMeals,
    required this.baselineSlots,
    required this.currentSlots,
    required this.baselineActiveDays,
    required this.currentActiveDays,
    required this.baselineFreeDays,
    required this.currentFreeDays,
  });
}

class SnapshotPlacesDiff {
  /// Titres normalisés présents dans baseline mais absents du current.
  final List<String> removed;
  /// Titres normalisés présents dans current mais absents de baseline.
  final List<String> added;
  /// Titres normalisés répétés dans baseline (count > 1).
  final List<String> repeatedInBaseline;
  /// Titres normalisés répétés dans current.
  final List<String> repeatedInCurrent;
  /// Total de titres uniques baseline.
  final int totalBaseline;
  /// Total de titres uniques current.
  final int totalCurrent;
  /// `(added + removed) / max(totalBaseline, totalCurrent) * 100`.
  /// Mesure le "churn" des lieux entre les 2 snapshots. Null si pas
  /// assez de données.
  final double? changeRatioPct;

  const SnapshotPlacesDiff({
    required this.removed,
    required this.added,
    required this.repeatedInBaseline,
    required this.repeatedInCurrent,
    required this.totalBaseline,
    required this.totalCurrent,
    required this.changeRatioPct,
  });
}

class SnapshotDistancesDiff {
  final double? baselineAvgM;
  final double? currentAvgM;
  final double? deltaAvgM;
  final double? baselineMaxM;
  final double? currentMaxM;
  final double? deltaMaxM;

  const SnapshotDistancesDiff({
    required this.baselineAvgM,
    required this.currentAvgM,
    required this.deltaAvgM,
    required this.baselineMaxM,
    required this.currentMaxM,
    required this.deltaMaxM,
  });
}

/// Diff per-day. Sert à détecter des journées qui passent de
/// remplies à vides ou inversement.
class DayDiff {
  final String date;
  final int? baselineSlots;
  final int? currentSlots;
  final int? baselineVisits;
  final int? currentVisits;
  final int? baselineMeals;
  final int? currentMeals;
  /// True si baseline avait ≥1 slot et current 0. Signal de
  /// régression. Suit la spec : *"une journée devient vide alors
  /// que baseline avait des activités"*.
  final bool becameEmpty;

  const DayDiff({
    required this.date,
    required this.baselineSlots,
    required this.currentSlots,
    required this.baselineVisits,
    required this.currentVisits,
    required this.baselineMeals,
    required this.currentMeals,
    required this.becameEmpty,
  });
}

class SnapshotDaysDiff {
  /// Détail par date (union des dates baseline + current, triées).
  final List<DayDiff> byDate;
  /// Dates qui sont passées de "actives" à "vides" entre baseline
  /// et current.
  final List<String> emptyDates;

  const SnapshotDaysDiff({
    required this.byDate,
    required this.emptyDates,
  });
}

class SnapshotComparison {
  final String baselinePath;
  final String currentPath;
  final SnapshotVerdict verdict;
  /// Raisons agrégées de chaque déclencheur FAIL (ordre stable).
  final List<String> failReasons;
  /// Raisons agrégées de chaque déclencheur WARN.
  final List<String> warnReasons;
  /// Notes informatives (non-bloquantes). Ex: "JSON courant sans
  /// quality_report → scores not_available".
  final List<String> notes;

  final SnapshotVolumeDiff volume;
  final List<ScoreDiff> scoreDiffs;
  final SnapshotPlacesDiff places;
  final SnapshotDistancesDiff distances;
  final SnapshotDaysDiff days;

  const SnapshotComparison({
    required this.baselinePath,
    required this.currentPath,
    required this.verdict,
    required this.failReasons,
    required this.warnReasons,
    required this.notes,
    required this.volume,
    required this.scoreDiffs,
    required this.places,
    required this.distances,
    required this.days,
  });

  /// Rendu console — lisible, synthétique. Pour `flutter test`
  /// stdout.
  String toConsoleString() {
    final b = StringBuffer();
    b.writeln('═══════════════════════════════════════════════════════════════');
    b.writeln('  Singapore snapshot comparison');
    b.writeln('═══════════════════════════════════════════════════════════════');
    b.writeln('  Baseline: $baselinePath');
    b.writeln('  Current : $currentPath');
    b.writeln('  Verdict : ${verdict.label}');
    b.writeln('');
    b.writeln('  Volume');
    b.writeln('  ─ visits      : ${_formatInt(volume.baselineVisits)} → '
        '${_formatInt(volume.currentVisits)} (delta '
        '${_formatDelta(volume.deltaVisits, decimals: 0)})');
    b.writeln('  ─ meals       : ${_formatInt(volume.baselineMeals)} → '
        '${_formatInt(volume.currentMeals)}');
    b.writeln('  ─ slots       : ${_formatInt(volume.baselineSlots)} → '
        '${_formatInt(volume.currentSlots)}');
    b.writeln('  ─ active days : ${_formatInt(volume.baselineActiveDays)} → '
        '${_formatInt(volume.currentActiveDays)}');
    b.writeln('  ─ free days   : ${_formatInt(volume.baselineFreeDays)} → '
        '${_formatInt(volume.currentFreeDays)}');
    b.writeln('');
    b.writeln('  Quality scores');
    for (final s in scoreDiffs) {
      final tag = s.status == SnapshotVerdict.pass
          ? 'OK'
          : s.status.label;
      b.writeln('  ─ ${s.name.padRight(11)} : '
          '${_formatNum(s.baseline)} → ${_formatNum(s.current)} '
          '(delta ${_formatDelta(s.delta)}) $tag');
    }
    b.writeln('');
    b.writeln('  Places');
    b.writeln('  ─ removed : ${places.removed.length}');
    b.writeln('  ─ added   : ${places.added.length}');
    b.writeln('  ─ change ratio : '
        '${_formatNum(places.changeRatioPct, decimals: 1)} %');
    if (places.removed.isNotEmpty || places.added.isNotEmpty) {
      if (places.removed.isNotEmpty) {
        b.writeln('  ─ removed list :');
        for (final r in places.removed.take(10)) {
          b.writeln('      - $r');
        }
        if (places.removed.length > 10) {
          b.writeln('      (… ${places.removed.length - 10} more)');
        }
      }
      if (places.added.isNotEmpty) {
        b.writeln('  ─ added list :');
        for (final a in places.added.take(10)) {
          b.writeln('      + $a');
        }
        if (places.added.length > 10) {
          b.writeln('      (… ${places.added.length - 10} more)');
        }
      }
    }
    b.writeln('');
    b.writeln('  Distances');
    b.writeln('  ─ avg inter-slot (m) : '
        '${_formatNum(distances.baselineAvgM)} → '
        '${_formatNum(distances.currentAvgM)} '
        '(delta ${_formatDelta(distances.deltaAvgM)})');
    b.writeln('');
    b.writeln('  Days');
    if (days.emptyDates.isNotEmpty) {
      b.writeln('  ─ became empty :');
      for (final d in days.emptyDates) {
        b.writeln('      - $d');
      }
    } else {
      b.writeln('  ─ no day became empty');
    }
    b.writeln('');
    if (failReasons.isEmpty && warnReasons.isEmpty) {
      b.writeln('  Warnings : (none)');
    } else {
      if (failReasons.isNotEmpty) {
        b.writeln('  FAIL reasons :');
        for (final r in failReasons) {
          b.writeln('    [FAIL] $r');
        }
      }
      if (warnReasons.isNotEmpty) {
        b.writeln('  WARN reasons :');
        for (final r in warnReasons) {
          b.writeln('    [WARN] $r');
        }
      }
    }
    if (notes.isNotEmpty) {
      b.writeln('');
      b.writeln('  Notes :');
      for (final n in notes) {
        b.writeln('    - $n');
      }
    }
    b.writeln('═══════════════════════════════════════════════════════════════');
    return b.toString();
  }

  /// Rendu Markdown — pour `test/snapshots/singapore_diff_report.md`.
  /// Sections : entête, volume, scores, lieux, journées,
  /// warnings/fails, note Google Places.
  String toMarkdown() {
    final b = StringBuffer();
    b.writeln('# Singapore snapshot comparison');
    b.writeln('');
    b.writeln('- **Baseline** : `$baselinePath`');
    b.writeln('- **Current**  : `$currentPath`');
    b.writeln('- **Verdict**  : **${verdict.label}**');
    b.writeln('');

    // Volume
    b.writeln('## Volume');
    b.writeln('');
    b.writeln('| Metric | Baseline | Current | Delta |');
    b.writeln('|---|---:|---:|---:|');
    b.writeln(
        '| Visits | ${_formatInt(volume.baselineVisits)} | ${_formatInt(volume.currentVisits)} | ${_formatDelta(volume.deltaVisits, decimals: 0)} |');
    b.writeln(
        '| Meals | ${_formatInt(volume.baselineMeals)} | ${_formatInt(volume.currentMeals)} | — |');
    b.writeln(
        '| Slots | ${_formatInt(volume.baselineSlots)} | ${_formatInt(volume.currentSlots)} | — |');
    b.writeln(
        '| Active days | ${_formatInt(volume.baselineActiveDays)} | ${_formatInt(volume.currentActiveDays)} | — |');
    b.writeln(
        '| Free days | ${_formatInt(volume.baselineFreeDays)} | ${_formatInt(volume.currentFreeDays)} | — |');
    if (volume.visitsChangePct != null) {
      b.writeln(
          '| Visits change % | — | — | ${_formatDelta(volume.visitsChangePct)} % |');
    }
    b.writeln('');

    // Scores
    b.writeln('## Quality scores');
    b.writeln('');
    b.writeln('| Score | Baseline | Current | Delta | Status |');
    b.writeln('|---|---:|---:|---:|:---:|');
    for (final s in scoreDiffs) {
      final tag =
          s.status == SnapshotVerdict.pass ? 'OK' : s.status.label;
      b.writeln(
          '| ${s.name} | ${_formatNum(s.baseline)} | ${_formatNum(s.current)} | ${_formatDelta(s.delta)} | $tag |');
    }
    b.writeln('');

    // Lieux
    b.writeln('## Places');
    b.writeln('');
    b.writeln('- Removed (baseline → ∅) : **${places.removed.length}**');
    b.writeln('- Added   (∅ → current)  : **${places.added.length}**');
    b.writeln('- Change ratio : '
        '${_formatNum(places.changeRatioPct, decimals: 1)} %');
    b.writeln('- Repeated in baseline : ${places.repeatedInBaseline.length}');
    b.writeln('- Repeated in current  : ${places.repeatedInCurrent.length}');
    b.writeln('');
    if (places.removed.isNotEmpty) {
      b.writeln('### Removed titles');
      for (final r in places.removed) {
        b.writeln('- ~~$r~~');
      }
      b.writeln('');
    }
    if (places.added.isNotEmpty) {
      b.writeln('### Added titles');
      for (final a in places.added) {
        b.writeln('- $a');
      }
      b.writeln('');
    }

    // Distances
    b.writeln('## Distances');
    b.writeln('');
    b.writeln('| Metric | Baseline | Current | Delta |');
    b.writeln('|---|---:|---:|---:|');
    b.writeln(
        '| Avg inter-slot (m) | ${_formatNum(distances.baselineAvgM)} | ${_formatNum(distances.currentAvgM)} | ${_formatDelta(distances.deltaAvgM)} |');
    b.writeln(
        '| Max inter-slot (m) | ${_formatNum(distances.baselineMaxM)} | ${_formatNum(distances.currentMaxM)} | ${_formatDelta(distances.deltaMaxM)} |');
    b.writeln('');

    // Journées
    b.writeln('## Days');
    b.writeln('');
    if (days.emptyDates.isNotEmpty) {
      b.writeln('### Days that became empty');
      for (final d in days.emptyDates) {
        b.writeln('- $d');
      }
      b.writeln('');
    }
    b.writeln('| Date | Slots (b → c) | Visits (b → c) | Meals (b → c) |');
    b.writeln('|---|:---:|:---:|:---:|');
    for (final d in days.byDate) {
      b.writeln(
          '| ${d.date} | ${_formatInt(d.baselineSlots)} → ${_formatInt(d.currentSlots)} | ${_formatInt(d.baselineVisits)} → ${_formatInt(d.currentVisits)} | ${_formatInt(d.baselineMeals)} → ${_formatInt(d.currentMeals)} |');
    }
    b.writeln('');

    // Warnings / Fails
    b.writeln('## Verdict reasons');
    b.writeln('');
    if (failReasons.isEmpty && warnReasons.isEmpty) {
      b.writeln('_None._');
    } else {
      if (failReasons.isNotEmpty) {
        b.writeln('### FAIL');
        for (final r in failReasons) {
          b.writeln('- $r');
        }
        b.writeln('');
      }
      if (warnReasons.isNotEmpty) {
        b.writeln('### WARN');
        for (final r in warnReasons) {
          b.writeln('- $r');
        }
        b.writeln('');
      }
    }

    if (notes.isNotEmpty) {
      b.writeln('## Notes');
      b.writeln('');
      for (final n in notes) {
        b.writeln('- $n');
      }
      b.writeln('');
    }

    b.writeln('---');
    b.writeln('');
    b.writeln(
        '> ⚠️ **Note Google Places** : ce snapshot dépend de la Google Places API. ');
    b.writeln(
        '> Des variations entre runs (visites différentes, scores légèrement différents) ');
    b.writeln(
        '> peuvent être non fonctionnelles (rotation API, cache, etc.). Le comparateur ');
    b.writeln(
        '> est tolérant : seuls les écarts dépassant les seuils Phase 0 déclenchent ');
    b.writeln(
        '> WARN/FAIL. Voir `docs/migrations/phase0_task0_4.md` pour les seuils exacts.');
    return b.toString();
  }
}

// ─── Compute ───────────────────────────────────────────────────────────

/// Compare 2 snapshots JSON et produit un `SnapshotComparison`.
///
/// `baseline` et `current` sont attendus au format produit par
/// `test/snapshots/generate_baseline.dart`. Champs absents ⇒ valeurs
/// `null` propagées dans le rapport (jamais de crash).
///
/// `baselinePath` / `currentPath` sont purement informatifs (affichés
/// dans le rapport). Si l'appelant les omet, ils valent `'(baseline)'`
/// et `'(current)'`.
SnapshotComparison compareSnapshots({
  required Map<String, dynamic> baseline,
  required Map<String, dynamic> current,
  String baselinePath = '(baseline)',
  String currentPath = '(current)',
}) {
  final failReasons = <String>[];
  final warnReasons = <String>[];
  final notes = <String>[];

  // ─── Volume ───────────────────────────────────────────────────────
  final bVisits = _readInt(baseline, ['summary', 'total_visits']);
  final cVisits = _readInt(current, ['summary', 'total_visits']);
  final deltaVisits =
      (bVisits != null && cVisits != null) ? cVisits - bVisits : null;
  final visitsChangePct = (bVisits != null && bVisits > 0 && cVisits != null)
      ? ((cVisits - bVisits) / bVisits) * 100.0
      : null;

  final bMeals = _readInt(baseline, ['summary', 'total_meals']);
  final cMeals = _readInt(current, ['summary', 'total_meals']);
  final bActiveDays = _readInt(baseline, ['summary', 'total_generated_days']);
  final cActiveDays = _readInt(current, ['summary', 'total_generated_days']);
  final bFreeDays = _readInt(baseline, ['summary', 'free_days_count']);
  final cFreeDays = _readInt(current, ['summary', 'free_days_count']);
  final bSlots = (bVisits ?? 0) + (bMeals ?? 0);
  final cSlots = (cVisits ?? 0) + (cMeals ?? 0);

  final volume = SnapshotVolumeDiff(
    baselineVisits: bVisits,
    currentVisits: cVisits,
    deltaVisits: deltaVisits,
    visitsChangePct: visitsChangePct,
    baselineMeals: bMeals,
    currentMeals: cMeals,
    baselineSlots: (bVisits == null && bMeals == null) ? null : bSlots,
    currentSlots: (cVisits == null && cMeals == null) ? null : cSlots,
    baselineActiveDays: bActiveDays,
    currentActiveDays: cActiveDays,
    baselineFreeDays: bFreeDays,
    currentFreeDays: cFreeDays,
  );

  if (visitsChangePct != null) {
    final absPct = visitsChangePct.abs();
    if (visitsChangePct < 0 && absPct > _kFailVisitsDropPct) {
      failReasons.add(
          'Visits drop ${absPct.toStringAsFixed(1)}% > ${_kFailVisitsDropPct.toStringAsFixed(0)}% threshold');
    } else if (absPct > _kWarnVisitsChangePct) {
      warnReasons.add(
          'Visits change ${visitsChangePct.toStringAsFixed(1)}% '
          '(|x| > ${_kWarnVisitsChangePct.toStringAsFixed(0)}%)');
    }
  }
  // "un run qui avait des activités devient presque vide" — détecté
  // si baseline ≥ 5 visites ET current ≤ 1.
  if (bVisits != null && bVisits >= 5 && cVisits != null && cVisits <= 1) {
    failReasons.add(
        'Current run nearly empty ($cVisits visit) while baseline had $bVisits');
  }

  // ─── Scores ───────────────────────────────────────────────────────
  final scoreSpecs = <
      ({
        String name,
        double? baseline,
        double? current,
      })>[
    (
      name: 'overall',
      baseline: _readDouble(baseline, ['quality_report', 'overall_score']),
      current: _readDouble(current, ['quality_report', 'overall_score']),
    ),
    (
      name: 'coherence',
      baseline:
          _readDouble(baseline, ['quality_report', 'scores', 'coherence']),
      current:
          _readDouble(current, ['quality_report', 'scores', 'coherence']),
    ),
    (
      name: 'diversity',
      baseline:
          _readDouble(baseline, ['quality_report', 'scores', 'diversity']),
      current:
          _readDouble(current, ['quality_report', 'scores', 'diversity']),
    ),
    (
      name: 'repetition',
      baseline:
          _readDouble(baseline, ['quality_report', 'scores', 'repetition']),
      current:
          _readDouble(current, ['quality_report', 'scores', 'repetition']),
    ),
    (
      name: 'transition',
      baseline:
          _readDouble(baseline, ['quality_report', 'scores', 'transition']),
      current:
          _readDouble(current, ['quality_report', 'scores', 'transition']),
    ),
    (
      name: 'coverage',
      baseline:
          _readDouble(baseline, ['quality_report', 'scores', 'coverage']),
      current:
          _readDouble(current, ['quality_report', 'scores', 'coverage']),
    ),
  ];

  final scoreDiffs = <ScoreDiff>[];
  for (final spec in scoreSpecs) {
    final delta =
        (spec.baseline != null && spec.current != null)
            ? spec.current! - spec.baseline!
            : null;
    var status = SnapshotVerdict.pass;
    String? reason;

    if (delta != null) {
      switch (spec.name) {
        case 'overall':
          if (delta <= -_kFailOverallDrop) {
            status = SnapshotVerdict.fail;
            reason =
                'overall drop ${delta.toStringAsFixed(1)} ≤ -${_kFailOverallDrop.toStringAsFixed(0)}';
            failReasons.add(reason);
          } else if (delta <= -_kWarnOverallDrop) {
            status = SnapshotVerdict.warn;
            reason =
                'overall drop ${delta.toStringAsFixed(1)} ≤ -${_kWarnOverallDrop.toStringAsFixed(0)}';
            warnReasons.add(reason);
          }
        case 'coherence':
          if (delta <= -_kWarnCoherenceDrop) {
            status = SnapshotVerdict.warn;
            reason =
                'coherence drop ${delta.toStringAsFixed(1)} ≤ -${_kWarnCoherenceDrop.toStringAsFixed(0)}';
            warnReasons.add(reason);
          }
        case 'transition':
          if (delta <= -_kWarnTransitionDrop) {
            status = SnapshotVerdict.warn;
            reason =
                'transition drop ${delta.toStringAsFixed(1)} ≤ -${_kWarnTransitionDrop.toStringAsFixed(0)}';
            warnReasons.add(reason);
          }
        case 'coverage':
          if (delta <= -_kFailCoverageDrop) {
            status = SnapshotVerdict.fail;
            reason =
                'coverage drop ${delta.toStringAsFixed(1)} ≤ -${_kFailCoverageDrop.toStringAsFixed(0)}';
            failReasons.add(reason);
          }
        // diversity, repetition : pas de seuil delta WARN/FAIL ici
        // (couverts par les seuils absolus ci-dessous).
      }
    }

    // Seuils absolus (current below threshold).
    if (spec.name == 'coverage' && spec.current != null &&
        spec.current! < _kFailCoverageBelow) {
      status = SnapshotVerdict.fail;
      final r =
          'coverage ${spec.current!.toStringAsFixed(1)} < ${_kFailCoverageBelow.toStringAsFixed(0)}';
      reason ??= r;
      failReasons.add(r);
    }
    if (spec.name == 'repetition' && spec.current != null &&
        spec.current! < _kFailRepetitionBelow) {
      status = SnapshotVerdict.fail;
      final r =
          'repetition ${spec.current!.toStringAsFixed(1)} < ${_kFailRepetitionBelow.toStringAsFixed(0)}';
      reason ??= r;
      failReasons.add(r);
    }

    scoreDiffs.add(ScoreDiff(
      name: spec.name,
      baseline: spec.baseline,
      current: spec.current,
      delta: delta,
      status: status,
      reason: reason,
    ));
  }

  // Note si quality_report absent.
  if (scoreSpecs.every((s) => s.baseline == null) ||
      scoreSpecs.every((s) => s.current == null)) {
    notes.add(
        'quality_report absent ou partiel — comparaison de scores limitée');
  }

  // ─── Lieux ────────────────────────────────────────────────────────
  final baselineTitles = _extractTitleCounts(baseline);
  final currentTitles = _extractTitleCounts(current);
  final bSet = baselineTitles.keys.toSet();
  final cSet = currentTitles.keys.toSet();
  final removed = bSet.difference(cSet).toList()..sort();
  final added = cSet.difference(bSet).toList()..sort();
  final repeatedB = baselineTitles.entries
      .where((e) => e.value > 1)
      .map((e) => '${e.key} ×${e.value}')
      .toList()
    ..sort();
  final repeatedC = currentTitles.entries
      .where((e) => e.value > 1)
      .map((e) => '${e.key} ×${e.value}')
      .toList()
    ..sort();
  final maxBC = math.max(bSet.length, cSet.length);
  final changeRatioPct = maxBC == 0
      ? null
      : ((removed.length + added.length) / maxBC) * 100.0;

  final places = SnapshotPlacesDiff(
    removed: removed,
    added: added,
    repeatedInBaseline: repeatedB,
    repeatedInCurrent: repeatedC,
    totalBaseline: bSet.length,
    totalCurrent: cSet.length,
    changeRatioPct: changeRatioPct,
  );

  if (changeRatioPct != null && changeRatioPct > _kWarnTitlesDiffPct) {
    warnReasons.add(
        'Titles diff ${changeRatioPct.toStringAsFixed(1)}% > ${_kWarnTitlesDiffPct.toStringAsFixed(0)}% threshold');
  }

  // ─── Distances ────────────────────────────────────────────────────
  final bAvgRaw = baseline['summary']?['avg_inter_slot_distance_meters'];
  final cAvgRaw = current['summary']?['avg_inter_slot_distance_meters'];
  final bAvgM =
      bAvgRaw is num ? bAvgRaw.toDouble() : double.tryParse('$bAvgRaw');
  final cAvgM =
      cAvgRaw is num ? cAvgRaw.toDouble() : double.tryParse('$cAvgRaw');
  final deltaAvgM = (bAvgM != null && cAvgM != null) ? cAvgM - bAvgM : null;

  // Max inter-slot : reconstruit depuis quality_report.by_day si dispo.
  double? bMaxM;
  double? cMaxM;
  final bDays = _readList(baseline, ['quality_report', 'by_day']);
  final cDays = _readList(current, ['quality_report', 'by_day']);
  if (bDays != null) {
    bMaxM = 0.0;
    for (final d in bDays) {
      if (d is Map) {
        final v = d['max_inter_slot_meters'];
        if (v is num && v.toDouble() > bMaxM!) bMaxM = v.toDouble();
      }
    }
    if (bMaxM == 0.0) bMaxM = null;
  }
  if (cDays != null) {
    cMaxM = 0.0;
    for (final d in cDays) {
      if (d is Map) {
        final v = d['max_inter_slot_meters'];
        if (v is num && v.toDouble() > cMaxM!) cMaxM = v.toDouble();
      }
    }
    if (cMaxM == 0.0) cMaxM = null;
  }
  final deltaMaxM = (bMaxM != null && cMaxM != null) ? cMaxM - bMaxM : null;

  final distances = SnapshotDistancesDiff(
    baselineAvgM: bAvgM,
    currentAvgM: cAvgM,
    deltaAvgM: deltaAvgM,
    baselineMaxM: bMaxM,
    currentMaxM: cMaxM,
    deltaMaxM: deltaMaxM,
  );

  // ─── Journées ─────────────────────────────────────────────────────
  final daysByDateB = <String, Map<String, dynamic>>{};
  final daysByDateC = <String, Map<String, dynamic>>{};
  if (bDays != null) {
    for (final d in bDays) {
      if (d is Map && d['date'] is String) {
        daysByDateB[d['date'] as String] =
            Map<String, dynamic>.from(d);
      }
    }
  }
  if (cDays != null) {
    for (final d in cDays) {
      if (d is Map && d['date'] is String) {
        daysByDateC[d['date'] as String] =
            Map<String, dynamic>.from(d);
      }
    }
  }
  final allDates =
      {...daysByDateB.keys, ...daysByDateC.keys}.toList()..sort();
  final byDate = <DayDiff>[];
  final emptyDates = <String>[];
  for (final date in allDates) {
    final b = daysByDateB[date];
    final c = daysByDateC[date];
    final bSlotsD = b == null ? null : (b['total_slots'] as num?)?.toInt();
    final cSlotsD = c == null ? null : (c['total_slots'] as num?)?.toInt();
    final bV = b == null ? null : (b['visits_count'] as num?)?.toInt();
    final cV = c == null ? null : (c['visits_count'] as num?)?.toInt();
    final bMe = b == null ? null : (b['meals_count'] as num?)?.toInt();
    final cMe = c == null ? null : (c['meals_count'] as num?)?.toInt();
    final becameEmpty =
        (bSlotsD ?? 0) > 0 && (cSlotsD == null || cSlotsD == 0);
    if (becameEmpty) emptyDates.add(date);
    byDate.add(DayDiff(
      date: date,
      baselineSlots: bSlotsD,
      currentSlots: cSlotsD,
      baselineVisits: bV,
      currentVisits: cV,
      baselineMeals: bMe,
      currentMeals: cMe,
      becameEmpty: becameEmpty,
    ));
  }
  if (emptyDates.isNotEmpty) {
    warnReasons.add(
        '${emptyDates.length} day(s) became empty: ${emptyDates.join(", ")}');
  }

  final days = SnapshotDaysDiff(byDate: byDate, emptyDates: emptyDates);

  // ─── Verdict global ───────────────────────────────────────────────
  final verdict = failReasons.isNotEmpty
      ? SnapshotVerdict.fail
      : warnReasons.isNotEmpty
          ? SnapshotVerdict.warn
          : SnapshotVerdict.pass;

  return SnapshotComparison(
    baselinePath: baselinePath,
    currentPath: currentPath,
    verdict: verdict,
    failReasons: failReasons,
    warnReasons: warnReasons,
    notes: notes,
    volume: volume,
    scoreDiffs: scoreDiffs,
    places: places,
    distances: distances,
    days: days,
  );
}
