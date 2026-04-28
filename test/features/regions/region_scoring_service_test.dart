import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/regions/models/country_region.dart';
import 'package:voyage/features/regions/services/region_scoring_service.dart';

/// Fixture : 5 régions des USA avec leurs tags réels (cf. JSON asset V1).
final _usaRegions = const [
  CountryRegion(
    countryCode: 'US',
    countryName: 'États-Unis',
    regionName: 'New York & Côte Est',
    label: 'New York, Boston, Washington DC, Philadelphie',
    priority: 1,
    recommendedRadiusKm: 350,
    tags: ['city', 'culture', 'first_time', 'food', 'shopping'],
  ),
  CountryRegion(
    countryCode: 'US',
    countryName: 'États-Unis',
    regionName: 'Californie',
    label: 'Los Angeles, San Francisco, San Diego, Big Sur',
    priority: 2,
    recommendedRadiusKm: 550,
    tags: ['city', 'roadtrip', 'coast', 'shopping', 'food'],
  ),
  CountryRegion(
    countryCode: 'US',
    countryName: 'États-Unis',
    regionName: 'Ouest américain',
    label: 'Las Vegas, Grand Canyon, Utah, Arizona',
    priority: 3,
    recommendedRadiusKm: 700,
    tags: ['nature', 'roadtrip', 'parks', 'adventure'],
  ),
  CountryRegion(
    countryCode: 'US',
    countryName: 'États-Unis',
    regionName: 'Floride',
    label: 'Miami, Orlando, Keys, Everglades',
    priority: 4,
    recommendedRadiusKm: 450,
    tags: ['beach', 'family', 'theme_parks', 'nature'],
  ),
  CountryRegion(
    countryCode: 'US',
    countryName: 'États-Unis',
    regionName: 'Hawaï',
    label: 'Oahu, Maui, Big Island, Kauai',
    priority: 5,
    recommendedRadiusKm: 350,
    tags: ['beach', 'nature', 'honeymoon', 'relax'],
  ),
];

void main() {
  const service = RegionScoringService();

  group('RegionScoringService.scoreRegions', () {
    test('Famille USA + intérêt Plage → Floride en top (theme_parks + beach + family)', () {
      final scored = service.scoreRegions(
        regions: _usaRegions,
        userInterests: const ['Plage', 'Famille'],
        travelerType: 'Famille',
      );

      // Floride a tags = beach, family, theme_parks, nature
      // Plage → beach, coast, islands, diving, kitesurf, relax → match: beach (1)
      // Famille → family, theme_parks, beach, nature, first_time → match: beach, family, theme_parks, nature (4)
      // travelerType Famille → family, theme_parks, beach, nature, first_time → match: beach, family, theme_parks, nature (4)
      // score Floride = 5 (interest) × 1.0 + 4 (traveler) × 0.5 = 5.0 + 2.0 = 7.0
      // Pas de bonus first_time (2 interests, mais condition est < 3 donc 2 < 3 = TRUE)
      // → bonus seulement si first_time dans les tags. Floride n'a pas first_time.
      expect(scored.first.region.regionName, 'Floride');
      expect(scored.first.matchedTags, containsAll(['beach', 'family', 'theme_parks', 'nature']));
    });

    test('Couple Inde + Culture/Histoire → Rajasthan en top (culture, history, palaces, first_time)', () {
      final indiaRegions = const [
        CountryRegion(
          countryCode: 'IN',
          countryName: 'Inde',
          regionName: 'Rajasthan & Agra',
          label: 'Jaipur, Udaipur, Jodhpur, Jaisalmer, Agra',
          priority: 1,
          recommendedRadiusKm: 650,
          tags: ['culture', 'history', 'palaces', 'first_time'],
        ),
        CountryRegion(
          countryCode: 'IN',
          countryName: 'Inde',
          regionName: 'Kerala',
          label: 'Kochi, Alleppey, Munnar, Varkala',
          priority: 3,
          recommendedRadiusKm: 400,
          tags: ['nature', 'wellness', 'beach', 'slow_travel'],
        ),
        CountryRegion(
          countryCode: 'IN',
          countryName: 'Inde',
          regionName: 'Goa & Karnataka',
          label: 'Goa, Hampi, Gokarna, Mysore',
          priority: 4,
          recommendedRadiusKm: 500,
          tags: ['beach', 'relax', 'culture'],
        ),
      ];

      final scored = service.scoreRegions(
        regions: indiaRegions,
        userInterests: const ['Culture', 'Histoire'],
        travelerType: 'Couple',
      );

      // Rajasthan = culture, history, palaces, first_time
      // Culture → culture, history, monuments, palaces, ruins, museums, architecture → match: culture, history, palaces (3)
      // Histoire → history, culture, monuments, ruins, palaces → match: culture, history, palaces (3, dédup avec Culture donc set total = 3)
      // interest tags merged = {culture, history, monuments, palaces, ruins, museums, architecture}
      // intersection avec region tags = {culture, history, palaces} → 3 matches
      // traveler Couple → honeymoon, relax, wellness, wine, food, photo → match: () = 0
      // bonus first_time : userInterests.length=2 < 3 ET tags contient first_time → +0.3
      // score = 3 × 1.0 + 0 × 0.5 + 0.3 = 3.3
      expect(scored.first.region.regionName, 'Rajasthan & Agra');
      expect(scored.first.score, greaterThan(3.0));
      expect(scored.first.matchedTags, containsAll(['culture', 'history', 'palaces']));
    });

    test('Aucune préférence (0 interest, no travelerType) → bonus first_time départage', () {
      // Avec 0 préférence et pas de travelerType, le scoring est nul partout
      // SAUF que les régions avec `first_time` reçoivent +0.3.
      // On doit donc avoir une région avec first_time en tête (priority croissante en tie-breaker).
      final scored = service.scoreRegions(
        regions: _usaRegions,
        userInterests: const [],
        travelerType: null,
      );

      // New York (priority 1, first_time present) → score 0.3
      // Californie (priority 2, no first_time) → score 0.0
      // Ouest américain (priority 3, no first_time) → score 0.0
      // Floride (priority 4, no first_time) → score 0.0
      // Hawaï (priority 5, no first_time) → score 0.0
      expect(scored.first.region.regionName, 'New York & Côte Est');
      expect(scored.first.score, 0.3);

      // Les régions sans first_time partagent toutes le même score 0.0,
      // donc tie-breaker priority → Californie en 2e, etc.
      expect(scored[1].region.regionName, 'Californie');
      expect(scored[2].region.regionName, 'Ouest américain');
    });

    test('Bonus first_time inactif si userInterests.length >= 3', () {
      final scored = service.scoreRegions(
        regions: _usaRegions,
        // 3 intérêts → bonus DÉSACTIVÉ même sur région avec first_time
        userInterests: const ['Culture', 'Gastronomie', 'Shopping'],
        travelerType: null,
      );

      // New York = city, culture, first_time, food, shopping
      // Culture → culture, history, monuments, palaces, ruins, museums, architecture → match: culture (1)
      // Gastronomie → food, wine, culture → match: culture, food (2)
      // Shopping → shopping, city, food → match: city, food, shopping (3)
      // interest set fusionné = {culture, history, monuments, palaces, ruins, museums, architecture, food, wine, shopping, city}
      // intersection avec region tags = {city, culture, food, shopping} → 4 matches
      // traveler tags = {} → 0
      // bonus first_time : NON ACTIF (length=3 pas < 3)
      // score = 4 × 1.0 = 4.0 EXACTEMENT (pas 4.3)
      final ny = scored.firstWhere((s) => s.region.regionName == 'New York & Côte Est');
      expect(ny.score, 4.0);
    });
  });

  group('RegionScoringService.bestRegion', () {
    test('Retourne null sur liste vide', () {
      final best = service.bestRegion(
        regions: const [],
        userInterests: const ['Culture'],
        travelerType: 'Senior',
      );
      expect(best, isNull);
    });

    test('Retourne le top-1 du scoring complet', () {
      final best = service.bestRegion(
        regions: _usaRegions,
        userInterests: const ['Plage', 'Famille'],
        travelerType: 'Famille',
      );
      expect(best?.region.regionName, 'Floride');
    });
  });
}
