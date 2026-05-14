import 'dart:convert';
import 'dart:io';

import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

void main() {
  final validator = PoiFixtureValidator();
  var allValid = true;
  var totalPois = 0;

  final newCities = [
    'istanbul', 'cairo', 'bangkok', 'tokyo', 'singapore',
    'madrid', 'vienna', 'prague', 'berlin', 'dublin',
    'edinburgh', 'athens', 'venice', 'florence', 'new-york', 'dubai'
  ];

  for (final city in newCities) {
    final path = 'test/fixtures/poi/pilot_pois_$city.json';
    final file = File(path);
    if (!file.existsSync()) {
      print('=== $city === MISSING');
      allValid = false;
      continue;
    }
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final report = validator.validate(json);
    print('=== $city ===');
    print('  POIs: ${report.stats.poiCount}, Valid: ${report.isValid}, '
        'Errors: ${report.errors.length}, Warnings: ${report.warnings.length}');
    if (report.errors.isNotEmpty) {
      for (final e in report.errors) {
        print('  [ERR] $e');
      }
    }
    if (report.warnings.isNotEmpty) {
      for (final w in report.warnings) {
        print('  [WARN] $w');
      }
    }
    print('');
    if (!report.isValid) allValid = false;
    totalPois += report.stats.poiCount;
  }

  print('=== Summary ===');
  print('Cities checked: ${newCities.length}');
  print('Total POIs: $totalPois');
  print('All valid: $allValid');

  if (!allValid) exit(1);
}
