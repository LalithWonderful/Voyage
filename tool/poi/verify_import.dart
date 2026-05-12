// POI-1.6 — Post-import verification for a destination.
// Read-only; uses secret key (preferred) or anon key.
//
// Usage:
//   dart run --define=SUPABASE_URL=<url> --define=SUPABASE_SECRET_KEY=<key> \
//       tool/poi/verify_import.dart [--destination lisbon]
//   dart run --define=SUPABASE_URL=<url> --define=SUPABASE_ANON_KEY=<key> \
//       tool/poi/verify_import.dart [--destination lisbon]

import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:voyage/features/poi/tools/poi_supabase_import_checker.dart';

void main(List<String> args) async {
  final destination = _argValue(args, '--destination') ?? 'lisbon';

  final url = const String.fromEnvironment('SUPABASE_URL');
  final secretKey = const String.fromEnvironment('SUPABASE_SECRET_KEY');
  final anonKey = const String.fromEnvironment('SUPABASE_ANON_KEY');
  final readKey = secretKey.isNotEmpty ? secretKey : anonKey;

  if (url.isEmpty || readKey.isEmpty) {
    stderr.writeln(
      'ERROR: SUPABASE_URL and a read key (SUPABASE_SECRET_KEY or SUPABASE_ANON_KEY) '
      'must be provided via --define.',
    );
    stderr.writeln(
      '  dart run --define=SUPABASE_URL=<url> --define=SUPABASE_SECRET_KEY=<key> '
      'tool/poi/verify_import.dart [--destination <key>]',
    );
    exit(1);
  }

  final client = SupabaseClient(url, readKey);
  final reader = SupabasePoiImportCheckReader(client);
  final checker = PoiSupabaseImportChecker(reader);

  try {
    final report = await checker.checkDestination(destination);
    stdout.writeln(report.toString());
    exit(report.isHealthy ? 0 : 1);
  } finally {
    await client.dispose();
  }
}

String? _argValue(List<String> args, String key) {
  final idx = args.indexOf(key);
  if (idx != -1 && idx + 1 < args.length) return args[idx + 1];
  return null;
}
