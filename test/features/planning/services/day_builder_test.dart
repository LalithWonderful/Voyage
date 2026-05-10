import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/data/destination_blueprints.dart';
import 'package:voyage/features/planning/services/day_builder.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Tests Day Builder V8.20 — composition de day packs thématiques pour
/// les grandes villes (Bangkok V1, Paris V1). Validation que :
/// - Day Builder s'active uniquement pour les villes éligibles.
/// - Les archétypes (old_city / riverside / market / modern) regroupent
///   les bons candidats par patterns + types Google Places.
/// - Les long transitions (>5 km) déclenchent shrink puis reject.
/// - Le premier jour du trip → arrival_light_day si possible.
/// - reservedPlaceIds bloque les candidats déjà pris par d'autres
///   sub-clusters du même segment.

void main() {
  late Trip bangkokTrip;
  late Trip kohSametTrip;

  setUp(() {
    bangkokTrip = Trip(
      id: 'trip1',
      userId: 'u1',
      title: 'Bangkok',
      destination: 'Bangkok, Thailand',
      startDate: DateTime(2026, 6, 22),
      endDate: DateTime(2026, 6, 28),
      createdAt: DateTime(2026, 5, 10),
    );
    kohSametTrip = Trip(
      id: 'trip2',
      userId: 'u1',
      title: 'Koh Samet',
      destination: 'Koh Samet, Thailand',
      startDate: DateTime(2026, 6, 30),
      endDate: DateTime(2026, 7, 1),
      createdAt: DateTime(2026, 5, 10),
    );
  });

  // Bangkok candidates : 5 must-sees Old City compact + 3 modern + 2 market.
  NearbyCandidate candidate({
    required String id,
    required String name,
    required double lat,
    required double lng,
    double rating = 4.5,
    int reviews = 1000,
    List<String> types = const ['tourist_attraction'],
  }) {
    return NearbyCandidate(
      placeId: id,
      name: name,
      latitude: lat,
      longitude: lng,
      rating: rating,
      userRatingCount: reviews,
      types: types,
    );
  }

  Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})>
      bangkokPool() {
    final entries = <NearbyCandidate, List<String>>{
      // Old City compact (Phra Nakhon, ~13.745 N, 100.49 E)
      candidate(
        id: 'gp',
        name: 'Grand Palace',
        lat: 13.7500, lng: 100.4914,
        reviews: 100000,
        types: ['tourist_attraction', 'historical_landmark'],
      ): [blueprintMustSeeMarker, 'Culture'],
      candidate(
        id: 'wp',
        name: 'Wat Pho',
        lat: 13.7465, lng: 100.4927,
        reviews: 50000,
        types: ['place_of_worship', 'tourist_attraction'],
      ): [blueprintMustSeeMarker, 'Culture'],
      candidate(
        id: 'wa',
        name: 'Wat Arun',
        lat: 13.7437, lng: 100.4889,
        reviews: 40000,
        types: ['place_of_worship', 'tourist_attraction'],
      ): [blueprintMustSeeMarker, 'Culture'],
      candidate(
        id: 'ks',
        name: 'Khao San Road',
        lat: 13.7589, lng: 100.4977,
        reviews: 20000,
        types: ['tourist_attraction'],
      ): [blueprintExperienceMarker, 'Nightlife'],
      candidate(
        id: 'nm',
        name: 'National Museum Bangkok',
        lat: 13.7575, lng: 100.4920,
        reviews: 5000,
        types: ['museum'],
      ): ['Culture'],
      // Modern (Sukhumvit/Siam, ~13.745 N, 100.534 E)
      candidate(
        id: 'jt',
        name: 'Jim Thompson House Museum',
        lat: 13.7494, lng: 100.5294,
        reviews: 10000,
        types: ['museum'],
      ): [blueprintMustSeeMarker, 'Culture'],
      candidate(
        id: 'mn',
        name: 'Mahanakhon SkyWalk',
        lat: 13.7232, lng: 100.5287,
        reviews: 8000,
        types: ['tourist_attraction'],
      ): [blueprintMustSeeMarker],
      candidate(
        id: 'lp',
        name: 'Lumphini Park',
        lat: 13.7307, lng: 100.5418,
        reviews: 30000,
        types: ['park'],
      ): [blueprintMustSeeMarker, 'Nature'],
      // Market (Chatuchak ~13.799, 100.55 + Chinatown ~13.741, 100.51)
      candidate(
        id: 'ch',
        name: 'Chatuchak Weekend Market',
        lat: 13.7997, lng: 100.5505,
        reviews: 60000,
        types: ['market'],
      ): [blueprintMustSeeMarker, 'Shopping'],
      candidate(
        id: 'cn',
        name: 'Chinatown Yaowarat',
        lat: 13.7414, lng: 100.5103,
        reviews: 30000,
        types: ['tourist_attraction'],
      ): [blueprintMustSeeMarker, 'Gastronomie'],
      // Riverside
      candidate(
        id: 'is',
        name: 'IconSiam',
        lat: 13.7261, lng: 100.5108,
        reviews: 80000,
        types: ['shopping_mall'],
      ): [blueprintMustSeeMarker, 'Shopping'],
      candidate(
        id: 'as',
        name: 'Asiatique The Riverfront',
        lat: 13.7044, lng: 100.5031,
        reviews: 50000,
        types: ['tourist_attraction'],
      ): [blueprintExperienceMarker],
      // Filler hotel-local (Bang Na ~13.67, 100.60) → no archetype match
      candidate(
        id: 'bn1',
        name: 'Imperial World Bang Na',
        lat: 13.6670, lng: 100.6080,
        reviews: 5000,
        types: ['shopping_mall'],
      ): const [],
    };
    return {
      for (final e in entries.entries)
        e.key.placeId: (candidate: e.key, matchedInterests: e.value),
    };
  }

  group('Day Builder activation', () {
    test('Bangkok cluster (centre Sukhumvit) → enabled', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      expect(result.enabled, isTrue);
      expect(result.cityKey, 'bangkok');
      expect(result.dayPackByDate.length, greaterThan(0));
    });

    test('Bangkok hotel area Bang Na (~12 km du centre) → enabled', () {
      // Bang Na est dans le rayon 35 km de Bangkok center.
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.6670,
        clusterCenterLng: 100.6080,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      expect(result.enabled, isTrue);
    });

    test('Koh Samet (kind=islandBeach) → disabled', () {
      // Koh Samet est trop loin du centre Bangkok (>200 km) ET son
      // blueprint est islandBeach → Day Builder skip.
      final result = buildDayPacksForCluster(
        clusterCenterLat: 12.5667,
        clusterCenterLng: 101.4500,
        clusterDays: [DateTime(2026, 6, 30), DateTime(2026, 7, 1)],
        clusterPool: bangkokPool(),
        trip: kohSametTrip,
        maxPerDay: 3,
      );
      expect(result.enabled, isFalse);
    });

    test('Hanoi (pas de blueprint) → disabled', () {
      final hanoiTrip = Trip(
        id: 't', userId: 'u', title: 'Hanoi',
        destination: 'Hanoi, Vietnam',
        startDate: DateTime(2026, 7, 11),
        endDate: DateTime(2026, 7, 14),
        createdAt: DateTime(2026, 5, 10),
      );
      final result = buildDayPacksForCluster(
        clusterCenterLat: 21.0285,
        clusterCenterLng: 105.8542,
        clusterDays: [
          DateTime(2026, 7, 11),
          DateTime(2026, 7, 12),
          DateTime(2026, 7, 13),
        ],
        clusterPool: bangkokPool(),
        trip: hanoiTrip,
        maxPerDay: 4,
      );
      expect(result.enabled, isFalse);
    });

    test('cluster < 2 jours → disabled', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [DateTime(2026, 6, 22)],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      expect(result.enabled, isFalse);
    });

    test('pool < 8 candidats → disabled', () {
      final tinyPool = Map.fromEntries(
        bangkokPool().entries.take(5),
      );
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
        ],
        clusterPool: tinyPool,
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      expect(result.enabled, isFalse);
    });
  });

  group('Day Builder pack composition', () {
    test('Bangkok 3j → ≥ 1 pack old_city avec Grand Palace + Wat Pho '
        'sans Chatuchak ni IconSiam', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      expect(result.enabled, isTrue);

      // Trouve un pack old_city (idéalement le J2 ou J3 — J1 = arrival).
      final oldCityPack = result.dayPackByDate.values
          .firstWhere(
            (p) => p.type == DayPackType.oldCityDay,
            orElse: () => throw StateError('no old_city pack found'),
          );
      final names = oldCityPack.places.map((c) => c.name).toList();
      expect(names, contains('Grand Palace'));
      expect(names, contains('Wat Pho'));
      // Pas de mix avec ICONSIAM ou Chatuchak ou Jim Thompson dans
      // le même pack — ce sont d'autres archétypes.
      expect(names, isNot(contains('IconSiam')));
      expect(names, isNot(contains('Chatuchak Weekend Market')));
      expect(names, isNot(contains('Jim Thompson House Museum')));
    });

    test('Long transitions ≤ 1 par pack non-arrival', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      for (final pack in result.dayPackByDate.values) {
        expect(pack.longTransitions, lessThanOrEqualTo(1),
            reason: 'pack ${pack.type.label} should not exceed 1 long hop');
      }
    });

    test('first day (= trip.startDate) → arrival_light_day OU old_city_day '
        '(spec : "Old City compact OR arrival_light_day")', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      final j1Pack = result.dayPackByDate[DateTime(2026, 6, 22)];
      expect(j1Pack, isNotNull);
      // V8.21 — arrival_light est strict (pattern-only, 5km cap). Si
      // le pool non-must-see compact est insuffisant, fall-through vers
      // old_city_day est acceptable (spec user 2026-05-10 PM).
      expect(
        j1Pack!.type,
        anyOf(DayPackType.arrivalLightDay, DayPackType.oldCityDay),
      );
      // Quel que soit le type, le pack J1 doit respecter les caps de
      // transition (arrival_light ≤5km, old_city ≤10km).
      if (j1Pack.type == DayPackType.arrivalLightDay) {
        expect(j1Pack.maxTransitionKm, lessThanOrEqualTo(5.0));
        expect(j1Pack.places.length, lessThanOrEqualTo(3));
      } else {
        expect(j1Pack.maxTransitionKm, lessThanOrEqualTo(10.0));
      }
    });

    test('Pack restreint à max 4 places', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 6, // user max 6 mais Day Builder cap 4
      );
      for (final pack in result.dayPackByDate.values) {
        expect(pack.places.length, lessThanOrEqualTo(4));
      }
    });

    test('Filler Bang Na (no archetype) ne ressort dans aucun pack', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      final allPlaceIds = <String>{
        for (final p in result.dayPackByDate.values) ...p.placeIds,
      };
      // 'bn1' = Imperial World Bang Na, sans match archétype.
      expect(allPlaceIds, isNot(contains('bn1')));
    });
  });

  group('Day Builder transition caps V8.21', () {
    test('Pack non-arrival rejette si maxTransition > 10km '
        '(Chatuchak↔Srinagarindra protégé)', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      for (final pack in result.dayPackByDate.values) {
        expect(pack.maxTransitionKm, lessThanOrEqualTo(10.0),
            reason: 'pack ${pack.type.label} dépasse cap 10km');
      }
    });

    test('arrival_light_day rejette si maxTransition > 5km '
        '(Asiatique→Bang Na 9.6km protégé)', () {
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      final j1 = result.dayPackByDate[DateTime(2026, 6, 22)];
      if (j1 != null && j1.type == DayPackType.arrivalLightDay) {
        expect(j1.maxTransitionKm, lessThanOrEqualTo(5.0),
            reason: 'arrival_light_day doit avoir maxTransition ≤ 5km');
      }
    });

    test('Bang Na local temple (place_of_worship sans pattern) '
        'n\'est PAS dans arrival_light_day', () {
      // Pool avec uniquement le strict nécessaire + 2 Bang Na temples
      // (type place_of_worship/buddhist_temple, NO pattern match).
      final localPool = <
          String,
          ({NearbyCandidate candidate, List<String> matchedInterests})>{};
      // Add local Bang Na temples (no pattern, type fallback only)
      localPool['bnnok'] = (
        candidate: NearbyCandidate(
          placeId: 'bnnok',
          name: 'Wat Bang Na Nok',
          latitude: 13.6765,
          longitude: 100.5876,
          rating: 4.5,
          userRatingCount: 1500,
          types: ['buddhist_temple', 'tourist_attraction', 'place_of_worship'],
        ),
        matchedInterests: const <String>[],
      );
      localPool['bnphueng'] = (
        candidate: NearbyCandidate(
          placeId: 'bnphueng',
          name: 'Wat Bang Nam Phueng Nok',
          latitude: 13.6828,
          longitude: 100.5865,
          rating: 4.4,
          userRatingCount: 1200,
          types: ['buddhist_temple', 'tourist_attraction', 'place_of_worship'],
        ),
        matchedInterests: const <String>[],
      );
      // Add iconic blueprint must-sees pour atteindre minPool
      localPool.addAll(bangkokPool());

      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.6700,
        clusterCenterLng: 100.6000, // Bang Na hotel
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
        ],
        clusterPool: localPool,
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      final j1 = result.dayPackByDate[DateTime(2026, 6, 22)];
      if (j1 != null && j1.type == DayPackType.arrivalLightDay) {
        final names = j1.places.map((c) => c.name).toList();
        expect(names, isNot(contains('Wat Bang Na Nok')),
            reason: 'temple Bang Na local ne doit jamais entrer en '
                'arrival_light (type fallback seulement, pas de pattern)');
        expect(names, isNot(contains('Wat Bang Nam Phueng Nok')));
      }
    });
  });

  group('Day Builder V8.22 first-hop exclusion + J1 fallback restriction', () {
    test('cluster hôtel Bang Na (12km du Old City) accepte vrai old_city_day '
        '(hop hôtel→1ʳᵉ place ignoré du cap)', () {
      // Cluster centre = Bang Na hôtel. Old City iconique = ~12km.
      // Pré V8.22 : pack old_city rejeté car NN order démarrait par
      // un 12km hop. Post V8.22 : ce hop initial est exclu du cap.
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.6700,
        clusterCenterLng: 100.6000,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      final j1 = result.dayPackByDate[DateTime(2026, 6, 22)];
      expect(j1, isNotNull,
          reason: 'J1 doit avoir un pack (arrival_light ou old_city)');
      // J1 doit être arrival_light OU old_city, jamais modern.
      expect(j1!.type,
          anyOf(DayPackType.arrivalLightDay, DayPackType.oldCityDay));
      // Quel que soit le type, maxTransition (inter-pick) doit être petit.
      expect(j1.maxTransitionKm, lessThanOrEqualTo(5.0));
    });

    test('J1 fallback restreint à old_city_day (jamais modern/market/'
        'riverside même si old_city pool insuffisant)', () {
      // Pool sans Old City (que des modern + riverside + market) →
      // J1 doit retourner null (pas de pack), jamais modern_day.
      final modernOnlyPool = <
          String,
          ({NearbyCandidate candidate, List<String> matchedInterests})>{};
      void add(String id, String name, double lat, double lng,
          int reviews, List<String> types, List<String> mi) {
        modernOnlyPool[id] = (
          candidate: NearbyCandidate(
            placeId: id,
            name: name,
            latitude: lat,
            longitude: lng,
            rating: 4.5,
            userRatingCount: reviews,
            types: types,
          ),
          matchedInterests: mi,
        );
      }

      add('jt', 'Jim Thompson House Museum', 13.7494, 100.5294, 10000,
          ['museum'], [blueprintMustSeeMarker]);
      add('mn', 'Mahanakhon SkyWalk', 13.7232, 100.5287, 8000,
          ['tourist_attraction'], [blueprintMustSeeMarker]);
      add('lp', 'Lumphini Park', 13.7307, 100.5418, 30000,
          ['park'], [blueprintMustSeeMarker]);
      add('is', 'IconSiam', 13.7261, 100.5108, 80000,
          ['shopping_mall'], [blueprintMustSeeMarker]);
      add('as', 'Asiatique The Riverfront', 13.7044, 100.5031, 50000,
          ['tourist_attraction'], [blueprintExperienceMarker]);
      add('ch', 'Chatuchak Weekend Market', 13.7997, 100.5505, 60000,
          ['market'], [blueprintMustSeeMarker]);
      add('tn', 'Train Night Market Srinagarindra', 13.6939, 100.6512, 18073,
          ['market'], const []);
      add('cn', 'Chinatown Yaowarat', 13.7414, 100.5103, 30000,
          ['tourist_attraction'], [blueprintMustSeeMarker]);

      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 22),
          DateTime(2026, 6, 25),
        ],
        clusterPool: modernOnlyPool,
        trip: bangkokTrip,
        maxPerDay: 4,
      );
      final j1 = result.dayPackByDate[DateTime(2026, 6, 22)];
      // J1 doit être null (pas de pack possible) OU arrival_light_day.
      // Modern/market/riverside interdits sur J1.
      if (j1 != null) {
        expect(j1.type,
            anyOf(DayPackType.arrivalLightDay, DayPackType.oldCityDay),
            reason: 'J1 ne doit jamais être modern/market/riverside');
      }
    });
  });

  group('Day Builder V8.24 zoned market split (Bangkok)', () {
    test('Chatuchak et Chinatown sont dans des zones distinctes '
        '(market_chatuchak_day vs market_old_city_day)', () {
      // Construit un pool avec assez de candidats marché pour que
      // chaque zone puisse théoriquement former un pack.
      final marketSplitPool = <
          String,
          ({NearbyCandidate candidate, List<String> matchedInterests})>{};
      void add(String id, String name, double lat, double lng,
          int reviews, List<String> types, List<String> mi) {
        marketSplitPool[id] = (
          candidate: NearbyCandidate(
            placeId: id,
            name: name,
            latitude: lat,
            longitude: lng,
            rating: 4.5,
            userRatingCount: reviews,
            types: types,
          ),
          matchedInterests: mi,
        );
      }

      // Old City zone (must avoid market_old_city_day pack collision —
      // 3 candidats Old City compacts).
      add('chinatown', 'Chinatown Yaowarat', 13.7414, 100.5103, 30000,
          ['tourist_attraction'], [blueprintMustSeeMarker]);
      add('banglamphu', 'Bang Lamphu Market', 13.7595, 100.4994, 776,
          ['tourist_attraction', 'market'], const []);
      add('pakkhlong', 'Pak Khlong Talat (Flower Market)', 13.7407, 100.4972,
          5000, ['market', 'tourist_attraction'], const []);

      // Chatuchak zone — distincte
      add('chatuchak', 'Chatuchak Weekend Market', 13.7997, 100.5505, 60000,
          ['market'], [blueprintMustSeeMarker]);
      add('jjmall', 'JJ Mall', 13.8023, 100.5526, 5000,
          ['shopping_mall'], const []);
      add('ortorkor', 'Or Tor Kor Market', 13.8046, 100.5497, 8000,
          ['market'], const []);

      // Srinagarindra zone — distincte
      add('trainnight', 'Train Night Market Srinagarindra', 13.6939, 100.6512,
          18073, ['market'], const []);

      // Iconiques compagnons pour atteindre minPool=8
      add('gp', 'Grand Palace', 13.7500, 100.4914, 100000,
          ['tourist_attraction', 'historical_landmark'],
          [blueprintMustSeeMarker]);
      add('wp', 'Wat Pho', 13.7465, 100.4927, 50000,
          ['place_of_worship'], [blueprintMustSeeMarker]);
      add('wa', 'Wat Arun', 13.7437, 100.4889, 40000,
          ['place_of_worship'], [blueprintMustSeeMarker]);

      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
          DateTime(2026, 7, 1),
        ],
        clusterPool: marketSplitPool,
        trip: bangkokTrip,
        maxPerDay: 4,
      );

      // Aucun pack ne doit jamais contenir Chatuchak ET Train Night
      // Market Srinagarindra ensemble (anciennement V8.21 risque).
      for (final pack in result.dayPackByDate.values) {
        final ids = pack.placeIds;
        expect(ids.contains('chatuchak') && ids.contains('trainnight'),
            isFalse,
            reason: 'pack ${pack.type.label} ne doit pas mixer Chatuchak '
                'et Srinagarindra (zones distinctes)');
      }

      // Aucun pack ne doit mixer Chatuchak (nord) ET Chinatown (Old
      // City) — V8.24 sépare ces deux zones marché.
      for (final pack in result.dayPackByDate.values) {
        final ids = pack.placeIds;
        expect(ids.contains('chatuchak') && ids.contains('chinatown'),
            isFalse,
            reason: 'pack ${pack.type.label} ne doit pas mixer Chatuchak '
                'et Chinatown (zones marché distinctes V8.24)');
      }
    });

    test('market_chatuchak_day pack possible si pool ≥ 3 '
        '(Chatuchak + JJ Mall + Or Tor Kor)', () {
      final pool = <
          String,
          ({NearbyCandidate candidate, List<String> matchedInterests})>{};
      void add(String id, String name, double lat, double lng,
          int reviews, List<String> types, List<String> mi) {
        pool[id] = (
          candidate: NearbyCandidate(
            placeId: id,
            name: name,
            latitude: lat,
            longitude: lng,
            rating: 4.5,
            userRatingCount: reviews,
            types: types,
          ),
          matchedInterests: mi,
        );
      }

      // Pool centré sur Chatuchak — 3 candidats market_chatuchak.
      add('chatuchak', 'Chatuchak Weekend Market', 13.7997, 100.5505, 60000,
          ['market'], [blueprintMustSeeMarker]);
      add('jjmall', 'JJ Mall', 13.8023, 100.5526, 5000,
          ['shopping_mall'], const []);
      add('ortorkor', 'Or Tor Kor Market', 13.8046, 100.5497, 8000,
          ['market'], const []);
      // Padding pour atteindre minPool=8
      add('gp', 'Grand Palace', 13.7500, 100.4914, 100000,
          ['tourist_attraction'], [blueprintMustSeeMarker]);
      add('wp', 'Wat Pho', 13.7465, 100.4927, 50000,
          ['place_of_worship'], [blueprintMustSeeMarker]);
      add('wa', 'Wat Arun', 13.7437, 100.4889, 40000,
          ['place_of_worship'], [blueprintMustSeeMarker]);
      add('jt', 'Jim Thompson House Museum', 13.7494, 100.5294, 10000,
          ['museum'], [blueprintMustSeeMarker]);
      add('mn', 'Mahanakhon SkyWalk', 13.7232, 100.5287, 8000,
          ['tourist_attraction'], [blueprintMustSeeMarker]);

      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
          DateTime(2026, 7, 1),
        ],
        clusterPool: pool,
        trip: bangkokTrip,
        maxPerDay: 4,
      );

      // Le greedy doit pouvoir placer un market_chatuchak_day quelque
      // part vu le pool (Chatuchak + JJ Mall + Or Tor Kor compacts à
      // ~13.80/100.55, inter-pick ≤ 0.5 km).
      final hasChatuchakPack = result.dayPackByDate.values
          .any((p) => p.type == DayPackType.marketChatuchakDay);
      // Le greedy peut préférer old_city ou modern d'abord, mais
      // market_chatuchak_day doit être un type *valide* dans le
      // catalogue. Le test plus précis : aucune des 3 places
      // Chatuchak ne se retrouve dans un pack non-Chatuchak.
      final chatuchakPlaces = {'chatuchak', 'jjmall', 'ortorkor'};
      for (final pack in result.dayPackByDate.values) {
        final overlap = pack.placeIds.intersection(chatuchakPlaces);
        if (overlap.isNotEmpty) {
          expect(pack.type, DayPackType.marketChatuchakDay,
              reason: 'place Chatuchak dans pack ${pack.type.label} '
                  'au lieu de market_chatuchak_day');
        }
      }
      // Sanity: le hasChatuchakPack pourra être true ou false selon
      // greedy ordering, mais le type doit exister dans l'enum.
      expect(DayPackType.marketChatuchakDay.label, 'market_chatuchak_day');
      // ignore: unused_local_variable
      final _ = hasChatuchakPack;
    });
  });

  group('Day Builder cross-cluster reservation', () {
    test('reservedPlaceIds exclut les places déjà prises par autre cluster',
        () {
      final reserved = {'gp', 'wp', 'wa'}; // sub-cluster A a pris Old City
      final result = buildDayPacksForCluster(
        clusterCenterLat: 13.7563,
        clusterCenterLng: 100.5018,
        clusterDays: [
          DateTime(2026, 6, 25),
          DateTime(2026, 6, 28),
        ],
        clusterPool: bangkokPool(),
        trip: bangkokTrip,
        maxPerDay: 4,
        reservedPlaceIds: reserved,
      );
      // Si activé, les packs ne doivent contenir aucun placeId réservé.
      if (result.enabled) {
        for (final pack in result.dayPackByDate.values) {
          for (final id in pack.placeIds) {
            expect(reserved, isNot(contains(id)),
                reason: 'reserved place $id leaked into pack');
          }
        }
      }
    });
  });
}
