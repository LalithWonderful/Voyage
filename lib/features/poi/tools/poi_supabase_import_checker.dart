// POI-1.4 — Post-import verification helper (read-only).
//
// Checks Supabase DB state for a given destination after a POI import.
// Lightweight abstraction over the query layer to keep tests simple.

import 'package:supabase/supabase.dart';

/// Minimal read-only interface for querying POI tables.
///
/// A Supabase implementation and a fake in-memory implementation are provided
/// below. This avoids heavy mocking of `SupabaseClient` in tests.
abstract class PoiImportCheckReader {
  /// Returns the number of rows in [table] matching optional [eqFilters].
  Future<int> count(String table, {Map<String, dynamic>? eqFilters});

  /// Returns selected rows from [table].
  ///
  /// [columns] defaults to all columns (`['*']`).
  /// [eqFilters] applies `.eq()` filters for each key/value pair.
  Future<List<Map<String, dynamic>>> select(
    String table, {
    List<String> columns,
    Map<String, dynamic>? eqFilters,
  });
}

/// Report produced by [PoiSupabaseImportChecker].
class PoiImportCheckReport {
  final String destinationKey;
  final int poiCount;
  final int aliasCount;
  final int linkCount;
  final int tagCount;
  final int flagCount;
  final List<String> anomalies;
  final bool isHealthy;

  const PoiImportCheckReport({
    required this.destinationKey,
    required this.poiCount,
    required this.aliasCount,
    required this.linkCount,
    required this.tagCount,
    required this.flagCount,
    required this.anomalies,
    required this.isHealthy,
  });

  Map<String, dynamic> toJson() => {
        'destination_key': destinationKey,
        'poi_count': poiCount,
        'alias_count': aliasCount,
        'link_count': linkCount,
        'tag_count': tagCount,
        'flag_count': flagCount,
        'is_healthy': isHealthy,
        'anomalies': anomalies,
      };

  @override
  String toString() {
    final buf = StringBuffer()
      ..writeln('=== POI Import Check: $destinationKey ===')
      ..writeln('POIs      : $poiCount')
      ..writeln('Aliases   : $aliasCount')
      ..writeln('Links     : $linkCount')
      ..writeln('Tags      : $tagCount')
      ..writeln('Flags     : $flagCount')
      ..writeln('Healthy   : $isHealthy');
    if (anomalies.isNotEmpty) {
      buf.writeln('Anomalies : ${anomalies.length}');
      for (final a in anomalies) {
        buf.writeln('  [ANOMALY] $a');
      }
    }
    return buf.toString();
  }
}

/// Read-only checker for post-import validation.
///
/// Queries table counts and detects duplicate aliases, tags, quality flags,
/// and source links for a specific destination.
class PoiSupabaseImportChecker {
  final PoiImportCheckReader _reader;

  PoiSupabaseImportChecker(this._reader);

  /// Validates the DB state for [destinationKey].
  Future<PoiImportCheckReport> checkDestination(String destinationKey) async {
    // ─── Count POIs ───
    final poiCount = await _reader.count(
      'pois',
      eqFilters: {'destination_key': destinationKey},
    );

    // ─── Gather local POI ids ───
    final poiRows = await _reader.select(
      'pois',
      columns: ['poi_id'],
      eqFilters: {'destination_key': destinationKey},
    );
    final poiIds = poiRows.map((r) => r['poi_id'] as String).toSet();

    // ─── Child counts (client-side filter) ───
    Future<int> _localChildCount(String table) async {
      final rows = await _reader.select(table);
      return rows.where((r) => poiIds.contains(r['poi_id'])).length;
    }

    final aliasCount = await _localChildCount('poi_aliases');
    final linkCount = await _localChildCount('poi_source_links');
    final tagCount = await _localChildCount('poi_tags');
    final flagCount = await _localChildCount('poi_quality_flags');

    // ─── Anomaly detection ───
    final anomalies = <String>[];

    // Duplicate aliases
    final aliases = await _reader.select('poi_aliases');
    final localAliases = aliases.where((a) => poiIds.contains(a['poi_id']));
    final aliasKeys = <String>{};
    for (final alias in localAliases) {
      final key = '${alias['poi_id']}|${alias['alias_normalized']}';
      if (!aliasKeys.add(key)) {
        anomalies.add('Duplicate alias "$key"');
      }
    }

    // POIs without canonical alias
    final canonicalAliasPoiIds = localAliases
        .where((a) => a['is_canonical'] == true)
        .map((a) => a['poi_id'] as String)
        .toSet();
    for (final poiId in poiIds) {
      if (!canonicalAliasPoiIds.contains(poiId)) {
        anomalies.add('POI $poiId has no canonical alias');
      }
    }

    // Duplicate tags
    final tags = await _reader.select('poi_tags');
    final localTags = tags.where((t) => poiIds.contains(t['poi_id']));
    final tagKeys = <String>{};
    for (final tag in localTags) {
      final key = '${tag['poi_id']}|${tag['tag']}';
      if (!tagKeys.add(key)) {
        anomalies.add('Duplicate tag "$key"');
      }
    }

    // Duplicate quality flags
    final flags = await _reader.select('poi_quality_flags');
    final localFlags = flags.where((f) => poiIds.contains(f['poi_id']));
    final flagKeys = <String>{};
    for (final flag in localFlags) {
      final key = '${flag['poi_id']}|${flag['flag_type']}|${flag['flag_reason']}';
      if (!flagKeys.add(key)) {
        anomalies.add('Duplicate quality flag "$key"');
      }
    }

    // Duplicate source links
    final links = await _reader.select('poi_source_links');
    final localLinks = links.where((l) => poiIds.contains(l['poi_id']));
    final linkKeys = <String>{};
    for (final link in localLinks) {
      final key =
          '${link['poi_id']}|${link['source_id']}|${link['source_poi_identifier']}';
      if (!linkKeys.add(key)) {
        anomalies.add('Duplicate source link "$key"');
      }
    }

    return PoiImportCheckReport(
      destinationKey: destinationKey,
      poiCount: poiCount,
      aliasCount: aliasCount,
      linkCount: linkCount,
      tagCount: tagCount,
      flagCount: flagCount,
      anomalies: anomalies,
      isHealthy: anomalies.isEmpty,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Implementations
// ═══════════════════════════════════════════════════════════════════

/// [PoiImportCheckReader] backed by a real Supabase client.
class SupabasePoiImportCheckReader implements PoiImportCheckReader {
  final SupabaseClient _client;

  SupabasePoiImportCheckReader(this._client);

  @override
  Future<int> count(String table, {Map<String, dynamic>? eqFilters}) async {
    final rows = await select(table, eqFilters: eqFilters);
    return rows.length;
  }

  @override
  Future<List<Map<String, dynamic>>> select(
    String table, {
    List<String> columns = const ['*'],
    Map<String, dynamic>? eqFilters,
  }) async {
    final columnsStr = columns.length == 1 ? columns.first : columns.join(',');
    var query = _client.from(table).select(columnsStr);
    eqFilters?.forEach((k, v) {
      query = query.eq(k, v);
    });
    final resp = await query;
    return List<Map<String, dynamic>>.from(resp);
  }
}
