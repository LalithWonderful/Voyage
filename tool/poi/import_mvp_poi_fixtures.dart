import 'dart:io';

import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/poi/tools/mvp_poi_fixture_importer.dart';

Future<void> main(List<String> args) async {
  late final MvpPoiFixtureImportOptions options;
  try {
    options = MvpPoiFixtureImportOptions.fromArgs(args);
  } on MvpPoiFixtureImportException catch (e) {
    stderr.writeln(e.message);
    exit(e.message.startsWith('Usage:') ? 0 : 1);
  }

  final importer = MvpPoiFixtureImporter(
    guards: LiveApiGuards.fromEnvironment(),
  );

  try {
    final run = await importer.run(options);
    stdout.writeln(run.summaryText());
  } on LiveApiBlockedException catch (e) {
    stderr.writeln('ERROR: $e');
    exit(2);
  } on MvpPoiFixtureImportException catch (e) {
    stderr.writeln('ERROR: ${e.message}');
    exit(1);
  }
}
