import 'dart:convert';
import 'dart:io';

import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

void main() {
  final validator = PoiFixtureValidator();
  var allValid = true;

  for (final city in ['london', 'amsterdam', 'marrakech']) {
    final path = 'test/fixtures/poi/pilot_pois_$city.json';
    final file = File(path);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final report = validator.validate(json);
    print('=== $city ===');
    print(report);
    print('');
    if (!report.isValid) allValid = false;
  }

  if (!allValid) exit(1);
}
