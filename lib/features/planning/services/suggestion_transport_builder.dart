import 'dart:developer' as developer;

import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/places_cache_service.dart';
import 'package:voyage/features/planning/services/routes_service.dart';

/// Construit les lignes `trip_transports` pour les paires d'activités
/// consécutives du même jour.
///
/// Cette classe est extraite de `_SuggestionsSheet._save()` pour être
/// testable en isolation (pas d'écriture Supabase, pas d'appel réseau).
class SuggestionTransportBuilder {
  final RoutesService _routesService;
  final PlacesCacheService _placesService;
  final String _destination;
  final String? _travelerType;

  SuggestionTransportBuilder({
    required RoutesService routesService,
    required PlacesCacheService placesService,
    required String destination,
    required String? travelerType,
  })  : _routesService = routesService,
        _placesService = placesService,
        _destination = destination,
        _travelerType = travelerType;

  Future<List<Map<String, dynamic>>> buildRows({
    required List<TripActivity> allActivities,
    required Set<String> existingPairs,
  }) async {
    final pairs = <(TripActivity, TripActivity)>[];
    for (var i = 0; i < allActivities.length - 1; i++) {
      final a = allActivities[i];
      final b = allActivities[i + 1];
      final sameDay = a.dayDate.year == b.dayDate.year &&
          a.dayDate.month == b.dayDate.month &&
          a.dayDate.day == b.dayDate.day;
      if (!sameDay) continue;
      if (existingPairs.contains('${a.id}|${b.id}')) continue;
      pairs.add((a, b));
    }

    developer.log(
      'Construction transports : ${pairs.length} paire(s) consécutive(s) à traiter',
      name: 'planning',
    );

    Future<RouteEndpoint?> resolveEndpoint(TripActivity act) async {
      if (act.hasCoordinates) {
        return RouteEndpoint.coords(lat: act.latitude!, lng: act.longitude!);
      }
      final info = await _placesService.findInfo(
        title: act.title,
        destination: _destination,
      );
      if (info.placeId != null && info.placeId!.isNotEmpty) {
        return RouteEndpoint.placeId(info.placeId!);
      }
      return null;
    }

    final transportResults = await Future.wait(pairs.map((pair) async {
      final (a, b) = pair;
      final epA = await resolveEndpoint(a);
      final epB = await resolveEndpoint(b);

      List<TransportOption>? routesOptions;
      if (epA != null && epB != null) {
        routesOptions = await _routesService.computeOptionsFromEndpoints(
          from: epA,
          to: epB,
        );
        developer.log(
          'Routes "${a.title}" → "${b.title}" : '
          '${routesOptions == null ? "ÉCHEC (null)" : "${routesOptions.length} options [${routesOptions.map((o) => o.mode).join(", ")}]"}',
          name: 'planning',
        );
      } else {
        developer.log(
          'Routes "${a.title}" → "${b.title}" : SKIP (endpoint introuvable — A=${epA == null ? "null" : "ok"}, B=${epB == null ? "null" : "ok"})',
          name: 'planning',
        );
      }

      if (routesOptions == null || routesOptions.isEmpty) return null;
      final finalOptions = routesOptions;
      final defaultMode = _pickDefaultMode(finalOptions, _travelerType);

      final defaultOpt = finalOptions.firstWhere(
        (o) => o.mode == defaultMode,
        orElse: () => finalOptions.first,
      );
      return {
        'trip_id': a.tripId,
        'from_activity_id': a.id,
        'to_activity_id': b.id,
        'selected_mode': defaultOpt.mode,
        'selected_duration_minutes': defaultOpt.durationMinutes,
        'selected_price_estimate': defaultOpt.priceEstimate,
        'options': finalOptions.map((o) => o.toJson()).toList(),
      };
    }));

    return transportResults.whereType<Map<String, dynamic>>().toList();
  }

  String _pickDefaultMode(List<TransportOption> options, String? travelerType) {
    if (options.isEmpty) return 'walk';
    TransportOption? findMode(String m) {
      for (final o in options) {
        if (o.mode == m) return o;
      }
      return null;
    }

    TransportOption? findTransit() => findMode('transit') ?? findMode('metro');

    final walk = findMode('walk');
    if (walk != null && walk.durationMinutes <= 12 && travelerType != 'Grand luxe') {
      return 'walk';
    }
    switch (travelerType) {
      case 'Grand luxe':
      case 'Voyage pro':
        return findMode('taxi')?.mode ?? options.first.mode;
      case 'Backpack':
      case 'Meilleur prix':
        return findMode('walk')?.mode ?? findTransit()?.mode ?? options.first.mode;
      case 'En famille':
        return findTransit()?.mode ?? findMode('taxi')?.mode ?? options.first.mode;
      default:
        return findTransit()?.mode ?? options.first.mode;
    }
  }
}
