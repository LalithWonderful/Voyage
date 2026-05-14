/// Lunao-first offline resolver for major train and bus hubs.
///
/// This resolver never falls back to Google Places, Geocoding, Routes,
/// Supabase, Overpass, or any network service. Unknown inputs return null.
library;

import 'package:voyage/features/transport/data/transport_hubs_seed.dart';

class OfflineTransportHubResolver {
  final List<TransportHub> _hubs;

  const OfflineTransportHubResolver({
    List<TransportHub> hubs = transportHubsSeed,
  }) : _hubs = hubs;

  TransportHub? resolve({
    required String city,
    required String query,
    Set<TransportHubType>? hubTypes,
  }) {
    final matches = search(city: city, query: query, hubTypes: hubTypes);
    return matches.isEmpty ? null : matches.first;
  }

  List<TransportHub> search({
    required String city,
    required String query,
    Set<TransportHubType>? hubTypes,
  }) {
    final normalizedCity = normalizeTransportHubToken(city);
    final normalizedQuery = normalizeTransportHubToken(query);
    if (normalizedCity.isEmpty || normalizedQuery.isEmpty) return const [];

    final matches = _hubs
        .where((hub) {
          if (normalizeTransportHubToken(hub.city) != normalizedCity) {
            return false;
          }
          if (hubTypes != null && !hubTypes.contains(hub.hubType)) return false;
          return _searchTokens(hub).any((token) {
            if (normalizedQuery.length <= 3) {
              return token == normalizedQuery;
            }
            return token == normalizedQuery || token.contains(normalizedQuery);
          });
        })
        .toList(growable: false);

    matches.sort(_compareHubs);
    return matches;
  }

  List<TransportHub> listForCity(String city) {
    final normalizedCity = normalizeTransportHubToken(city);
    if (normalizedCity.isEmpty) return const [];
    final matches = _hubs
        .where((hub) => normalizeTransportHubToken(hub.city) == normalizedCity)
        .toList(growable: false);
    matches.sort(_compareHubs);
    return matches;
  }

  static Iterable<String> _searchTokens(TransportHub hub) sync* {
    yield normalizeTransportHubToken(hub.name);
    yield normalizeTransportHubToken(hub.id.replaceAll('_', ' '));
    for (final alias in hub.aliases) {
      yield normalizeTransportHubToken(alias);
    }
    final iata = hub.iataCode;
    if (iata != null) {
      yield normalizeTransportHubToken(iata);
    }
    final rail = hub.railCode;
    if (rail != null) {
      yield normalizeTransportHubToken(rail);
    }
  }

  static int _compareHubs(TransportHub a, TransportHub b) {
    final priority = b.priority.compareTo(a.priority);
    if (priority != 0) return priority;
    return a.id.compareTo(b.id);
  }
}

String normalizeTransportHubToken(String value) {
  final lower = value.trim().toLowerCase();
  final stripped = lower
      .replaceAll(RegExp('[àáâãäåā]'), 'a')
      .replaceAll(RegExp('[çćč]'), 'c')
      .replaceAll(RegExp('[ď]'), 'd')
      .replaceAll(RegExp('[èéêëēėę]'), 'e')
      .replaceAll(RegExp('[ìíîïī]'), 'i')
      .replaceAll(RegExp('[ñń]'), 'n')
      .replaceAll(RegExp('[òóôõöøō]'), 'o')
      .replaceAll(RegExp('[ß]'), 'ss')
      .replaceAll(RegExp('[ùúûüū]'), 'u')
      .replaceAll(RegExp('[ýÿ]'), 'y')
      .replaceAll(RegExp('[’‘`´]'), "'")
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return stripped.replaceAll(RegExp(r'\s+'), ' ');
}
