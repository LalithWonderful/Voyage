import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:voyage/features/poi/tools/poi_supabase_importer.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/poi/run_pilot_import.dart <fixture.json> [--write]');
    stderr.writeln('');
    stderr.writeln('For real writes, provide secret key (preferred) or service role key:');
    stderr.writeln('  dart run --define=SUPABASE_URL=<url> --define=SUPABASE_SECRET_KEY=<key> ...');
    stderr.writeln('  dart run --define=SUPABASE_URL=<url> --define=SUPABASE_SERVICE_ROLE_KEY=<key> ...');
    exit(1);
  }

  final fixturePath = args.first;
  final dryRun = !args.contains('--write');

  final file = File(fixturePath);
  if (!file.existsSync()) {
    stderr.writeln('Fixture not found: $fixturePath');
    exit(1);
  }

  final fixtureJson = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

  final supabaseUrl = const String.fromEnvironment('SUPABASE_URL');
  final supabaseSecretKey = const String.fromEnvironment('SUPABASE_SECRET_KEY');
  final supabaseServiceRoleKey = const String.fromEnvironment('SUPABASE_SERVICE_ROLE_KEY');
  final writeKey = supabaseSecretKey.isNotEmpty ? supabaseSecretKey : supabaseServiceRoleKey;

  if (!dryRun && (supabaseUrl.isEmpty || writeKey.isEmpty)) {
    stderr.writeln('ERROR: SUPABASE_URL and a write key (SUPABASE_SECRET_KEY or SUPABASE_SERVICE_ROLE_KEY) must be set for real writes.');
    stderr.writeln('Run with: dart run --define=SUPABASE_URL=<url> --define=SUPABASE_SECRET_KEY=<key> ...');
    exit(1);
  }

  final client = SupabaseClient(
    supabaseUrl.isNotEmpty ? supabaseUrl : 'https://placeholder.supabase.co',
    writeKey.isNotEmpty ? writeKey : 'placeholder',
  );
  final importer = PoiSupabaseImporter(client: client);

  try {
    final report = await importer.import(fixtureJson, dryRun: dryRun);
    stdout.writeln(report.toString());
    if (!report.canProceed) exit(1);
  } finally {
    client.dispose();
  }
}
