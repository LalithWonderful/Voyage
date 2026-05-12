// POI-0.4 — Validateur de contrat entre un PoiStagingPlan et le schéma SQL.
//
// Vérifie offline (aucune DB) que le plan d'insertion généré par
// PoiStagingImporter respecte le contrat du DDL Supabase :
// - tables et colonnes existent
// - NOT NULL respectés
// - types compatibles
// - CHECK constraints satisfaites
// - contraintes d'unicité non violées
// - ordre d'insertion cohérent avec les FK
//
// Aucun appel réseau. Aucun Supabase.

library;

import 'poi_sql_schema_parser.dart';
import 'package:voyage/features/poi/tools/poi_staging_importer.dart';

/// Rapport de validation du contrat SQL.
class PoiSqlContractReport {
  final List<String> errors;
  final List<String> warnings;
  bool get isValid => errors.isEmpty;

  const PoiSqlContractReport({
    required this.errors,
    required this.warnings,
  });

  Map<String, dynamic> toJson() => {
    'valid': isValid,
    'error_count': errors.length,
    'warning_count': warnings.length,
    'errors': errors,
    'warnings': warnings,
  };
}

/// Valide un [PoiStagingPlan] contre un [SqlSchema] parsé.
class PoiSqlContractValidator {
  final SqlSchema schema;

  const PoiSqlContractValidator(this.schema);

  PoiSqlContractReport validate(PoiStagingPlan plan) {
    final errors = <String>[];
    final warnings = <String>[];

    // ─── 1. Tables attendues ───
    const expectedTables = [
      'poi_sources',
      'pois',
      'poi_aliases',
      'poi_source_links',
      'poi_tags',
      'poi_quality_flags',
    ];
    for (final tableName in expectedTables) {
      if (!schema.tables.containsKey(tableName)) {
        errors.add('Schema missing table: $tableName');
      }
    }

    // ─── 2. Validation ligne par ligne ───
    _validateRows('poi_sources', plan.poiSources, errors, warnings);
    _validateRows('pois', plan.pois, errors, warnings);
    _validateRows('poi_aliases', plan.poiAliases, errors, warnings);
    _validateRows('poi_source_links', plan.poiSourceLinks, errors, warnings);
    _validateRows('poi_tags', plan.poiTags, errors, warnings);
    _validateRows('poi_quality_flags', plan.poiQualityFlags, errors, warnings);

    // ─── 3. Contraintes d'unicité SQL ───
    _validateUniqueConstraints(plan, errors);

    // ─── 4. Ordre d'insertion (FK) ───
    _validateInsertionOrder(plan, errors);

    return PoiSqlContractReport(errors: errors, warnings: warnings);
  }

  // ───────────────────────────────────────────────
  // Validation par table
  // ───────────────────────────────────────────────

  void _validateRows(
    String tableName,
    List<Map<String, dynamic>> rows,
    List<String> errors,
    List<String> warnings,
  ) {
    final table = schema.tables[tableName];
    if (table == null) return;

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final prefix = '$tableName[$i]';

      // a) Toutes les clés du row doivent exister en SQL
      for (final key in row.keys) {
        if (!table.columns.containsKey(key)) {
          errors.add('$prefix: column "$key" not found in SQL schema');
        }
      }

      // b) NOT NULL sans default → obligatoire
      for (final col in table.columns.values) {
        if (!col.isNullable && !col.hasDefault) {
          if (!row.containsKey(col.name) || row[col.name] == null) {
            errors.add(
              '$prefix: NOT NULL column "${col.name}" missing or null',
            );
          }
        }
      }

      // c) Compatibilité de type
      for (final entry in row.entries) {
        final col = table.columns[entry.key];
        if (col == null) continue;
        final value = entry.value;
        if (value == null) continue;
        if (!_isTypeCompatible(value, col.type)) {
          errors.add(
            '$prefix: type mismatch for "${entry.key}": '
            'Dart ${value.runtimeType} vs SQL ${col.type}',
          );
        }
      }

      // d) CHECK constraints
      for (final check in table.checkConstraints) {
        if (check.expression != null) {
          if (!_evaluateCheck(check.expression!, row)) {
            errors.add(
              '$prefix: CHECK violated: ${check.expression}',
            );
          }
        }
      }
    }
  }

  // ───────────────────────────────────────────────
  // Type compatibility
  // ───────────────────────────────────────────────

  bool _isTypeCompatible(dynamic value, String sqlType) {
    switch (sqlType) {
      case 'uuid':
      case 'text':
        return value is String;
      case 'integer':
        return value is int;
      case 'boolean':
        return value is bool;
      case 'double':
      case 'double precision':
        return value is double || value is int;
      case 'timestamptz':
      case 'timestamp':
        return value is String || value is DateTime;
      case 'jsonb':
      case 'json':
        return value is Map<String, dynamic> || value is List<dynamic>;
      default:
        return true;
    }
  }

  // ───────────────────────────────────────────────
  // CHECK evaluator (limité au sous-ensemble POI)
  // ───────────────────────────────────────────────

  bool _evaluateCheck(String expression, Map<String, dynamic> row) {
    final lower = expression.toLowerCase().trim();
    //

    // col is null or (col >= min and col <= max)
    final nullOrRange = RegExp(
      r"^(\w+)\s+is\s+null\s+or\s*\(\s*\1\s*>=\s*(-?\d+(?:\.\d+)?)\s+and\s+\1\s*<=\s*(-?\d+(?:\.\d+)?)\s*\)$",
      caseSensitive: false,
    ).firstMatch(lower);
    if (nullOrRange != null) {
      final col = nullOrRange.group(1)!;
      final min = num.parse(nullOrRange.group(2)!);
      final max = num.parse(nullOrRange.group(3)!);
      final value = row[col];
      if (value == null) return true;
      final n = _toNum(value);
      return n != null && n >= min && n <= max;
    }

    // col >= min and col <= max
    final range = RegExp(
      r"^(\w+)\s*>=\s*(-?\d+(?:\.\d+)?)\s+and\s+\1\s*<=\s*(-?\d+(?:\.\d+)?)$",
      caseSensitive: false,
    ).firstMatch(lower);
    if (range != null) {
      final col = range.group(1)!;
      final min = num.parse(range.group(2)!);
      final max = num.parse(range.group(3)!);
      final value = row[col];
      if (value == null) return true;
      final n = _toNum(value);
      return n != null && n >= min && n <= max;
    }

    // col is null or col > min
    final nullOrGt = RegExp(
      r"^(\w+)\s+is\s+null\s+or\s+\1\s*>\s*(-?\d+(?:\.\d+)?)$",
      caseSensitive: false,
    ).firstMatch(lower);
    if (nullOrGt != null) {
      final col = nullOrGt.group(1)!;
      final min = num.parse(nullOrGt.group(2)!);
      final value = row[col];
      if (value == null) return true;
      final n = _toNum(value);
      return n != null && n > min;
    }

    // col in ('a', 'b', 'c')
    final inList = RegExp(
      r"^(\w+)\s+in\s*\(\s*((?:'[^']*'(?:\s*,\s*'[^']*')*))\s*\)$",
      caseSensitive: false,
    ).firstMatch(lower);
    if (inList != null) {
      final col = inList.group(1)!;
      final valuesStr = inList.group(2)!;
      final allowed = RegExp(r"'([^']*)'")
          .allMatches(valuesStr)
          .map((m) => m.group(1)!)
          .toSet();
      final value = row[col];
      if (value == null) return true;
      return allowed.contains(value);
    }

    // Check non supporté → ne pas bloquer
    return true;
  }

  num? _toNum(dynamic value) {
    if (value is num) return value;
    return null;
  }

  // ───────────────────────────────────────────────
  // Unique constraints
  // ───────────────────────────────────────────────

  void _validateUniqueConstraints(
    PoiStagingPlan plan,
    List<String> errors,
  ) {
    final tableMap = <String, List<Map<String, dynamic>>>{
      'poi_sources': plan.poiSources,
      'pois': plan.pois,
      'poi_aliases': plan.poiAliases,
      'poi_source_links': plan.poiSourceLinks,
      'poi_tags': plan.poiTags,
      'poi_quality_flags': plan.poiQualityFlags,
    };

    for (final entry in schema.tables.entries) {
      final tableName = entry.key;
      final table = entry.value;
      final rows = tableMap[tableName] ?? [];

      for (final unique in table.uniqueConstraints) {
        final seen = <String>{};
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          final key = unique.columns.map((c) {
            // Support limité : coalesce(col, '')
            final coalesceMatch = RegExp(
              r"coalesce\((\w+)\s*,\s*''\)",
              caseSensitive: false,
            ).firstMatch(c);
            if (coalesceMatch != null) {
              final colName = coalesceMatch.group(1)!;
              final val = row[colName];
              return val == null ? '' : '$val';
            }
            return '${row[c]}';
          }).join('|');

          if (!seen.add(key)) {
            errors.add(
              '$tableName[$i]: violates unique constraint '
              '(${unique.columns.join(', ')})',
            );
          }
        }
      }
    }
  }

  // ───────────────────────────────────────────────
  // Ordre d'insertion (FK)
  // ───────────────────────────────────────────────

  void _validateInsertionOrder(
    PoiStagingPlan plan,
    List<String> errors,
  ) {
    const tableOrder = [
      'poi_sources',
      'pois',
      'poi_aliases',
      'poi_source_links',
      'poi_tags',
      'poi_quality_flags',
    ];

    final deps = <String, Set<String>>{};
    for (final table in schema.tables.values) {
      for (final fk in table.foreignKeys) {
        if (fk.referenceTable != null) {
          deps.putIfAbsent(table.name, () => {}).add(fk.referenceTable!);
        }
      }
    }

    for (var i = 0; i < tableOrder.length; i++) {
      final table = tableOrder[i];
      final tableDeps = deps[table] ?? {};
      for (final dep in tableDeps) {
        final depIndex = tableOrder.indexOf(dep);
        if (depIndex == -1) {
          errors.add(
            'Insertion order: dependency "$dep" not found in plan for "$table"',
          );
        } else if (depIndex >= i) {
          errors.add(
            'Insertion order: "$table" (index $i) must come after '
            '"$dep" (index $depIndex)',
          );
        }
      }
    }
  }
}
