/// Tests unitaires `itinerary_mutation.dart` (Lot 2.1).
///
/// Couverture : 3 modes (APPEND/SPLIT/REPLACE) × cas de succès + cas
/// d'échec (anchor introuvable, days insuffisants, free days
/// insuffisants). Plus quelques edge-cases : multi-step segments,
/// match accent-insensible, multi-occurrence anchor.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/data/sub_trip_suggestions.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/itinerary_mutation.dart';

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
}
