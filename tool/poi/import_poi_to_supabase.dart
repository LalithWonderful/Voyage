// POI-1.3 — CLI d'import contrôlé d'un fixture POI vers Supabase.
//
// Usage :
//   dart run tool/poi/import_poi_to_supabase.dart <fixture.json>
//
// Dry-run par défaut. Pour écrire :
//   dart run --define=ALLOW_POI_SUPABASE_WRITE=true \
//            --define=SUPABASE_URL=<url> \
//            --define=SUPABASE_SECRET_KEY=<key> \
//            tool/poi/import_poi_to_supabase.dart <fixture.json> --write
//
// Le fixture doit avoir été revu (PoiFixtureReviewer) avant import.

import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:voyage/features/poi/tools/poi_supabase_importer.dart';

const bool _allowWrite = bool.fromEnvironment(
  'ALLOW_POI_SUPABASE_WRITE',
  defaultValue: false,
);

void main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(1);
  }

  final fixturePath = args.first;
  final dryRun = !args.contains('--write');

  if (!dryRun && !_allowWrite) {
    stderr.writeln(
      'ERROR: --write requires ALLOW_POI_SUPABASE_WRITE=true.\n'
      'Run with: dart run --define=ALLOW_POI_SUPABASE_WRITE=true ...',
    );
    exit(1);
  }

  final file = File(fixturePath);
  if (!file.existsSync()) {
    stderr.writeln('ERROR: Fixture not found: $fixturePath');
    exit(1);
  }

  final fixtureJson = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

  SupabaseClient? client;
  if (!dryRun) {
    final supabaseUrl = const String.fromEnvironment('SUPABASE_URL');
    final supabaseSecretKey = const String.fromEnvironment('SUPABASE_SECRET_KEY');
    final supabaseServiceRoleKey = const String.fromEnvironment('SUPABASE_SERVICE_ROLE_KEY');
    final supabaseAnonKey = const String.fromEnvironment('SUPABASE_ANON_KEY');
    final writeKey = supabaseSecretKey.isNotEmpty
        ? supabaseSecretKey
        : (supabaseServiceRoleKey.isNotEmpty ? supabaseServiceRoleKey : supabaseAnonKey);

    if (supabaseUrl.isEmpty || writeKey.isEmpty) {
      stderr.writeln(
        'ERROR: SUPABASE_URL and a write key (SUPABASE_SECRET_KEY, SUPABASE_SERVICE_ROLE_KEY, '
        'or SUPABASE_ANON_KEY) must be set for real writes.\n'
        'Run with: dart run --define=SUPABASE_URL=<url> '
        '--define=SUPABASE_SECRET_KEY=<key> ...',
      );
      exit(1);
    }

    client = SupabaseClient(supabaseUrl, writeKey);
  }

  final importer = PoiSupabaseImporter(client: client);

  try {
    final report = await importer.import(fixtureJson, dryRun: dryRun);
    stdout.writeln(report.toString());

    if (!report.canProceed) {
      exit(1);
    }
  } finally {
    client?.dispose();
  }
}

void _usage() {
  stdout.writeln('''
Usage: dart run tool/poi/import_poi_to_supabase.dart <fixture.json> [--write]

Options:
  --write    Execute real Supabase upserts (requires ALLOW_POI_SUPABASE_WRITE=true)

Environment:
  SUPABASE_URL              Supabase project URL
  SUPABASE_SECRET_KEY       Supabase secret key (preferred for writes)
  SUPABASE_SERVICE_ROLE_KEY Fallback service role key for writes
  SUPABASE_ANON_KEY         Fallback anonymous key for writes
''');
}
