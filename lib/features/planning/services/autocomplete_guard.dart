import 'dart:async';
import 'package:flutter/foundation.dart';

/// POI-2.1 / API-0.6a — Central guard for Google Places autocomplete calls.
///
/// Enforces, in order:
/// 1. Min length (default 4 chars) → skip with debug log
/// 2. In-memory cache hit → return cached, debug log
/// 3. Google fallback with timeout + error safety → cache result, debug log
///
/// The guard is **generic** and **context-agnostic**. Lunao-first lookup is
/// the responsibility of the caller (PlacesService), because the result type
/// varies per context (destination has `kind`, city does not, transport has
/// neither).
///
/// Transport autocomplete gets min-length + cache + timeout protection,
/// but never Lunao destination matches.
class AutocompleteGuard {
  final Duration _timeout;
  final int _minLength;
  final Map<String, _CacheEntry<dynamic>> _cache = {};

  AutocompleteGuard({
    Duration timeout = const Duration(seconds: 5),
    int minLength = 4,
  })  : _timeout = timeout,
        _minLength = minLength;

  /// Execute an autocomplete search with full guard protection.
  ///
  /// [query] — raw user input (will be trimmed + lowercased internally).
  /// [context] — semantic context for logging ('destination', 'city',
  ///   'transport', etc.).
  /// [fallback] — the actual Google Places call (or any other fallback).
  ///
  /// Returns results from cache or fallback. Never throws — errors and
  /// timeouts return an empty list after logging.
  Future<List<T>> execute<T>({
    required String query,
    required String context,
    required Future<List<T>> Function() fallback,
  }) async {
    final normalized = query.trim().toLowerCase();

    // 1. Min-length guard
    if (normalized.length < _minLength) {
      // ignore: avoid_print
      print(
        '[autocomplete] google_skipped '
        'reason=too_short '
        'query="$normalized" '
        'length=${normalized.length} '
        'context=$context',
      );
      return <T>[];
    }

    // 2. Cache hit
    final cacheKey = '$context:$normalized';
    final cached = _cache[cacheKey];
    if (cached != null && !cached.isStale) {
      // ignore: avoid_print
      print(
        '[autocomplete] source=cache '
        'query="$normalized" '
        'context=$context '
        'results=${cached.results.length}',
      );
      return cached.results as List<T>;
    }

    // 3. Fallback with timeout + error safety
    try {
      final results = await fallback().timeout(_timeout);
      _cache[cacheKey] = _CacheEntry<T>(results);
      // ignore: avoid_print
      print(
        '[autocomplete] source=google_fallback '
        'query="$normalized" '
        'context=$context '
        'results=${results.length}',
      );
      return results;
    } on TimeoutException {
      // ignore: avoid_print
      print(
        '[autocomplete] source=google_fallback '
        'reason=timeout '
        'query="$normalized" '
        'context=$context',
      );
      return <T>[];
    } catch (e) {
      // ignore: avoid_print
      print(
        '[autocomplete] source=google_fallback '
        'reason=error '
        'error="$e" '
        'query="$normalized" '
        'context=$context',
      );
      return <T>[];
    }
  }

  /// Expose cache for tests.
  @visibleForTesting
  Map<String, dynamic> get cacheSnapshot =>
      Map<String, dynamic>.from(_cache);

  /// Clear cache (useful for testing or memory pressure).
  void clearCache() => _cache.clear();
}

class _CacheEntry<T> {
  final List<T> results;
  final DateTime createdAt;

  _CacheEntry(this.results) : createdAt = DateTime.now();

  /// Entries older than 5 minutes are considered stale.
  bool get isStale =>
      DateTime.now().difference(createdAt) > const Duration(minutes: 5);
}
