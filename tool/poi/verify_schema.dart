// POI-1.6 — Verify that the 6 POI tables exist in Supabase.
// Reads credentials from SupabaseConstants (no CLI secrets).

import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:voyage/core/constants/supabase_constants.dart';

void main() async {
  final client = SupabaseClient(
    SupabaseConstants.supabaseUrl,
    SupabaseConstants.supabaseAnonKey,
  );

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
    stdout.writeln('\nSome tables are missing. Apply supabase/sql/poi_knowledge_base.sql first.');
    exit(1);
  }
}
