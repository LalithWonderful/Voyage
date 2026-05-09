/// Tests unitaires `itinerary_mutation.dart` (Lot 2.1).
///
/// Couverture : 3 modes (APPEND/SPLIT/REPLACE) × cas de succès + cas
/// d'échec (anchor introuvable, days insuffisants, free days
/// insuffisants). Plus quelques edge-cases : multi-step segments,
/// match accent-insensible, multi-occurrence anchor.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/planning/services/pinned_dates.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/itinerary_mutation.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────

TripSegment _seg(String city, int days, {String? country}) =>
    TripSegment(city: city, days: days, country: country);

SubTripSuggestion _appendDayTrip({
  required String anchor,
  required String city,
}) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: 1)],
      insertionMode: InsertionMode.dayTrip,
    );

SubTripSuggestion _appendNearbyStay({
  required String anchor,
  required String city,
  required int days,
  String? regionLabel,
  String? country,
}) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: days, country: country)],
      insertionMode: InsertionMode.nearbyStay,
      regionLabel: regionLabel,
    );

SubTripSuggestion _split({
  required String anchor,
  required String city,
  required int days,
  required int minKeep,
  bool gateway = true,
}) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: days)],
      insertionMode: gateway
          ? InsertionMode.splitGatewaySequence
          : InsertionMode.splitSegment,
      minAnchorDaysToKeep: minKeep,
    );

SubTripSuggestion _splitMulti({
  required String anchor,
  required List<({String city, int days})> cities,
  required int minKeep,
}) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: cities.map((c) => c.city).join(' + '),
      segments: cities
          .map((c) => SuggestedSegment(city: c.city, days: c.days))
          .toList(),
      insertionMode: InsertionMode.splitGatewaySequence,
      minAnchorDaysToKeep: minKeep,
    );

SubTripSuggestion _replace({
  required String anchor,
  required String city,
  required int suggestedDays,
}) =>
    SubTripSuggestion(
      anchorCity: anchor,
      displayName: city,
      segments: [SuggestedSegment(city: city, days: suggestedDays)],
      insertionMode: InsertionMode.replaceAnchorGateway,
    );

void main() {
  group('computeMutation — anchor lookup', () {
    test('anchor introuvable → MutationFailed.anchorNotFound', () {
      final result = computeMutation(
        suggestion: _appendDayTrip(anchor: 'Tokyo', city: 'Kyoto'),
        currentSegments: [_seg('Paris', 4), _seg('Lyon', 2)],
        tripDurationDays: 6,
      );
      expect(result, isA<MutationFailed>());
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.anchorNotFound,
      );
    });

    test('match accent-insensible (Hanoï == Hanoi)', () {
      final result = computeMutation(
        suggestion: _appendDayTrip(anchor: 'Hanoï', city: 'Trang An'),
        currentSegments: [_seg('Hanoi', 3)],
        tripDurationDays: 5,
      );
      expect(result, isA<MutationOk>());
      expect((result as MutationOk).mutation.anchorIndex, 0);
    });

    test('multi-occurrence anchor → premier match retenu', () {
      final result = computeMutation(
        suggestion: _appendDayTrip(anchor: 'Bangkok', city: 'Ayutthaya'),
        currentSegments: [
          _seg('Bangkok', 2),
          _seg('Phuket', 3),
          _seg('Bangkok', 1),
        ],
        tripDurationDays: 7, // 6 placés, 1 libre → APPEND OK
      );
      expect(result, isA<MutationOk>());
      expect((result as MutationOk).mutation.anchorIndex, 0);
    });
  });

  group('computeMutation — APPEND (dayTrip / nearbyStay)', () {
    test('dayTrip avec jours libres suffisants', () {
      final result = computeMutation(
        suggestion: _appendDayTrip(anchor: 'Paris', city: 'Versailles'),
        currentSegments: [_seg('Paris', 4)],
        tripDurationDays: 6, // 4 placés, 2 libres
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.newAnchorDays, isNull);
      expect(m.insertedSegments.length, 1);
      expect(m.insertedSegments[0].city, 'Versailles');
      expect(m.insertedSegments[0].days, 1);
    });

    test('dayTrip sans jour libre → notEnoughFreeDaysToAppend', () {
      final result = computeMutation(
        suggestion: _appendDayTrip(anchor: 'Paris', city: 'Versailles'),
        currentSegments: [_seg('Paris', 7)],
        tripDurationDays: 7, // 7/7 placés
      );
      expect(result, isA<MutationFailed>());
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.notEnoughFreeDaysToAppend,
      );
    });

    test('nearbyStay 2 nuits avec jours libres pile suffisants', () {
      final result = computeMutation(
        suggestion: _appendNearbyStay(
          anchor: 'Da Nang',
          city: 'Hué',
          days: 2,
          regionLabel: 'au Vietnam central',
          country: 'Vietnam',
        ),
        currentSegments: [_seg('Da Nang', 3, country: 'Vietnam')],
        tripDurationDays: 5, // 3 placés, 2 libres
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.insertedSegments[0].days, 2);
      expect(m.insertedSegments[0].country, 'Vietnam',
          reason: 'pour APPEND, le country est propagé depuis '
              'SuggestedSegment.country (pas hérité de l\'anchor)');
    });
  });

  group('computeMutation — SPLIT (splitSegment / splitGatewaySequence)', () {
    test('splitGatewaySequence simple : Hanoï 4 + Ninh Bình 3 / minKeep 1', () {
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
        ),
        currentSegments: [_seg('Hanoï', 4, country: 'Vietnam')],
        tripDurationDays: 4,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.newAnchorDays, 1); // 4 - 3 = 1
      expect(m.insertedSegments[0].city, 'Ninh Bình');
      expect(m.insertedSegments[0].days, 3);
    });

    test('split insuffisant → notEnoughDaysToSplit', () {
      // Hanoï 3 + Ninh Bình 3 / minKeep 1 → reste 0 < 1
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
        ),
        currentSegments: [_seg('Hanoï', 3)],
        tripDurationDays: 3,
      );
      expect(result, isA<MutationFailed>());
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.notEnoughDaysToSplit,
      );
    });

    test('split multi-step : Bangkok 6 → Rayong 1 + Koh Samet 2 / minKeep 1', () {
      final result = computeMutation(
        suggestion: _splitMulti(
          anchor: 'Bangkok',
          cities: [
            (city: 'Rayong', days: 1),
            (city: 'Koh Samet', days: 2),
          ],
          minKeep: 1,
        ),
        currentSegments: [_seg('Bangkok', 6, country: 'Thaïlande')],
        tripDurationDays: 6,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.newAnchorDays, 3); // 6 - 1 - 2 = 3
      expect(m.insertedSegments.length, 2);
      expect(m.insertedSegments[0].city, 'Rayong');
      expect(m.insertedSegments[1].city, 'Koh Samet');
    });

    test('splitGatewaySequence borderline : Hanoï 4 + Ninh Bình 3 / minKeep 1, '
        'reste exactement minKeep', () {
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
        ),
        currentSegments: [_seg('Hanoï', 4)],
        tripDurationDays: 4,
      );
      expect(result, isA<MutationOk>(),
          reason: 'reste = 1 = minKeep, doit passer');
      expect((result as MutationOk).mutation.newAnchorDays, 1);
    });

    test('safety floor : SPLIT avec minKeep=0 et addedDays=anchor.days '
        '→ refus (jamais 0-day segment)', () {
      // Cas pathologique : catalogue mal configuré (minKeep=0 + 3 nuits
      // suggérées sur anchor de 3 nuits → reste 0). La safety floor
      // dans computeMutation force minKeep effectif à 1.
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 0,
        ),
        currentSegments: [_seg('Hanoï', 3)],
        tripDurationDays: 3,
      );
      expect(result, isA<MutationFailed>(),
          reason: 'safety floor refuse de créer un anchor à 0 jour '
              'même si catalogue déclare minKeep=0');
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.notEnoughDaysToSplit,
      );
    });

    test('safety floor : SPLIT avec minKeep=0 et marge → autorisé', () {
      // minKeep=0 mais addedDays < anchor.days → reste ≥ 1, pas de
      // segment vide → autorisé.
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 0,
        ),
        currentSegments: [_seg('Hanoï', 4)],
        tripDurationDays: 4,
      );
      expect(result, isA<MutationOk>());
      expect((result as MutationOk).mutation.newAnchorDays, 1);
    });
  });

  group('computeMutation — REPLACE (replaceAnchorGateway)', () {
    test('Da Nang 5 + Hội An déclaré 3 → Hội An prend 5 jours (override)', () {
      final result = computeMutation(
        suggestion: _replace(
          anchor: 'Da Nang',
          city: 'Hội An',
          suggestedDays: 3,
        ),
        currentSegments: [_seg('Da Nang', 5, country: 'Vietnam')],
        tripDurationDays: 5,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.newAnchorDays, 0); // anchor supprimé
      expect(m.insertedSegments[0].city, 'Hội An');
      expect(m.insertedSegments[0].days, 5,
          reason: 'override de la valeur déclarée 3');
      expect(m.insertedSegments[0].country, 'Vietnam');
    });

    test('REPLACE même durée déclarée que anchor', () {
      final result = computeMutation(
        suggestion: _replace(
          anchor: 'Da Nang',
          city: 'Hội An',
          suggestedDays: 3,
        ),
        currentSegments: [_seg('Da Nang', 3)],
        tripDurationDays: 3,
      );
      expect(result, isA<MutationOk>());
      expect((result as MutationOk).mutation.insertedSegments[0].days, 3);
    });
  });

  group('applyMutation — APPEND insère APRÈS l\'anchor', () {
    test('insertion à la suite de l\'anchor, autres segments inchangés', () {
      final segments = [
        _seg('Paris', 4),
        _seg('Lyon', 2),
      ];
      final result = computeMutation(
        suggestion: _appendDayTrip(anchor: 'Paris', city: 'Versailles'),
        currentSegments: segments,
        tripDurationDays: 7, // 1 jour libre
      );
      final mutated = applyMutation(segments, (result as MutationOk).mutation);
      expect(mutated.length, 3);
      expect(mutated[0].city, 'Paris');
      expect(mutated[0].days, 4); // inchangé
      expect(mutated[1].city, 'Versailles');
      expect(mutated[1].days, 1);
      expect(mutated[2].city, 'Lyon'); // inchangé
    });
  });

  group('applyMutation — SPLIT remplace anchor par [suggested, anchor reduit]', () {
    test('Hanoï 4 + Ninh Bình 3 → [Ninh Bình 3, Hanoï 1]', () {
      final segments = [_seg('Hanoï', 4, country: 'Vietnam')];
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 4,
      );
      final mutated = applyMutation(segments, (result as MutationOk).mutation);
      expect(mutated.length, 2);
      expect(mutated[0].city, 'Ninh Bình');
      expect(mutated[0].days, 3);
      expect(mutated[1].city, 'Hanoï');
      expect(mutated[1].days, 1, reason: 'anchor réduit');
      expect(mutated[1].country, 'Vietnam',
          reason: 'copyWith préserve les autres champs');
    });

    test('split multi-step : Bangkok 6 → [Rayong 1, Koh Samet 2, Bangkok 3]', () {
      final segments = [_seg('Bangkok', 6, country: 'Thaïlande')];
      final result = computeMutation(
        suggestion: _splitMulti(
          anchor: 'Bangkok',
          cities: [
            (city: 'Rayong', days: 1),
            (city: 'Koh Samet', days: 2),
          ],
          minKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 6,
      );
      final mutated = applyMutation(segments, (result as MutationOk).mutation);
      expect(mutated.length, 3);
      expect(mutated[0].city, 'Rayong');
      expect(mutated[1].city, 'Koh Samet');
      expect(mutated[2].city, 'Bangkok');
      expect(mutated[2].days, 3); // 6 - 1 - 2
    });

    test('SPLIT préserve la somme totale', () {
      final segments = [_seg('Hanoï', 4)];
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 4,
      );
      final mutated = applyMutation(segments, (result as MutationOk).mutation);
      final totalBefore = segments.fold<int>(0, (s, e) => s + e.days);
      final totalAfter = mutated.fold<int>(0, (s, e) => s + e.days);
      expect(totalAfter, totalBefore);
    });
  });

  group('applyMutation — REPLACE supprime anchor et insère à sa place', () {
    test('Da Nang 5 → Hội An 5 (override durée)', () {
      final segments = [
        _seg('Phú Quốc', 3, country: 'Vietnam'),
        _seg('Da Nang', 5, country: 'Vietnam'),
        _seg('Bangkok', 2, country: 'Thaïlande'),
      ];
      final result = computeMutation(
        suggestion: _replace(
          anchor: 'Da Nang',
          city: 'Hội An',
          suggestedDays: 3,
        ),
        currentSegments: segments,
        tripDurationDays: 10,
      );
      final mutated = applyMutation(segments, (result as MutationOk).mutation);
      expect(mutated.length, 3);
      expect(mutated[0].city, 'Phú Quốc'); // inchangé
      expect(mutated[1].city, 'Hội An');
      expect(mutated[1].days, 5, reason: 'override');
      expect(mutated[2].city, 'Bangkok'); // inchangé
    });

    test('REPLACE préserve la somme totale', () {
      final segments = [_seg('Da Nang', 5), _seg('Bangkok', 2)];
      final result = computeMutation(
        suggestion: _replace(
          anchor: 'Da Nang',
          city: 'Hội An',
          suggestedDays: 3,
        ),
        currentSegments: segments,
        tripDurationDays: 7,
      );
      final mutated = applyMutation(segments, (result as MutationOk).mutation);
      final totalBefore = segments.fold<int>(0, (s, e) => s + e.days);
      final totalAfter = mutated.fold<int>(0, (s, e) => s + e.days);
      expect(totalAfter, totalBefore);
    });
  });

  group('applyMutation — idempotence applique-t-elle même résultat', () {
    test('appliquer la même mutation 2× sur 2 listes identiques '
        'donne 2 résultats identiques', () {
      final segments = [_seg('Hanoï', 4)];
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 4,
      );
      final m = (result as MutationOk).mutation;
      final r1 = applyMutation(segments, m);
      final r2 = applyMutation(segments, m);
      expect(r1.length, r2.length);
      for (var i = 0; i < r1.length; i++) {
        expect(r1[i].city, r2[i].city);
        expect(r1[i].days, r2[i].days);
      }
    });
  });

  // ─── Batch (Lot 2.3) ─────────────────────────────────────────────

  /// Helper local au groupe : compute la mutation pour une suggestion
  /// donnée, throw si MutationFailed (les fixtures de tests batch
  /// présupposent que les individuelles passent). Pas de underscore
  /// au préfixe (closure locale, lint le déconseille).
  ItineraryMutation mut(
    SubTripSuggestion s,
    List<TripSegment> segments,
    int duration,
  ) {
    final r = computeMutation(
      suggestion: s,
      currentSegments: segments,
      tripDurationDays: duration,
    );
    if (r is MutationOk) return r.mutation;
    throw StateError('test fixture: mutation failed: ${(r as MutationFailed).reason}');
  }

  group('validateMutationBatch', () {
    test('liste vide → BatchOk', () {
      final result = validateMutationBatch(
        mutations: const [],
        currentSegments: [_seg('Hanoï', 4)],
        tripDurationDays: 4,
      );
      expect(result, isA<BatchOk>());
    });

    test('1 SPLIT + 1 REPLACE sur anchors différents → OK', () {
      final segments = [_seg('Hanoï', 4), _seg('Da Nang', 3)];
      final m1 = mut(
        _split(anchor: 'Hanoï', city: 'Ninh Bình', days: 3, minKeep: 1),
        segments,
        7,
      );
      final m2 = mut(
        _replace(anchor: 'Da Nang', city: 'Hội An', suggestedDays: 3),
        segments,
        7,
      );
      final result = validateMutationBatch(
        mutations: [m1, m2],
        currentSegments: segments,
        tripDurationDays: 7,
      );
      expect(result, isA<BatchOk>());
    });

    test('2 SPLIT sur même anchor → conflictingStructuralOnSameAnchor', () {
      final segments = [_seg('Hanoï', 6)];
      final m1 = mut(
        _split(anchor: 'Hanoï', city: 'Ninh Bình', days: 3, minKeep: 1),
        segments,
        6,
      );
      // 2e split sur Hanoï (Ha Long) — calculé contre original.
      final m2 = mut(
        _split(anchor: 'Hanoï', city: 'Ha Long', days: 2, minKeep: 1),
        segments,
        6,
      );
      final result = validateMutationBatch(
        mutations: [m1, m2],
        currentSegments: segments,
        tripDurationDays: 6,
      );
      expect(result, isA<BatchFailed>());
      expect(
        (result as BatchFailed).reason,
        BatchFailureReason.conflictingStructuralOnSameAnchor,
      );
      expect(result.anchorCity, 'Hanoï');
    });

    test('REPLACE + APPEND sur même anchor → appendOnRemovedAnchor', () {
      final segments = [_seg('Da Nang', 3)];
      final m1 = mut(
        _replace(anchor: 'Da Nang', city: 'Hội An', suggestedDays: 3),
        segments,
        5,
      );
      // APPEND sur Da Nang via dayTrip imaginaire (Da Nang n'a pas de
      // dayTrip dans le catalogue mais on peut le construire ici).
      final dayTripFromDaNang = SubTripSuggestion(
        anchorCity: 'Da Nang',
        displayName: 'Marble Mountains',
        segments: [SuggestedSegment(city: 'Marble Mountains', days: 1)],
        insertionMode: InsertionMode.dayTrip,
      );
      final m2 = mut(dayTripFromDaNang, segments, 5);
      final result = validateMutationBatch(
        mutations: [m1, m2],
        currentSegments: segments,
        tripDurationDays: 5,
      );
      expect(result, isA<BatchFailed>());
      expect(
        (result as BatchFailed).reason,
        BatchFailureReason.appendOnRemovedAnchor,
      );
    });

    test('2 APPEND avec total > free days → notEnoughFreeDaysForAllAppends',
        () {
      // Trip 4j, déjà placés Hanoï 3 + Da Nang 1 = 4. Aucun jour libre.
      final segments = [_seg('Hanoï', 3), _seg('Da Nang', 1)];
      final dayTripHanoi = SubTripSuggestion(
        anchorCity: 'Hanoï',
        displayName: 'Trang An',
        segments: [SuggestedSegment(city: 'Trang An', days: 1)],
        insertionMode: InsertionMode.dayTrip,
      );
      // 2 mutations avec free=0 → la 1re passe individuellement
      // (computeMutation est appelée avec tripDuration assez grand pour
      // faire passer le test fixture). Mais en BATCH avec free = 0,
      // la somme excède.
      // Pour isoler la règle batch, on appelle le validator avec une
      // duration plus stricte que celle utilisée pour compute.
      final m1 = mut(dayTripHanoi, segments, 5); // free=1 dispo
      // 2e mutation : on fabrique manuellement un append de 2 jours
      // pour dépasser. Direct sans passer par computeMutation pour
      // contourner les checks individuels.
      final m2 = ItineraryMutation(
        anchorIndex: 1,
        anchorCity: 'Da Nang',
        mode: InsertionMode.dayTrip,
        insertedSegments: [_seg('Hoi An', 2)],
        newAnchorDays: null,
      );
      final result = validateMutationBatch(
        mutations: [m1, m2],
        currentSegments: segments,
        tripDurationDays: 4, // 0 free days
      );
      expect(result, isA<BatchFailed>());
      expect(
        (result as BatchFailed).reason,
        BatchFailureReason.notEnoughFreeDaysForAllAppends,
      );
    });

    test('SPLIT + APPEND sur même anchor → OK (split garde anchor, append après)',
        () {
      final segments = [_seg('Bangkok', 6)];
      final m1 = mut(
        _split(anchor: 'Bangkok', city: 'Pattaya', days: 2, minKeep: 1),
        segments,
        7,
      );
      // APPEND dayTrip sur Bangkok aussi.
      final dayTripBkk = SubTripSuggestion(
        anchorCity: 'Bangkok',
        displayName: 'Ayutthaya',
        segments: [SuggestedSegment(city: 'Ayutthaya', days: 1)],
        insertionMode: InsertionMode.dayTrip,
      );
      final m2 = mut(dayTripBkk, segments, 7);
      final result = validateMutationBatch(
        mutations: [m1, m2],
        currentSegments: segments,
        tripDurationDays: 7,
      );
      expect(result, isA<BatchOk>(),
          reason: 'SPLIT garde l\'anchor (réduit), APPEND peut s\'ajouter');
    });
  });

  group('applyMutationBatch', () {
    test('multi-anchor : Hanoï SPLIT + Da Nang REPLACE en cascade', () {
      final segments = [_seg('Hanoï', 4), _seg('Da Nang', 3)];
      final m1 = mut(
        _split(anchor: 'Hanoï', city: 'Ninh Bình', days: 3, minKeep: 1),
        segments,
        7,
      );
      final m2 = mut(
        _replace(anchor: 'Da Nang', city: 'Hội An', suggestedDays: 3),
        segments,
        7,
      );
      final result = applyMutationBatch(segments, [m1, m2]);
      // Attendu : [Ninh Bình 3, Hanoï 1, Hội An 3]
      expect(result.length, 3);
      expect(result[0].city, 'Ninh Bình');
      expect(result[0].days, 3);
      expect(result[1].city, 'Hanoï');
      expect(result[1].days, 1);
      expect(result[2].city, 'Hội An');
      expect(result[2].days, 3);
    });

    test('ordre tap-order préservé pour anchors indépendants', () {
      final segments = [_seg('Hanoï', 4), _seg('Da Nang', 3)];
      // Ordre inverse dans le batch : Da Nang d'abord, Hanoï ensuite.
      final m1 = mut(
        _replace(anchor: 'Da Nang', city: 'Hội An', suggestedDays: 3),
        segments,
        7,
      );
      final m2 = mut(
        _split(anchor: 'Hanoï', city: 'Ninh Bình', days: 3, minKeep: 1),
        segments,
        7,
      );
      final result = applyMutationBatch(segments, [m1, m2]);
      // Re-localisation par city : Da Nang appliqué d'abord (Hội An
      // remplace), puis Hanoï SPLIT (Ninh Bình + Hanoï 1).
      expect(result.length, 3);
      expect(result.map((s) => s.city).toList(),
          ['Ninh Bình', 'Hanoï', 'Hội An']);
    });

    test('apply Bangkok SPLIT multi-step + Hanoï SPLIT', () {
      final segments = [_seg('Hanoï', 4), _seg('Bangkok', 6)];
      final m1 = mut(
        _split(anchor: 'Hanoï', city: 'Ninh Bình', days: 3, minKeep: 1),
        segments,
        10,
      );
      final m2 = mut(
        _splitMulti(
          anchor: 'Bangkok',
          cities: [
            (city: 'Rayong', days: 1),
            (city: 'Koh Samet', days: 2),
          ],
          minKeep: 1,
        ),
        segments,
        10,
      );
      final result = applyMutationBatch(segments, [m1, m2]);
      expect(result.map((s) => s.city).toList(),
          ['Ninh Bình', 'Hanoï', 'Rayong', 'Koh Samet', 'Bangkok']);
      expect(result.map((s) => s.days).toList(), [3, 1, 1, 2, 3]);
    });

    test('liste vide → segments inchangés', () {
      final segments = [_seg('Hanoï', 4), _seg('Da Nang', 3)];
      final result = applyMutationBatch(segments, []);
      expect(result.length, 2);
      expect(result[0].city, 'Hanoï');
      expect(result[1].city, 'Da Nang');
    });
  });

  // ─── V2.2 — insertionStartDate ──────────────────────────────────────

  group('suggestionRequiresInsertionDate', () {
    test('majorDestination × splitSegment → true', () {
      final s = SubTripSuggestion(
        anchorCity: 'Bangkok',
        displayName: 'Krabi',
        segments: const [SuggestedSegment(city: 'Krabi', days: 3)],
        insertionMode: InsertionMode.splitSegment,
        category: SuggestionCategory.majorDestination,
        minAnchorDaysToKeep: 1,
      );
      expect(suggestionRequiresInsertionDate(s), isTrue);
    });

    test('gateway × splitSegment → false (cas Ha Long single-step)', () {
      final s = SubTripSuggestion(
        anchorCity: 'Hanoï',
        displayName: 'Ha Long',
        segments: const [SuggestedSegment(city: 'Baie d\'Ha Long', days: 2)],
        insertionMode: InsertionMode.splitSegment,
        minAnchorDaysToKeep: 1,
      );
      expect(suggestionRequiresInsertionDate(s), isFalse);
    });

    test('splitGatewaySequence multi-step → true (Rayong+Koh Samet)', () {
      final s = SubTripSuggestion(
        anchorCity: 'Bangkok',
        displayName: 'Rayong + Koh Samet',
        segments: const [
          SuggestedSegment(city: 'Rayong', days: 1),
          SuggestedSegment(city: 'Koh Samet', days: 2),
        ],
        insertionMode: InsertionMode.splitGatewaySequence,
        minAnchorDaysToKeep: 1,
      );
      expect(suggestionRequiresInsertionDate(s), isTrue);
    });

    test('splitGatewaySequence single-step → false (Ninh Bình)', () {
      final s = SubTripSuggestion(
        anchorCity: 'Hanoï',
        displayName: 'Ninh Bình',
        segments: const [SuggestedSegment(city: 'Ninh Bình', days: 3)],
        insertionMode: InsertionMode.splitGatewaySequence,
        minAnchorDaysToKeep: 1,
      );
      expect(suggestionRequiresInsertionDate(s), isFalse);
    });

    test('APPEND modes → false', () {
      final s = SubTripSuggestion(
        anchorCity: 'Paris',
        displayName: 'Versailles',
        segments: const [SuggestedSegment(city: 'Versailles', days: 1)],
        insertionMode: InsertionMode.dayTrip,
      );
      expect(suggestionRequiresInsertionDate(s), isFalse);
    });

    test('REPLACE → false', () {
      final s = SubTripSuggestion(
        anchorCity: 'Da Nang',
        displayName: 'Hội An',
        segments: const [SuggestedSegment(city: 'Hội An', days: 5)],
        insertionMode: InsertionMode.replaceAnchorGateway,
      );
      expect(suggestionRequiresInsertionDate(s), isFalse);
    });
  });

  group('computeMutation — insertionStartDate', () {
    SubTripSuggestion krabiMajor() => const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3, country: 'Thaïlande')],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        );

    PinnedDatesAnalysis bkkAnalysis({List<TripDocument> docs = const []}) {
      return analyzePinnedDates(
        segments: [_seg('Bangkok', 11), _seg('Phú Quốc', 5)],
        tripStartDate: DateTime(2026, 6, 21),
        docs: docs,
      );
    }

    test('mutation porte requiresInsertionDate=true même sans date fournie', () {
      final result = computeMutation(
        suggestion: krabiMajor(),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.requiresInsertionDate, isTrue);
      expect(m.insertionStartDate, isNull);
      expect(m.insertionPreDays, isNull);
    });

    test('date valide + analyse → MutationOk avec insertionPreDays calculé', () {
      final result = computeMutation(
        suggestion: krabiMajor(),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
        insertionStartDate: DateTime(2026, 6, 26),
        pinnedAnalysis: bkkAnalysis(),
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.insertionStartDate, DateTime(2026, 6, 26));
      expect(m.insertionPreDays, 5); // 26/06 - 21/06
      expect(m.newAnchorDays, 8); // 11 - 3
    });

    test('date hors borne → MutationFailed.insertionDateOutOfBounds', () {
      // Date avant le début du segment.
      final result = computeMutation(
        suggestion: krabiMajor(),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
        insertionStartDate: DateTime(2026, 6, 18),
        pinnedAnalysis: bkkAnalysis(),
      );
      expect(result, isA<MutationFailed>());
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.insertionDateOutOfBounds,
      );
    });

    test('startPinned + pre=0 → autorisé (Lalith 2026-05-08 : pas de '
        'nuit forcée à l\'ancrage)', () {
      final analysis = bkkAnalysis(docs: [
        TripDocument(
          id: 'f1', userId: 'u', tripId: 't',
          category: DocumentCategory.flight,
          name: 'Vol',
          metadata: const {
            'from_city': 'Luxembourg',
            'to_city': 'Bangkok',
            'date': '2026-06-21',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ]);
      final result = computeMutation(
        suggestion: krabiMajor(),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
        insertionStartDate: DateTime(2026, 6, 21),
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
      expect((result as MutationOk).mutation.insertionPreDays, 0);
    });

    test('overlap hôtel anchor → insertionDateConflictsHotel', () {
      final analysis = bkkAnalysis(docs: [
        TripDocument(
          id: 'h1', userId: 'u', tripId: 't',
          category: DocumentCategory.hotel,
          name: 'Hôtel',
          metadata: const {
            'address_city': 'Bangkok',
            'check_in': '2026-06-25',
            'check_out': '2026-06-28',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ]);
      final result = computeMutation(
        suggestion: krabiMajor(),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
        insertionStartDate: DateTime(2026, 6, 26),
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationFailed>());
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.insertionDateConflictsHotel,
      );
    });

    test('date sans analyse → mutation acceptée avec insertionStartDate '
        'mais pas de pre/post (applyMutation tombera en fallback)', () {
      final result = computeMutation(
        suggestion: krabiMajor(),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
        insertionStartDate: DateTime(2026, 6, 26),
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.insertionStartDate, DateTime(2026, 6, 26));
      expect(m.insertionPreDays, isNull);
    });
  });

  group('applyMutation — 3-way split V2', () {
    test('cas E2E mémoire — Bangkok 11 + Krabi 3 @ 26/06 → '
        '[Bangkok 5, Krabi 3, Bangkok 3]', () {
      final segments = [_seg('Bangkok', 11, country: 'Thaïlande'), _seg('Phú Quốc', 5)];
      final result = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3, country: 'Thaïlande')],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 16,
        insertionStartDate: DateTime(2026, 6, 26),
        pinnedAnalysis: analyzePinnedDates(
          segments: segments,
          tripStartDate: DateTime(2026, 6, 21),
          docs: const [],
        ),
      );
      expect(result, isA<MutationOk>());
      final mutated = applyMutation(segments, (result as MutationOk).mutation);

      expect(mutated.length, 4);
      expect(mutated[0].city, 'Bangkok');
      expect(mutated[0].days, 5);
      expect(mutated[0].country, 'Thaïlande');
      expect(mutated[1].city, 'Krabi');
      expect(mutated[1].days, 3);
      expect(mutated[2].city, 'Bangkok');
      expect(mutated[2].days, 3);
      expect(mutated[2].country, 'Thaïlande');
      expect(mutated[3].city, 'Phú Quốc');
      expect(mutated[3].days, 5);
    });

    test('pre=0 → pas de segment anchor pre émis', () {
      final segments = [_seg('Bangkok', 11)];
      // Insertion au tout début (pre=0).
      final mutation = ItineraryMutation(
        anchorIndex: 0,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 8,
        insertionStartDate: DateTime(2026, 6, 21),
        insertionPreDays: 0,
      );
      final mutated = applyMutation(segments, mutation);
      expect(mutated.length, 2);
      expect(mutated[0].city, 'Krabi');
      expect(mutated[1].city, 'Bangkok');
      expect(mutated[1].days, 8);
    });

    test('post=0 → pas de segment anchor post émis', () {
      final segments = [_seg('Bangkok', 11)];
      // pre=8, inserted=3 → post=0.
      final mutation = ItineraryMutation(
        anchorIndex: 0,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 8,
        insertionStartDate: DateTime(2026, 6, 29),
        insertionPreDays: 8,
      );
      final mutated = applyMutation(segments, mutation);
      expect(mutated.length, 2);
      expect(mutated[0].city, 'Bangkok');
      expect(mutated[0].days, 8);
      expect(mutated[1].city, 'Krabi');
    });

    test('sans insertionPreDays → fallback comportement MVP', () {
      final segments = [_seg('Bangkok', 11)];
      final mutation = ItineraryMutation(
        anchorIndex: 0,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 8,
        // pas d'insertionStartDate ni preDays
      );
      final mutated = applyMutation(segments, mutation);
      // Comportement Lot 2.1 inchangé : insertion en début, anchor reliquat après.
      expect(mutated.length, 2);
      expect(mutated[0].city, 'Krabi');
      expect(mutated[1].city, 'Bangkok');
      expect(mutated[1].days, 8);
    });

    test('SPLIT préserve la somme totale après 3-way split', () {
      final segments = [_seg('Bangkok', 11), _seg('Phú Quốc', 5)];
      final mutation = ItineraryMutation(
        anchorIndex: 0,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 8,
        insertionStartDate: DateTime(2026, 6, 26),
        insertionPreDays: 5,
      );
      final mutated = applyMutation(segments, mutation);
      final totalBefore = segments.fold<int>(0, (s, e) => s + e.days);
      final totalAfter = mutated.fold<int>(0, (s, e) => s + e.days);
      expect(totalAfter, totalBefore);
    });
  });

  group('validateMutationBatch — missingInsertionDate', () {
    test('mutation requiresInsertionDate sans date → BatchFailed', () {
      final result = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3)],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        ),
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
      );
      final m = (result as MutationOk).mutation;
      expect(m.requiresInsertionDate, isTrue);
      expect(m.insertionStartDate, isNull);

      final batch = validateMutationBatch(
        mutations: [m],
        currentSegments: [_seg('Bangkok', 11)],
        tripDurationDays: 11,
      );
      expect(batch, isA<BatchFailed>());
      expect(
        (batch as BatchFailed).reason,
        BatchFailureReason.missingInsertionDate,
      );
      expect(batch.anchorCity, 'Bangkok');
    });

    test('mutation requiresInsertionDate avec date → BatchOk', () {
      final segments = [_seg('Bangkok', 11)];
      final result = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3)],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 11,
        insertionStartDate: DateTime(2026, 6, 26),
        pinnedAnalysis: analyzePinnedDates(
          segments: segments,
          tripStartDate: DateTime(2026, 6, 21),
          docs: const [],
        ),
      );
      final batch = validateMutationBatch(
        mutations: [(result as MutationOk).mutation],
        currentSegments: segments,
        tripDurationDays: 11,
      );
      expect(batch, isA<BatchOk>());
    });

    test('SPLIT sans requiresInsertionDate (gateway × split) sans date → '
        'BatchOk (legacy MVP path autorisé)', () {
      final result = computeMutation(
        suggestion: _split(
          anchor: 'Hanoï',
          city: 'Ninh Bình',
          days: 3,
          minKeep: 1,
          gateway: false, // splitSegment, pas majorDestination
        ),
        currentSegments: [_seg('Hanoï', 4)],
        tripDurationDays: 4,
      );
      final m = (result as MutationOk).mutation;
      expect(m.requiresInsertionDate, isFalse);
      final batch = validateMutationBatch(
        mutations: [m],
        currentSegments: [_seg('Hanoï', 4)],
        tripDurationDays: 4,
      );
      expect(batch, isA<BatchOk>());
    });
  });

  // ─── V2 fix Bangkok dupliqué ────────────────────────────────────────

  group('findAnchorIndexForSuggestion — multi-occurrence', () {
    SubTripSuggestion krabiMajor() => const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3)],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        );

    SubTripSuggestion ayutthayaDayTrip() => const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Ayutthaya',
          segments: [SuggestedSegment(city: 'Ayutthaya', days: 1)],
          insertionMode: InsertionMode.dayTrip,
        );

    test('majorDestination + 2 Bangkok → choisit le plus long', () {
      final segments = [
        _seg('Bangkok', 8), // BKK aller
        _seg('Phuket', 3),
        _seg('Bangkok', 22), // BKK retour, plus long
      ];
      final idx = findAnchorIndexForSuggestion(segments, krabiMajor());
      expect(idx, 2);
    });

    test('majorDestination + 1 seul Bangkok → premier match', () {
      final segments = [_seg('Bangkok', 11), _seg('Phú Quốc', 5)];
      final idx = findAnchorIndexForSuggestion(segments, krabiMajor());
      expect(idx, 0);
    });

    test('dayTrip (gateway category) + 2 Bangkok → premier match (legacy)',
        () {
      final segments = [
        _seg('Bangkok', 8),
        _seg('Phuket', 3),
        _seg('Bangkok', 22),
      ];
      final idx = findAnchorIndexForSuggestion(segments, ayutthayaDayTrip());
      expect(idx, 0);
    });

    test('majorDestination + Bangkok absent → -1', () {
      final segments = [_seg('Hanoï', 4)];
      final idx = findAnchorIndexForSuggestion(segments, krabiMajor());
      expect(idx, -1);
    });
  });

  group('findAllAnchorIndicesForSuggestion — multi-window', () {
    SubTripSuggestion krabi() => const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3)],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        );

    test('2 Bangkok → 2 indices retournés dans l\'ordre du voyage', () {
      final segments = [
        _seg('Bangkok', 11),
        _seg('Phú Quốc', 5),
        _seg('Hanoï', 4),
        _seg('Hội An', 3),
        _seg('Bangkok', 22),
      ];
      final indices = findAllAnchorIndicesForSuggestion(segments, krabi());
      expect(indices, [0, 4]);
    });

    test('1 Bangkok → 1 index', () {
      final segments = [_seg('Bangkok', 11)];
      final indices = findAllAnchorIndicesForSuggestion(segments, krabi());
      expect(indices, [0]);
    });

    test('aucun Bangkok → liste vide', () {
      final segments = [_seg('Hanoï', 4)];
      final indices = findAllAnchorIndicesForSuggestion(segments, krabi());
      expect(indices, isEmpty);
    });
  });

  group('computeMutation — anchorOverrideIndex', () {
    SubTripSuggestion krabi() => const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3)],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        );

    test('override=0 cible le 1er Bangkok (court) malgré la règle longest',
        () {
      final segments = [
        _seg('Bangkok', 11), // window 1
        _seg('Phú Quốc', 5),
        _seg('Bangkok', 22), // window 2 (long, sélectionné par défaut)
      ];
      final result = computeMutation(
        suggestion: krabi(),
        currentSegments: segments,
        tripDurationDays: 38,
        anchorOverrideIndex: 0,
      );
      final m = (result as MutationOk).mutation;
      expect(m.anchorIndex, 0);
      expect(m.anchorOccurrence, 1);
      expect(m.newAnchorDays, 8); // 11 - 3
    });

    test('override=2 cible le 2nd Bangkok (long)', () {
      final segments = [
        _seg('Bangkok', 11),
        _seg('Phú Quốc', 5),
        _seg('Bangkok', 22),
      ];
      final result = computeMutation(
        suggestion: krabi(),
        currentSegments: segments,
        tripDurationDays: 38,
        anchorOverrideIndex: 2,
      );
      final m = (result as MutationOk).mutation;
      expect(m.anchorIndex, 2);
      expect(m.anchorOccurrence, 2);
      expect(m.newAnchorDays, 19); // 22 - 3
    });

    test('override invalide (mauvaise ville) → fallback auto-resolve', () {
      final segments = [
        _seg('Bangkok', 11),
        _seg('Phú Quốc', 5),
        _seg('Bangkok', 22),
      ];
      // Index 1 = Phú Quốc, ne matche pas Bangkok → fallback longest.
      final result = computeMutation(
        suggestion: krabi(),
        currentSegments: segments,
        tripDurationDays: 38,
        anchorOverrideIndex: 1,
      );
      final m = (result as MutationOk).mutation;
      expect(m.anchorIndex, 2); // longest Bangkok
    });

    test('override hors bornes → fallback auto-resolve', () {
      final segments = [_seg('Bangkok', 11)];
      final result = computeMutation(
        suggestion: krabi(),
        currentSegments: segments,
        tripDurationDays: 11,
        anchorOverrideIndex: 99,
      );
      expect(result, isA<MutationOk>());
      expect((result as MutationOk).mutation.anchorIndex, 0);
    });
  });

  group('computeMutation — multi-occurrence majorDestination', () {
    test('Krabi visible sur le Bangkok long, pas le court — '
        'cas E2E rapport Lalith 2026-05-08', () {
      // Itinéraire local après refinements précédents :
      // Bangkok 8j + Rayong 1 + Koh Samet 2 + PQC 5 + Ninh Bình 3 +
      // Hanoï 1 + Hội An 3 + Bangkok 22.
      final segments = [
        _seg('Bangkok', 8),
        _seg('Rayong', 1),
        _seg('Koh Samet', 2),
        _seg('Phú Quốc', 5),
        _seg('Ninh Bình', 3),
        _seg('Hanoï', 1),
        _seg('Hội An', 3),
        _seg('Bangkok', 22),
      ];
      final result = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Krabi',
          segments: [SuggestedSegment(city: 'Krabi', days: 3)],
          insertionMode: InsertionMode.splitSegment,
          category: SuggestionCategory.majorDestination,
          minAnchorDaysToKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 45,
      );
      final m = (result as MutationOk).mutation;
      expect(m.anchorIndex, 7); // Bangkok long, pas Bangkok court
      expect(m.anchorOccurrence, 2);
    });
  });

  group('applyMutationBatch — re-localisation par occurrence', () {
    test('mutation sur Bangkok occurrence 2 cible bien le 2nd Bangkok '
        '(pas le 1er)', () {
      final segments = [
        _seg('Bangkok', 8),
        _seg('Phuket', 3),
        _seg('Bangkok', 22),
      ];
      // Mutation construite à la main pour viser explicitement
      // l'occurrence 2 (= Bangkok 22j).
      final mutation = ItineraryMutation(
        anchorIndex: 2,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 19,
        anchorOccurrence: 2,
      );
      final result = applyMutationBatch(segments, [mutation]);
      // Le 1er Bangkok (8j) doit rester intact, la mutation s'applique
      // sur le 2nd Bangkok.
      expect(result[0].city, 'Bangkok');
      expect(result[0].days, 8); // intact
      expect(result[1].city, 'Phuket');
      // Le 2nd Bangkok est split : insertion en début de bloc (pas de
      // pickedDate ici) → [Krabi 3, Bangkok 19].
      expect(result[2].city, 'Krabi');
      expect(result[3].city, 'Bangkok');
      expect(result[3].days, 19);
    });

    test('occurrence 1 cible bien le 1er Bangkok', () {
      final segments = [
        _seg('Bangkok', 8),
        _seg('Bangkok', 22),
      ];
      final mutation = ItineraryMutation(
        anchorIndex: 0,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 5,
        anchorOccurrence: 1,
      );
      final result = applyMutationBatch(segments, [mutation]);
      // 1er Bangkok split → [Krabi 3, Bangkok 5]. 2nd Bangkok intact.
      expect(result[0].city, 'Krabi');
      expect(result[1].city, 'Bangkok');
      expect(result[1].days, 5);
      expect(result[2].city, 'Bangkok');
      expect(result[2].days, 22);
    });

    test('occurrence introuvable (3 alors que seules 2 existent) → skip safe',
        () {
      final segments = [
        _seg('Bangkok', 8),
        _seg('Bangkok', 22),
      ];
      final mutation = ItineraryMutation(
        anchorIndex: 99,
        anchorCity: 'Bangkok',
        mode: InsertionMode.splitSegment,
        insertedSegments: [_seg('Krabi', 3)],
        newAnchorDays: 5,
        anchorOccurrence: 3,
      );
      final result = applyMutationBatch(segments, [mutation]);
      // Mutation skipée silencieusement : segments inchangés.
      expect(result.length, 2);
      expect(result[0].days, 8);
      expect(result[1].days, 22);
    });
  });

  // ─── V2 fix : APPEND ne doit pas shifter un segment aval pinné ───────

  group('computeMutation — wouldShiftPinnedDownstream', () {
    SubTripSuggestion hueNearbyStay() => const SubTripSuggestion(
          anchorCity: 'Da Nang',
          displayName: 'Hué',
          segments: [SuggestedSegment(city: 'Hué', days: 2)],
          insertionMode: InsertionMode.nearbyStay,
        );

    test('APPEND avec vol pinné aval (Da Nang→BKK 15/07) → consume from '
        'anchor (Da Nang 3 - Hué 2 = 1)', () {
      // Cas E2E rapport Lalith 2026-05-09 (rev) : la conversion en
      // consume-from-anchor remplace le rejet wouldShiftPinnedDownstream
      // initial. Da Nang a 3 jours, Hué prend 2 → Da Nang réduit à 1
      // jour, total inchangé, vol Da Nang→Bangkok 15/07 préservé.
      final segments = [
        _seg('Hanoï', 4),
        _seg('Da Nang', 3),
        _seg('Bangkok', 22),
      ];
      final tripStart = DateTime(2026, 7, 8);
      final docs = [
        TripDocument(
          id: 'f1',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.flight,
          name: 'Vol DAD→BKK',
          metadata: const {
            'from_city': 'Da Nang',
            'to_city': 'Bangkok',
            'date': '2026-07-15',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: docs,
      );
      final result = computeMutation(
        suggestion: hueNearbyStay(),
        currentSegments: segments,
        tripDurationDays: 35,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      // newAnchorDays set → la mutation est traitée en 3-way split par
      // applyMutation (anchor pre = 1, inserted Hué, no post).
      expect(m.newAnchorDays, 1);
      expect(m.insertionPreDays, 1);
      // mode reste nearbyStay pour l'UX (impact text inchangé).
      expect(m.mode, InsertionMode.nearbyStay);
    });

    test('APPEND avec downstream pinné MAIS anchor trop court → '
        'notEnoughDaysToSplit', () {
      // Da Nang 1 jour seulement, Hué veut 2 jours → impossible
      // d'absorber sans tomber à 0 jour anchor (interdit). Rejet
      // explicite avec raison appropriée.
      final segments = [
        _seg('Hanoï', 4),
        _seg('Da Nang', 1),
        _seg('Bangkok', 22),
      ];
      final tripStart = DateTime(2026, 7, 8);
      final docs = [
        TripDocument(
          id: 'f1',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.flight,
          name: 'Vol DAD→BKK',
          metadata: const {
            'from_city': 'Da Nang',
            'to_city': 'Bangkok',
            'date': '2026-07-13',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: docs,
      );
      final result = computeMutation(
        suggestion: hueNearbyStay(),
        currentSegments: segments,
        tripDurationDays: 35,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationFailed>());
      expect(
        (result as MutationFailed).reason,
        MutationFailureReason.notEnoughDaysToSplit,
      );
    });

    test('APPEND sans pinned aval → autorisé', () {
      final segments = [
        _seg('Hanoï', 4),
        _seg('Da Nang', 3),
      ];
      final tripStart = DateTime(2026, 7, 8);
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: const [],
      );
      final result = computeMutation(
        suggestion: hueNearbyStay(),
        currentSegments: segments,
        tripDurationDays: 9,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
    });

    test('APPEND quand l\'anchor est le dernier segment → autorisé '
        '(rien à shifter)', () {
      final segments = [
        _seg('Hanoï', 4),
        _seg('Da Nang', 3),
      ];
      final tripStart = DateTime(2026, 7, 8);
      final docs = [
        TripDocument(
          id: 'h1',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.hotel,
          name: 'Hôtel Da Nang',
          metadata: const {
            'address_city': 'Da Nang',
            'check_in': '2026-07-12',
            'check_out': '2026-07-15',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: docs,
      );
      final result = computeMutation(
        suggestion: hueNearbyStay(),
        currentSegments: segments,
        tripDurationDays: 9,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
    });

    test('APPEND avec hôtel aval pinné → consume from anchor (Da Nang '
        '3 - Hué 2 = 1)', () {
      // Hôtel Bangkok pinne Bangkok aval → APPEND Hué sur Da Nang
      // déclenche le mode consume-from-anchor (= Da Nang réduit à 1).
      final segments = [
        _seg('Hanoï', 4),
        _seg('Da Nang', 3),
        _seg('Bangkok', 22),
      ];
      final tripStart = DateTime(2026, 7, 8);
      final docs = [
        TripDocument(
          id: 'h1',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.hotel,
          name: 'Hôtel Bangkok',
          metadata: const {
            'address_city': 'Bangkok',
            'check_in': '2026-07-15',
            'check_out': '2026-07-20',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: docs,
      );
      final result = computeMutation(
        suggestion: hueNearbyStay(),
        currentSegments: segments,
        tripDurationDays: 35,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.newAnchorDays, 1);
      expect(m.insertionPreDays, 1);
    });

    test('APPEND avec hôtel base longue durée → ignoré dans la résolution '
        '(le hôtel base ne pinne pas le segment pour les insertions)', () {
      // L'appart Bangkok 22/06→06/08 couvre Bangkok aller + side-trip
      // PQC. Pour une insertion sur Bangkok aller, l'appart est isBase
      // → ne bloque pas. Mais Bangkok retour reste pinné via
      // hotelRanges base (le segment est ancré pour le drag-lock UI),
      // mais validateInsertionDate skip les bases. Régression test :
      // Ayutthaya 1n sur Bangkok aller (anchor 11) doit passer.
      final segments = [
        _seg('Bangkok', 11),
        _seg('Phú Quốc', 5),
        _seg('Bangkok', 22),
      ];
      final tripStart = DateTime(2026, 6, 22);
      final docs = [
        TripDocument(
          id: 'base',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.hotel,
          name: 'Appart Bangkok',
          metadata: const {
            'address_city': 'Bangkok',
            'check_in': '2026-06-22',
            'check_out': '2026-08-06',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
        TripDocument(
          id: 'fout',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.flight,
          name: 'Vol BKK→PQC',
          metadata: const {
            'from_city': 'Bangkok',
            'to_city': 'Phú Quốc',
            'date': '2026-07-03',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: docs,
      );
      // Vérification meta : l'appart Bangkok est bien classé base
      // (couvre des nuits Phú Quốc → phantom).
      final bkk1 = analysis.segments[0];
      expect(bkk1.hotelRanges.first.isBase, isTrue);

      // Ayutthaya 1n sur Bangkok aller — APPEND avec downstream pinné
      // (PQC, Bangkok retour). Conversion consume-from-anchor :
      // newAnchorDays = 11 - 1 = 10.
      final result = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Bangkok',
          displayName: 'Ayutthaya',
          segments: [SuggestedSegment(city: 'Ayutthaya', days: 1)],
          insertionMode: InsertionMode.dayTrip,
        ),
        currentSegments: segments,
        tripDurationDays: 46,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
      final m = (result as MutationOk).mutation;
      expect(m.newAnchorDays, 10);
      expect(m.insertionPreDays, 10);
    });

    test('Phase A — segments insérés portent sourceAnchorCity', () {
      // Pour APPEND, REPLACE et SPLIT, les segments matérialisés depuis
      // une suggestion doivent porter `sourceAnchorCity = anchor.city`
      // pour permettre le drag-lock par fenêtre dans la liste éditable.
      final segments = [_seg('Hanoï', 4)];
      // APPEND
      final appendResult = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Hanoï',
          displayName: 'Trang An',
          segments: [SuggestedSegment(city: 'Trang An', days: 1)],
          insertionMode: InsertionMode.dayTrip,
        ),
        currentSegments: segments,
        tripDurationDays: 5,
      );
      final appendMutation = (appendResult as MutationOk).mutation;
      expect(appendMutation.insertedSegments.first.sourceAnchorCity, 'Hanoï');

      // SPLIT
      final splitResult = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Hanoï',
          displayName: 'Ninh Bình',
          segments: [SuggestedSegment(city: 'Ninh Bình', days: 3)],
          insertionMode: InsertionMode.splitGatewaySequence,
          minAnchorDaysToKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 4,
      );
      final splitMutation = (splitResult as MutationOk).mutation;
      expect(splitMutation.insertedSegments.first.sourceAnchorCity, 'Hanoï');

      // REPLACE
      final replaceResult = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Hanoï',
          displayName: 'Hội An',
          segments: [SuggestedSegment(city: 'Hội An', days: 4)],
          insertionMode: InsertionMode.replaceAnchorGateway,
        ),
        currentSegments: segments,
        tripDurationDays: 4,
      );
      final replaceMutation = (replaceResult as MutationOk).mutation;
      expect(replaceMutation.insertedSegments.first.sourceAnchorCity, 'Hanoï');
    });

    test('Phase A — TripSegment JSON round-trip preserve sourceAnchorCity',
        () {
      const seg = TripSegment(
        city: 'Ninh Bình',
        days: 3,
        country: 'Vietnam',
        sourceAnchorCity: 'Hanoï',
      );
      final json = seg.toJson();
      expect(json['source_anchor_city'], 'Hanoï');
      final back = TripSegment.fromJson(json);
      expect(back.sourceAnchorCity, 'Hanoï');
      expect(back.city, 'Ninh Bình');
    });

    test('Phase A — TripSegment legacy JSON (sans source_anchor_city) → '
        'sourceAnchorCity null', () {
      final json = {'city': 'Paris', 'days': 3};
      final seg = TripSegment.fromJson(json);
      expect(seg.sourceAnchorCity, isNull);
    });

    test('SPLIT avec pinned aval → autorisé (preserve la durée totale, '
        'pas de shift)', () {
      final segments = [
        _seg('Hanoï', 4),
        _seg('Da Nang', 3),
        _seg('Bangkok', 22),
      ];
      final tripStart = DateTime(2026, 7, 8);
      final docs = [
        TripDocument(
          id: 'f1',
          userId: 'u',
          tripId: 't',
          category: DocumentCategory.flight,
          name: 'Vol DAD→BKK',
          metadata: const {
            'from_city': 'Da Nang',
            'to_city': 'Bangkok',
            'date': '2026-07-15',
          },
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final analysis = analyzePinnedDates(
        segments: segments,
        tripStartDate: tripStart,
        docs: docs,
      );
      final result = computeMutation(
        suggestion: const SubTripSuggestion(
          anchorCity: 'Da Nang',
          displayName: 'Hué',
          segments: [SuggestedSegment(city: 'Hué', days: 2)],
          insertionMode: InsertionMode.splitGatewaySequence,
          minAnchorDaysToKeep: 1,
        ),
        currentSegments: segments,
        tripDurationDays: 29,
        pinnedAnalysis: analysis,
      );
      expect(result, isA<MutationOk>());
    });
  });
}
