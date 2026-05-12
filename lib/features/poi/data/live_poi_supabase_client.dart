/// POI-0.8 — Thin wrapper live autour de `supabase_flutter`.
///
/// Adapte le vrai `SupabaseClient` au contrat abstrait
/// [PoiSupabaseClient] défini en POI-0.7. Aucune logique métier :
/// seule translation d'appels.
///
/// ## Usage
///
/// ```dart
/// import 'package:supabase_flutter/supabase_flutter.dart';
///
/// final liveClient = LivePoiSupabaseClient(Supabase.instance.client);
/// final repo = SupabasePoiRepository(liveClient);
/// ```
///
/// ## Sécurité
///
/// - Read-only : seules les méthodes `SELECT`-like sont exposées.
/// - Aucun `insert`, `update`, `delete`, `upsert` n'est accessible via
///   [PoiSupabaseClient].
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'poi_supabase_client.dart';

/// Implémentation live de [PoiSupabaseClient].
class LivePoiSupabaseClient implements PoiSupabaseClient {
  final SupabaseClient _client;

  const LivePoiSupabaseClient(this._client);

  @override
  PoiSupabaseQuery from(String table) => LivePoiSupabaseQuery(_client, table);
}

/// Implémentation live de [PoiSupabaseQuery].
///
/// Accumule les opérations de filtrage/tri/limite en mémoire puis les
/// traduit en appels chaînés sur `PostgrestQueryBuilder` au moment de
/// `execute()` / `maybeSingle()`.
class LivePoiSupabaseQuery implements PoiSupabaseQuery {
  final SupabaseClient _client;
  final String _table;

  List<String>? _columns;
  final List<_Eq> _eqFilters = [];
  final List<_Ilike> _ilikeFilters = [];
  String? _orCondition;
  _In? _inFilter;
  final List<_Order> _orders = [];
  int? _limit;

  LivePoiSupabaseQuery(this._client, this._table);

  @override
  PoiSupabaseQuery select([List<String>? columns]) {
    _columns = columns;
    return this;
  }

  @override
  PoiSupabaseQuery eq(String column, dynamic value) {
    _eqFilters.add(_Eq(column, value));
    return this;
  }

  @override
  PoiSupabaseQuery ilike(String column, String pattern) {
    _ilikeFilters.add(_Ilike(column, pattern));
    return this;
  }

  @override
  PoiSupabaseQuery or(String conditions) {
    _orCondition = conditions;
    return this;
  }

  @override
  PoiSupabaseQuery inFilter(String column, List<dynamic> values) {
    _inFilter = _In(column, values);
    return this;
  }

  @override
  PoiSupabaseQuery order(String column, {bool ascending = true}) {
    _orders.add(_Order(column, ascending));
    return this;
  }

  @override
  PoiSupabaseQuery limit(int count) {
    _limit = count;
    return this;
  }

  @override
  Future<List<Map<String, dynamic>>> execute() async {
    final response = await _build();
    return (response as List)
        .cast<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> maybeSingle() async {
    final response = await _build(limit: 1);
    final list = (response as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    return Map<String, dynamic>.from(list.first);
  }

  // ─── Construction du builder PostgREST ───

  Future<dynamic> _build({int? limit}) async {
    dynamic builder = _client.from(_table).select(
          _columns?.join(',') ?? '*',
        );

    for (final f in _eqFilters) {
      builder = builder.eq(f.column, f.value);
    }
    for (final f in _ilikeFilters) {
      builder = builder.ilike(f.column, f.pattern);
    }
    if (_orCondition != null) {
      builder = builder.or(_orCondition!);
    }
    if (_inFilter != null) {
      builder = builder.inFilter(_inFilter!.column, _inFilter!.values);
    }
    for (final o in _orders) {
      builder = builder.order(o.column, ascending: o.ascending);
    }
    builder = builder.limit(limit ?? _limit ?? 1000);

    return builder;
  }
}

// ─── Value objects internes ───

class _Eq {
  final String column;
  final dynamic value;
  _Eq(this.column, this.value);
}

class _Ilike {
  final String column;
  final String pattern;
  _Ilike(this.column, this.pattern);
}

class _In {
  final String column;
  final List<dynamic> values;
  _In(this.column, this.values);
}

class _Order {
  final String column;
  final bool ascending;
  _Order(this.column, this.ascending);
}
