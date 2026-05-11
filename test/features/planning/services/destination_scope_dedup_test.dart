// Phase 3 / Tâche 3.2 — Tests d'intégration de la scope validation
// `DestinationScope` dans le sélecteur déterministe.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places. Fixtures fictives.
//
// Stratégie pour isoler la nouvelle logique du reste du sélecteur :
//   - utilise un fake DI sans MetroProfile en lookup (cluster
//     center hors mégapole connue) pour éviter quality_floor V8.28f
//     fallback.
//   - candidats avec `userRatingCount < 200` et `types: ['park']`
//     pour échapper aux caps iconic existants.
//   - blueprintMustSeeMarker fourni au cas où.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/features/planning/data/destination_blueprints.dart'
    show blueprintMustSeeMarker;
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/models/destination_intelligence.dart';
import 'package:voyage/services/destination_scope_rejection.dart';
import 'package:voyage/services/scope_validator.dart';

// ─── Helpers ──────────────────────────────────────────────────────────

/// Default coords (50.0, 0.0) = North Sea : pas de MetroProfile
/// match, donc le filtre legacy `blockedAddressPatterns` reste
/// vide. Permet d'isoler le test du scope validator.
NearbyCandidate _candidate({
  required String id,
  required String name,
  String? address,
  double lat = 50.0,
  double lng = 0.0,
  double rating = 4.4,
  int reviews = 80,
  List<String> types = const ['park', 'point_of_interest'],
}) {
  return NearbyCandidate(
    placeId: id,
    name: name,
    address: address,
    latitude: lat,
    longitude: lng,
    rating: rating,
    userRatingCount: reviews,
    types: types,
  );
}

Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})>
    _pool(
  List<NearbyCandidate> candidates, {
  List<String> matchedInterests = const [blueprintMustSeeMarker],
}) {
  return {
    for (final c in candidates)
      c.placeId: (candidate: c, matchedInterests: matchedInterests),
  };
}

/// Trip avec destination fictive (`'Fictitious Place'`) pour ne
/// PAS matcher un blueprint connu → tripDestinationMetro restera
/// null → blockedAddrPatterns legacy = []. Permet d'isoler la
/// logique scope du filtre legacy concurrent.
Trip _isolatedTrip({
  required DateTime startDate,
  required DateTime endDate,
  String destination = 'Fictitious Place',
}) {
  return Trip(
    id: 'test-trip',
    userId: 'u1',
    title: 'Test',
    destination: destination,
    startDate: startDate,
    endDate: endDate,
    createdAt: DateTime(2026, 5, 11),
  );
}

/// Default cluster center hors MetroProfile (North Sea) pour
/// isoler le test du legacy filter.
PlacesPromptInput _cluster({
  required List<DateTime> days,
  required Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> pool,
  double centerLat = 50.0,
  double centerLng = 0.0,
}) {
  return PlacesPromptInput(
    center: DayCenter(
      latitude: centerLat,
      longitude: centerLng,
      source: 'destination',
    ),
    days: days,
    pool: pool,
  );
}

void main() {
  // ─── 1. Flag OFF = comportement inchangé ─────────────────────────────

  group('Flag OFF — comportement strictement inchangé', () {
    test('Flag OFF + DI Singapour : candidats Johor passent (legacy '
        'filtre les attrape ailleurs, validator inactif)', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Marina Bay Sands',
            address: '10 Bayfront Avenue, Singapore'),
        _candidate(id: 'p2', name: 'KSL City Mall',
            address: 'Jalan Seladang, Johor Bahru, Malaysia'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: false, // explicit OFF
        destinationIntelligence: buildSingaporeDestinationIntelligence(),
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isEmpty,
          reason: 'Aucun rejet destination_scope attendu avec flag OFF');
    });

    test('Defaults (sans aucun param scope) = strict OFF', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'KSL City Mall',
            address: 'Johor Bahru, Malaysia'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isEmpty,
          reason: 'Defaults sans flag explicite = pré-3.2 strict');
    });

    test('Flag ON sans DI → aucun rejet (court-circuit sécurité)', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'KSL City Mall',
            address: 'Johor Bahru, Malaysia'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: true,
        destinationIntelligence: null, // pas de DI
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isEmpty,
          reason: 'Flag ON mais DI null → court-circuit, no-op');
    });
  });

  // ─── 2. Flag ON : Singapour bloque Malaisie / Indonésie ──────────────

  group('Flag ON — Singapour bloque hors scope', () {
    final singaporeDi = buildSingaporeDestinationIntelligence();

    test('Address "Johor Bahru, Malaysia" → rejet '
        'blocked_neighbor_region', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Marina Bay Sands',
            address: '10 Bayfront Avenue, Singapore'),
        _candidate(id: 'p2', name: 'KSL City Mall',
            address: 'Jalan Seladang, Johor Bahru, Malaysia',
            // déplacé près du centre cluster pour ne pas être
            // filtré par distance/cohérence
            lat: 50.0, lng: 0.0),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: true,
        destinationIntelligence: singaporeDi,
        destinationScopeRejectionsOut: scopeRejections,
      );

      // KSL City Mall (Johor Bahru) doit être rejeté
      final visitNames = visits.map((v) => v.title).toList();
      expect(visitNames, isNot(contains('KSL City Mall')),
          reason: 'KSL City Mall (Johor) ne doit jamais apparaître '
              'avec flag ON');

      expect(scopeRejections, isNotEmpty);
      final ksl = scopeRejections
          .where((r) => r.candidateTitle == 'KSL City Mall')
          .toList();
      expect(ksl, isNotEmpty);
      expect(ksl.first.reason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(ksl.first.pipelineReason,
          equals('destination_scope_blocked_neighbor_region'));
    });

    test('Address "Batam, Indonesia" → rejet', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Mega Mall',
            address: 'Batu Aji, Batam, Riau Islands, Indonesia',
            lat: 50.0, lng: 0.0),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: true,
        destinationIntelligence: singaporeDi,
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isNotEmpty);
      expect(scopeRejections.first.reason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
    });

    test('Address "Tanjung Pinang, Kepri" → rejet', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Resort Kepri',
            address: 'Tanjung Pinang, Kepri, Indonesia',
            lat: 50.0, lng: 0.0),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: true,
        destinationIntelligence: singaporeDi,
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isNotEmpty);
    });

    test('Address "Marina Bay, Singapore" → accepté (pas de rejet)', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Marina Bay Sands',
            address: '10 Bayfront Avenue, Singapore 018956'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _isolatedTrip(startDate: day, endDate: day);

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: true,
        destinationIntelligence: singaporeDi,
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isEmpty,
          reason: 'Lieu Singapour propre ne doit pas être rejeté');
    });
  });

  // ─── 3. Dubai DI résout le point ouvert 3.1 ──────────────────────────

  group('Flag ON — Dubai DI avec blockedNeighborRegions', () {
    // Phase 3 / Tâche 3.2 — résolution propre du point ouvert
    // signalé en 3.1. Dubai accepte AE, bloque Abu Dhabi / Sharjah
    // / Ajman via blockedNeighborRegions.
    DestinationIntelligence dubaiDi() => DestinationIntelligence(
          destinationKey: 'dubai',
          canonicalCenter: const GeoPoint(lat: 25.276, lng: 55.296),
          countryCode: 'AE',
          allowedCountryCodes: const ['AE'],
          blockedCountryCodes: const [],
          blockedNeighborRegions: const [
            'abu dhabi',
            'sharjah',
            'ajman',
          ],
          borderSensitivity: BorderSensitivity.medium,
          tripMode: TripMode.megaCity,
          zones: [
            const TouristZone(
              name: 'Downtown',
              center: GeoPoint(lat: 25.197, lng: 55.274),
              radiusKm: 2,
              theme: 'urban_core',
            ),
          ],
          anchors: [
            const DestinationAnchor(
              name: 'Burj Khalifa',
              placeQueries: ['Burj Khalifa'],
              importance: 5,
              recommendedDuration: Duration(minutes: 120),
            ),
          ],
          transportRules: const TransportRules(
            maxTransitionKm: 10,
            dominantMode: 'taxi',
            hasMetro: true,
            hasMetroAnchorLogic: false,
          ),
        );

    test('Address "Abu Dhabi" rejeté SANS logique custom pipeline', () {
      final day = DateTime(2026, 5, 18);
      // Coords hors MetroProfile Dubai (North Sea) → legacy
      // filter inactif, on isole le scope validator.
      final candidates = [
        _candidate(id: 'p1', name: 'Sheikh Zayed Grand Mosque',
            address: 'Sheikh Rashid bin Saeed Street, Abu Dhabi'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = Trip(
        id: 'test-dubai',
        userId: 'u1',
        title: 'Fictitious Dubai-like',
        destination: 'Fictitious Dubai-like',
        startDate: day,
        endDate: day,
        createdAt: DateTime(2026, 5, 11),
      );

      final scopeRejections = <DestinationScopeRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useDestinationScope: true,
        destinationIntelligence: dubaiDi(),
        destinationScopeRejectionsOut: scopeRejections,
      );

      expect(scopeRejections, isNotEmpty,
          reason: 'Abu Dhabi doit être rejeté via '
              'blockedNeighborRegions');
      expect(scopeRejections.first.reason,
          equals(ScopeRejectionReason.blockedNeighborRegion));
      expect(scopeRejections.first.matchedEvidence, equals('abu dhabi'));
    });
  });

  // ─── 4. Pipeline reason / logging structure ──────────────────────────

  group('Logging et reason structure', () {
    test('pipelineReason format snake_case canonique', () {
      const rej = DestinationScopeRejection(
        candidateTitle: 'X',
        reason: ScopeRejectionReason.blockedNeighborRegion,
        confidence: ScopeConfidence.medium,
      );
      expect(rej.pipelineReason,
          equals('destination_scope_blocked_neighbor_region'));
    });

    test('pipelineReason pour outOfCountry', () {
      const rej = DestinationScopeRejection(
        candidateTitle: 'X',
        reason: ScopeRejectionReason.outOfCountry,
        confidence: ScopeConfidence.high,
      );
      expect(rej.pipelineReason,
          equals('destination_scope_out_of_country'));
    });

    test('pipelineReason pour blockedCountry', () {
      const rej = DestinationScopeRejection(
        candidateTitle: 'X',
        reason: ScopeRejectionReason.blockedCountry,
        confidence: ScopeConfidence.high,
      );
      expect(rej.pipelineReason,
          equals('destination_scope_blocked_country'));
    });
  });
}
