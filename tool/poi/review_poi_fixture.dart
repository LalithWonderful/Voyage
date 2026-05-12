#!/usr/bin/env dart
// POI-1.2 — Script CLI de review de fixture POI.
//
// Usage :
//   dart tool/poi/review_poi_fixture.dart --raw singapore_osm_raw.json --out singapore_reviewed.json
//   dart tool/poi/review_poi_fixture.dart --raw singapore_osm_raw.json --overrides singapore_overrides.json --out singapore_reviewed.json --report report.md

import 'dart:convert';
import 'dart:io';

import 'package:voyage/features/poi/tools/poi_fixture_reviewer.dart';

final _usage = '''
Usage: dart tool/poi/review_poi_fixture.dart --raw <file> --out <file> [options]

Requis :
  --raw <path>      Chemin du fixture brut (JSON).
  --out <path>      Chemin de sortie du fixture reviewé (JSON).

Optionnels :
  --overrides <path>  Chemin du fichier d'overrides manuels (JSON).
  --report <path>     Chemin du rapport qualité (Markdown).
  --json-report <path> Chemin du rapport qualité (JSON).
  --help              Affiche cette aide.

Exemples :
  dart tool/poi/review_poi_fixture.dart --raw singapore_osm_raw.json --out singapore_reviewed.json
  dart tool/poi/review_poi_fixture.dart --raw singapore_osm_raw.json --overrides singapore_overrides.json --out singapore_reviewed.json --report report.md
'''.trim();

void main(List<String> args) async {
  final parser = _parseArgs(args);
  final help = parser['help'] == 'true';

  if (help || parser['raw'] == null || parser['out'] == null) {
    // ignore: avoid_print
    print(_usage);
    exit(help ? 0 : 1);
  }

  final rawPath = parser['raw']!;
  final outPath = parser['out']!;
  final overridesPath = parser['overrides'];
  final reportPath = parser['report'];
  final jsonReportPath = parser['json-report'];

  // ─── Chargement ───
  stderr.writeln('// Chargement du fixture brut : $rawPath');
  final rawFile = File(rawPath);
  if (!rawFile.existsSync()) {
    stderr.writeln('ERREUR: Fichier introuvable: $rawPath');
    exit(2);
  }
  final rawJson = json.decode(rawFile.readAsStringSync()) as Map<String, dynamic>;

  Map<String, PoiOverride>? overrides;
  if (overridesPath != null) {
    stderr.writeln('// Chargement des overrides : $overridesPath');
    final ovFile = File(overridesPath);
    if (ovFile.existsSync()) {
      final ovJson = json.decode(ovFile.readAsStringSync()) as Map<String, dynamic>;
      overrides = PoiFixtureReviewer.loadOverrides(ovJson);
      stderr.writeln('//   Overrides chargés : ${overrides.length}');
    } else {
      stderr.writeln('//   Fichier non trouvé, pas d\'overrides');
    }
  }

  // ─── Review ───
  stderr.writeln('// Review en cours...');
  final reviewer = PoiFixtureReviewer(
    rawFixture: rawJson,
    overrides: overrides,
  );

  final reviewed = reviewer.buildReviewedFixture();
  final report = reviewer.generateQualityReport();

  // ─── Écriture fixture reviewed ───
  stderr.writeln('// POI reviewés : ${report.reviewedPois} / ${report.totalPois}');
  stderr.writeln('// POI supprimés : ${report.removedPois}');
  stderr.writeln('// Problèmes détectés : ${report.issues.length}');
  if (report.errors.isNotEmpty) {
    stderr.writeln('//   Erreurs : ${report.errors.length}');
  }
  if (report.warnings.isNotEmpty) {
    stderr.writeln('//   Warnings : ${report.warnings.length}');
  }

  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');
  outFile.writeAsStringSync(encoder.convert(reviewed));
  stderr.writeln('// Fixture reviewé écrit : $outPath');

  // ─── Écriture rapports ───
  if (reportPath != null) {
    final reportFile = File(reportPath);
    reportFile.parent.createSync(recursive: true);
    reportFile.writeAsStringSync(report.toMarkdown());
    stderr.writeln('// Rapport Markdown écrit : $reportPath');
  }

  if (jsonReportPath != null) {
    final jsonReportFile = File(jsonReportPath);
    jsonReportFile.parent.createSync(recursive: true);
    jsonReportFile.writeAsStringSync(encoder.convert(report.toJson()));
    stderr.writeln('// Rapport JSON écrit : $jsonReportPath');
  }

  // ─── Exit code ───
  if (report.errors.isNotEmpty) {
    stderr.writeln('// ⚠️ Des erreurs ont été détectées (voir rapport).');
    exit(3);
  }
}

Map<String, String?> _parseArgs(List<String> args) {
  final result = <String, String?>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--help':
        result['help'] = 'true';
      case '--raw':
      case '--out':
      case '--overrides':
      case '--report':
      case '--json-report':
        if (i + 1 < args.length) {
          result[arg.substring(2)] = args[++i];
        }
    }
  }
  return result;
}
