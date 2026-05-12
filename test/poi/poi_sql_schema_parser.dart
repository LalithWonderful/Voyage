// POI-0.4 — Parser SQL offline pour le DDL POI.
//
// Pas un parser SQL généraliste. Gère uniquement le sous-ensemble
// utilisé par `supabase/sql/poi_knowledge_base.sql` :
//   - CREATE TABLE … (colonnes + contraintes table-level)
//   - types simples (uuid, text, integer, boolean, double precision,
//     timestamptz, jsonb)
//   - NOT NULL, DEFAULT, PRIMARY KEY inline
//   - contraintes table-level : PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK
//
// Aucune connexion réseau. Aucun Supabase.

library;

/// Schéma SQL parsé (ensemble des tables).
class SqlSchema {
  final Map<String, SqlTable> tables;
  const SqlSchema({required this.tables});

  SqlTable? table(String name) => tables[name];
}

/// Table SQL avec ses colonnes et contraintes.
class SqlTable {
  final String name;
  final Map<String, SqlColumn> columns;
  final List<SqlTableConstraint> constraints;

  const SqlTable({
    required this.name,
    required this.columns,
    required this.constraints,
  });

  SqlColumn? column(String name) => columns[name];

  List<SqlTableConstraint> get primaryKeys =>
      constraints.where((c) => c.kind == 'primary_key').toList();

  List<SqlTableConstraint> get foreignKeys =>
      constraints.where((c) => c.kind == 'foreign_key').toList();

  List<SqlTableConstraint> get uniqueConstraints =>
      constraints.where((c) => c.kind == 'unique').toList();

  List<SqlTableConstraint> get checkConstraints =>
      constraints.where((c) => c.kind == 'check').toList();
}

/// Colonne SQL.
class SqlColumn {
  final String name;
  final String type;
  final bool isNullable;
  final String? defaultValue;

  const SqlColumn({
    required this.name,
    required this.type,
    this.isNullable = true,
    this.defaultValue,
  });

  bool get hasDefault => defaultValue != null && defaultValue!.isNotEmpty;
}

/// Contrainte table-level.
class SqlTableConstraint {
  final String? name;
  final String kind; // primary_key, foreign_key, unique, check
  final List<String> columns;
  final String? referenceTable;
  final String? referenceColumns;
  final String? expression; // pour CHECK

  const SqlTableConstraint({
    this.name,
    required this.kind,
    required this.columns,
    this.referenceTable,
    this.referenceColumns,
    this.expression,
  });
}

/// Parseur léger du DDL POI.
class PoiSqlSchemaParser {
  SqlSchema parse(String sql) {
    final tables = <String, SqlTable>{};
    final cleanSql = _removeComments(sql);

    final tableRegex = RegExp(
      r'create\s+table\s+if\s+not\s+exists\s+public\.(\w+)\s*\((.*?)\);',
      caseSensitive: false,
      dotAll: true,
    );

    for (final match in tableRegex.allMatches(cleanSql)) {
      final tableName = match.group(1)!;
      final body = match.group(2)!;
      tables[tableName] = _parseTable(tableName, body);
    }

    return SqlSchema(tables: tables);
  }

  // ─── Nettoyage ───

  String _removeComments(String sql) {
    var result = sql.replaceAllMapped(
      RegExp(r'--.*$', multiLine: true),
      (m) => '',
    );
    result = result.replaceAllMapped(
      RegExp(r'/\*.*?\*/', dotAll: true),
      (m) => '',
    );
    return result;
  }

  // ─── Parsing table ───

  SqlTable _parseTable(String name, String body) {
    final columns = <String, SqlColumn>{};
    final constraints = <SqlTableConstraint>[];

    final items = _splitSqlItems(body);
    for (final item in items) {
      final trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      final lower = trimmed.toLowerCase();
      if (lower.startsWith('constraint ') ||
          lower.startsWith('primary key ') ||
          lower.startsWith('foreign key ') ||
          lower.startsWith('unique ') ||
          lower.startsWith('check ')) {
        constraints.add(_parseTableConstraint(trimmed));
      } else {
        final col = _parseColumn(trimmed);
        if (col != null) {
          columns[col.name] = col;
          // Inline primary key → contrainte table-level
          if (lower.contains('primary key')) {
            constraints.add(SqlTableConstraint(
              kind: 'primary_key',
              columns: [col.name],
            ));
          }
          // Inline unique
          if (RegExp(r'\bunique\b').hasMatch(lower)) {
            constraints.add(SqlTableConstraint(
              kind: 'unique',
              columns: [col.name],
            ));
          }
          // Inline references
          final refMatch = RegExp(
            r'references\s+(?:public\.)?(\w+)\s*\(([^)]+)\)',
            caseSensitive: false,
          ).firstMatch(trimmed);
          if (refMatch != null) {
            constraints.add(SqlTableConstraint(
              kind: 'foreign_key',
              columns: [col.name],
              referenceTable: refMatch.group(1),
              referenceColumns: refMatch.group(2),
            ));
          }
        }
      }
    }

    return SqlTable(name: name, columns: columns, constraints: constraints);
  }

  // ─── Split items (respecte parenthèses) ───

  List<String> _splitSqlItems(String body) {
    final items = <String>[];
    var depth = 0;
    final current = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch == '(') {
        depth++;
        current.write(ch);
      } else if (ch == ')') {
        depth--;
        current.write(ch);
      } else if (ch == ',' && depth == 0) {
        items.add(current.toString().trim());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    final last = current.toString().trim();
    if (last.isNotEmpty) items.add(last);
    return items;
  }

  // ─── Parsing colonne ───

  SqlColumn? _parseColumn(String def) {
    // double precision (2 mots)
    final dpMatch = RegExp(
      r'^(\w+)\s+double\s+precision\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(def);
    if (dpMatch != null) {
      return _buildColumn(
        dpMatch.group(1)!,
        'double precision',
        dpMatch.group(2)!,
      );
    }

    // Cas général : nom type [reste]
    final match = RegExp(r'^(\w+)\s+(\S+)\s*(.*)$').firstMatch(def);
    if (match == null) return null;

    return _buildColumn(
      match.group(1)!,
      match.group(2)!.toLowerCase(),
      match.group(3)!,
    );
  }

  SqlColumn _buildColumn(String name, String type, String rest) {
    final lowerRest = rest.toLowerCase();
    final hasNotNull = lowerRest.contains('not null');
    final hasPrimaryKey = lowerRest.contains('primary key');
    final isNullable = !hasNotNull && !hasPrimaryKey;

    final defaultMatch = RegExp(
      r'default\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(rest.trim());
    final defaultValue = defaultMatch?.group(1)?.trim();

    return SqlColumn(
      name: name,
      type: type,
      isNullable: isNullable,
      defaultValue: defaultValue,
    );
  }

  // ─── Parsing contrainte table-level ───

  SqlTableConstraint _parseTableConstraint(String def) {
    final lower = def.toLowerCase();

    // PRIMARY KEY
    final pkNameMatch = RegExp(
      r'constraint\s+(\w+)\s+primary\s+key',
      caseSensitive: false,
    ).firstMatch(def);
    if (pkNameMatch != null || lower.contains('primary key')) {
      final cols = _extractParenthesized(def, 'primary key');
      return SqlTableConstraint(
        name: pkNameMatch?.group(1),
        kind: 'primary_key',
        columns: cols != null ? _splitColumnList(cols) : [],
      );
    }

    // FOREIGN KEY
    final fkNameMatch = RegExp(
      r'constraint\s+(\w+)\s+foreign\s+key',
      caseSensitive: false,
    ).firstMatch(def);
    if (fkNameMatch != null || lower.contains('foreign key')) {
      final fkCols = _extractParenthesized(def, 'foreign key');
      final refIdx = lower.indexOf('references');
      String? refTable;
      String? refCols;
      if (refIdx != -1) {
        final refText = def.substring(refIdx);
        final tableMatch = RegExp(
          r'references\s+(?:public\.)?(\w+)',
          caseSensitive: false,
        ).firstMatch(refText);
        refTable = tableMatch?.group(1);
        refCols = _extractParenthesized(refText, 'references');
      }
      return SqlTableConstraint(
        name: fkNameMatch?.group(1),
        kind: 'foreign_key',
        columns: fkCols != null ? _splitColumnList(fkCols) : [],
        referenceTable: refTable,
        referenceColumns: refCols,
      );
    }

    // UNIQUE
    final uniqueNameMatch = RegExp(
      r'constraint\s+(\w+)\s+unique',
      caseSensitive: false,
    ).firstMatch(def);
    if (uniqueNameMatch != null || lower.contains('unique')) {
      final cols = _extractParenthesized(def, 'unique');
      return SqlTableConstraint(
        name: uniqueNameMatch?.group(1),
        kind: 'unique',
        columns: cols != null ? _splitColumnList(cols) : [],
      );
    }

    // CHECK
    final checkNameMatch = RegExp(
      r'constraint\s+(\w+)\s+check',
      caseSensitive: false,
    ).firstMatch(def);
    if (checkNameMatch != null || lower.contains('check')) {
      final expr = _extractParenthesized(def, 'check');
      return SqlTableConstraint(
        name: checkNameMatch?.group(1),
        kind: 'check',
        columns: [],
        expression: expr,
      );
    }

    return const SqlTableConstraint(kind: 'unknown', columns: []);
  }

  // ─── Helpers ───

  String? _extractParenthesized(String text, String keyword) {
    final lowerText = text.toLowerCase();
    final lowerKeyword = keyword.toLowerCase();
    final start = lowerText.indexOf(lowerKeyword);
    if (start == -1) return null;

    final parenStart = text.indexOf('(', start);
    if (parenStart == -1) return null;

    var depth = 1;
    var i = parenStart + 1;
    while (i < text.length && depth > 0) {
      if (text[i] == '(') depth++;
      else if (text[i] == ')') depth--;
      i++;
    }
    if (depth != 0) return null;
    return text.substring(parenStart + 1, i - 1);
  }

  List<String> _splitColumnList(String cols) {
    return cols
        .split(',')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
  }
}
