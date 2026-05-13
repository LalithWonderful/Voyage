// POI-1.6 / POI-1.7 — Verify that the 6 POI tables exist in Supabase.
// Prefers SUPABASE_SECRET_KEY or SUPABASE_ANON_KEY from --define.
// Falls back to SupabaseConstants only if env vars are not provided.

import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:supabase/supabase.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/core/constants/supabase_constants.dart';
import 'package:voyage/features/poi/tools/supabase_live_guard.dart';

void main() async {
  try {
    assertLiveSupabaseAllowedForPoiTool(operation: poiVerifySchemaOperation);
  } on LiveApiBlockedException catch (e) {
    stderr.writeln('ERROR: $e');
    exit(2);
  }

  final secretKey = const String.fromEnvironment('SUPABASE_SECRET_KEY');
  final anonKey = const String.fromEnvironment('SUPABASE_ANON_KEY');
  final readKey = secretKey.isNotEmpty
      ? secretKey
      : (anonKey.isNotEmpty ? anonKey : SupabaseConstants.supabaseAnonKey);

  final client = SupabaseClient(SupabaseConstants.supabaseUrl, readKey);

  final requiredTables = [
    'poi_sources',
    'pois',
    'poi_aliases',
    'poi_source_links',
    'poi_tags',
    'poi_quality_flags',
  ];

  var allExist = true;
  for (final table in requiredTables) {
    try {
      await client.from(table).select().limit(1);
      stdout.writeln('✅ $table');
    } catch (e) {
      stdout.writeln('❌ $table — $e');
      allExist = false;
    }
  }

  await client.dispose();

  if (allExist) {
    stdout.writeln('\nAll 6 POI tables are present.');
  } else {
    stdout.writeln(
      '\nSome tables are missing. Apply supabase/sql/poi_knowledge_base.sql first.',
    );
    exit(1);
  }
}
