import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/data/destination_blueprints.dart';
import 'package:voyage/features/planning/data/metro_profile.dart';
import 'package:voyage/features/planning/data/segment_city_canonicals.dart';
import 'package:voyage/features/planning/services/day_builder.dart';
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';

/// Verrouille la compatibilité query↔intérêt utilisée pour filtrer les
/// `additionalTextQueries` du profil voyageur (Grand luxe, Couple, Backpack).
/// Cf. commit d603bb5 et `_premiumQueryCompatibilities` dans
/// `places_first_pipeline.dart`. Test Lalith 2026-05-08 : haute pollution
/// observée avec profil Grand luxe + budget élevé (luxury spa dans Événements,
/// fine dining dans Wellness, boutique hotel comme activité).
void main() {
  group('isProfileQueryCompatibleWithInterest', () {
    test('"luxury spa" est compatible Wellness, pas Événements', () {
      expect(
        isProfileQueryCompatibleWithInterest('luxury spa', 'Wellness'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('luxury spa', 'Événements'),
        isFalse,
      );
    });

    test('"fine dining" est compatible Gastronomie, pas Wellness/Plage', () {
      expect(
        isProfileQueryCompatibleWithInterest('fine dining', 'Gastronomie'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('fine dining', 'Wellness'),
        isFalse,
      );
      expect(
        isProfileQueryCompatibleWithInterest('fine dining', 'Plage'),
        isFalse,
      );
    });

    test('"Michelin" (casse) est compatible Gastronomie, pas Wellness', () {
      expect(
        isProfileQueryCompatibleWithInterest('Michelin', 'Gastronomie'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('Michelin', 'Wellness'),
        isFalse,
      );
    });

    test('"rooftop bar" est compatible Nightlife, pas Plage ni Wellness', () {
      expect(
        isProfileQueryCompatibleWithInterest('rooftop bar', 'Nightlife'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('rooftop bar', 'Plage'),
        isFalse,
      );
      expect(
        isProfileQueryCompatibleWithInterest('rooftop bar', 'Wellness'),
        isFalse,
      );
    });

    test('"boutique hotel" / "luxury hotel" / "hostel" jamais compatibles', () {
      const allInterests = [
        'Wellness',
        'Gastronomie',
        'Plage',
        'Nightlife',
        'Culture',
        'Spots populaires',
        'Hors circuit',
        'Bons plans',
        'Esthétique',
        'Couple',
        'Événements',
        'Nature',
        'Shopping',
        'Sports',
      ];
      for (final i in allInterests) {
        expect(
          isProfileQueryCompatibleWithInterest('boutique hotel', i),
          isFalse,
          reason: '"boutique hotel" ne doit jamais être proposé pour $i',
        );
        expect(
          isProfileQueryCompatibleWithInterest('luxury hotel', i),
          isFalse,
          reason: '"luxury hotel" ne doit jamais être proposé pour $i',
        );
        expect(
          isProfileQueryCompatibleWithInterest('hostel', i),
          isFalse,
          reason: '"hostel" ne doit jamais être proposé comme activité',
        );
      }
    });

    test('query inconnue de la map → permissif (default true)', () {
      expect(
        isProfileQueryCompatibleWithInterest('cuisine locale', 'Gastronomie'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('plage', 'Plage'),
        isTrue,
      );
    });

    test('"romantic restaurant" est compatible Couple/Gastronomie', () {
      expect(
        isProfileQueryCompatibleWithInterest('romantic restaurant', 'Couple'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest(
          'romantic restaurant',
          'Gastronomie',
        ),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest(
          'romantic restaurant',
          'Wellness',
        ),
        isFalse,
      );
    });

    test('"sunset spot" est compatible Nature/Couple, pas Nightlife', () {
      expect(
        isProfileQueryCompatibleWithInterest('sunset spot', 'Nature'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('sunset spot', 'Couple'),
        isTrue,
      );
      expect(
        isProfileQueryCompatibleWithInterest('sunset spot', 'Nightlife'),
        isFalse,
      );
    });
  });

  // V8 (Lalith 2026-05-10 — Phase Cost-2) — verrouille la signature pure
  // utilisée pour grouper les jours du voyage par centre Places. La
  // signature détermine combien de fetch Places sont déclenchés sur un
  // voyage : 2 jours dans la même ville → 1 fetch, 2 jours dans 2 villes
  // distinctes → 2 fetch.
  group('placesPoolSignature — Cost-2 grouping', () {
    DayCenter c(double lat, double lng, {String source = 'segment_city'}) =>
        DayCenter(latitude: lat, longitude: lng, source: source);

    test('mêmes lat/lng + radius + lang → même signature', () {
      final s1 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'fr');
      final s2 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'fr');
      expect(s1, s2);
    });

    test('lat/lng diffèrent au-delà de la 3e décimale → signatures différentes', () {
      // 0.001° de lat ≈ 110m. À ce niveau de granularité on sépare les
      // centres : deux hôtels à >110m ne partagent pas la même pool.
      final s1 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'fr');
      final s2 = placesPoolSignature(
          center: c(40.7138, -74.0060), radius: 600, languageCode: 'fr');
      expect(s1, isNot(s2));
    });

    test('lat/lng diffèrent en dessous de la 3e décimale → même signature', () {
      // Jitter d'hôtels à <55m : on collapse pour éviter les fetches
      // redondants. 40.71284 vs 40.71285 → arrondis tous deux à 40.713.
      final s1 = placesPoolSignature(
          center: c(40.71284, -74.00601), radius: 600, languageCode: 'fr');
      final s2 = placesPoolSignature(
          center: c(40.71285, -74.00609), radius: 600, languageCode: 'fr');
      expect(s1, s2);
    });

    test('source du centre n\'entre PAS dans la signature', () {
      // hotel vs segment_city sur les mêmes coords → fetch identique.
      final s1 = placesPoolSignature(
          center: c(40.7128, -74.0060, source: 'hotel'),
          radius: 600,
          languageCode: 'fr');
      final s2 = placesPoolSignature(
          center: c(40.7128, -74.0060, source: 'segment_city'),
          radius: 600,
          languageCode: 'fr');
      expect(s1, s2);
    });

    test('radius différent → signatures différentes', () {
      // Cas théorique : un voyage avec deux profils voyageurs successifs
      // (radius 600 puis 1500). Deux pools, deux groupes.
      final s1 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'fr');
      final s2 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 1500, languageCode: 'fr');
      expect(s1, isNot(s2));
    });

    test('langue différente → signatures différentes', () {
      // Places renvoie des `name` localisés. Pool fr ≠ pool en.
      final s1 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'fr');
      final s2 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'en');
      expect(s1, isNot(s2));
    });

    test('langue null → signature stable', () {
      final s1 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: null);
      final s2 = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: null);
      expect(s1, s2);
    });

    test('format lisible — contient lat/lng arrondis', () {
      // Sanity : si on cherche une signature dans les logs
      // `[places_pool_build]`, on doit pouvoir reconnaître les coords.
      final s = placesPoolSignature(
          center: c(40.7128, -74.0060), radius: 600, languageCode: 'fr');
      expect(s, contains('40.713'));
      expect(s, contains('-74.006'));
      expect(s, contains('r=600'));
      expect(s, contains('l=fr'));
    });
  });

  // V8.10 (Lalith 2026-05-10 — fix orphan-day Paris) — verrouille
  // la classification destination broad vs city. Le test garantit
  // que les villes (Paris, Tokyo, Bangkok, etc.) ne déclenchent pas
  // le skip orphan-day, et que les pays/régions le déclenchent.
  group('isBroadDestinationName — Q1B fix Paris', () {
    test('villes connues → city (false)', () {
      expect(isBroadDestinationName('Paris'), isFalse);
      expect(isBroadDestinationName('Tokyo'), isFalse);
      expect(isBroadDestinationName('Bangkok'), isFalse);
      expect(isBroadDestinationName('Lisbonne'), isFalse);
      expect(isBroadDestinationName('Rome'), isFalse);
      expect(isBroadDestinationName('New York'), isFalse);
      expect(isBroadDestinationName('Marrakech'), isFalse);
    });

    test('« City, Country » → first token compte (city)', () {
      // Format usuel saisi par les utilisateurs.
      expect(isBroadDestinationName('Paris, France'), isFalse);
      expect(isBroadDestinationName('Tokyo, Japon'), isFalse);
      expect(isBroadDestinationName('Bangkok, Thaïlande'), isFalse);
      expect(isBroadDestinationName('Lisboa, Portugal'), isFalse);
    });

    test('pays/régions seuls → broad (true)', () {
      expect(isBroadDestinationName('France'), isTrue);
      expect(isBroadDestinationName('Thaïlande'), isTrue);
      expect(isBroadDestinationName('Thailand'), isTrue);
      expect(isBroadDestinationName('Brésil'), isTrue);
      expect(isBroadDestinationName('Brazil'), isTrue);
      expect(isBroadDestinationName('Vietnam'), isTrue);
      expect(isBroadDestinationName('USA'), isTrue);
      expect(isBroadDestinationName('États-Unis'), isTrue);
      expect(isBroadDestinationName('Asie du Sud-Est'), isTrue);
      expect(isBroadDestinationName('Southeast Asia'), isTrue);
      expect(isBroadDestinationName('Europe'), isTrue);
      expect(isBroadDestinationName('Caraïbes'), isTrue);
    });

    test('insensible casse', () {
      expect(isBroadDestinationName('paris'), isFalse);
      expect(isBroadDestinationName('PARIS'), isFalse);
      expect(isBroadDestinationName('FRANCE'), isTrue);
      expect(isBroadDestinationName('thailand'), isTrue);
    });

    test('insensible accents', () {
      expect(isBroadDestinationName('Brésil'), isTrue);
      expect(isBroadDestinationName('Bresil'), isTrue);
      expect(isBroadDestinationName('Thaïlande'), isTrue);
      expect(isBroadDestinationName('Thailande'), isTrue);
      expect(isBroadDestinationName('Égypte'), isTrue);
      expect(isBroadDestinationName('Egypte'), isTrue);
    });

    test('null ou vide → broad (safe default préserve protection anti-filler)', () {
      expect(isBroadDestinationName(null), isTrue);
      expect(isBroadDestinationName(''), isTrue);
      expect(isBroadDestinationName('   '), isTrue);
    });

    test('whitespace autour → trim correctement', () {
      expect(isBroadDestinationName('  Paris  '), isFalse);
      expect(isBroadDestinationName('  France  '), isTrue);
    });
  });

  // V8.13 (Lalith 2026-05-10 — Quality-1D destination blueprints) —
  // verrouille le lookup blueprint. Le résultat drive le seeding de
  // la pool avec must-sees/experiences avant la génération du planning,
  // donc la stabilité de cette résolution est critique.
  group('getBlueprintForDestination — Q1D blueprints lookup', () {
    test('Bangkok variants → bangkok blueprint', () {
      final b = getBlueprintForDestination('Bangkok');
      expect(b, isNotNull);
      expect(b!.destinationKey, 'bangkok');
      expect(b.kind, DestinationKind.majorCity);
      expect(b.mustSeeQueries, isNotEmpty);
      expect(b.mustSeeQueries.any((q) => q.contains('Grand Palace')), isTrue);
    });

    test('« Bangkok, Thailand » → bangkok via first token', () {
      final b = getBlueprintForDestination('Bangkok, Thailand');
      expect(b?.destinationKey, 'bangkok');
    });

    test('« Krung Thep » → bangkok (variant)', () {
      // Nom officiel thaï de Bangkok.
      final b = getBlueprintForDestination('Krung Thep');
      expect(b?.destinationKey, 'bangkok');
    });

    test('« BKK » abréviation → bangkok', () {
      final b = getBlueprintForDestination('BKK');
      expect(b?.destinationKey, 'bangkok');
    });

    test('Koh Samet variants → koh samet blueprint', () {
      expect(getBlueprintForDestination('Koh Samet')?.destinationKey,
          'koh samet');
      expect(getBlueprintForDestination('Ko Samet')?.destinationKey,
          'koh samet');
      expect(
          getBlueprintForDestination('Samet')?.destinationKey, 'koh samet');
    });

    test('Koh Samet → islandBeach kind', () {
      final b = getBlueprintForDestination('Koh Samet');
      expect(b?.kind, DestinationKind.islandBeach);
    });

    test('Paris variants → paris blueprint', () {
      expect(getBlueprintForDestination('Paris')?.destinationKey, 'paris');
      expect(getBlueprintForDestination('Paris, France')?.destinationKey,
          'paris');
      expect(getBlueprintForDestination('paris')?.destinationKey, 'paris');
      expect(getBlueprintForDestination('PARIS')?.destinationKey, 'paris');
    });

    test('Paris must-sees contiennent les iconiques', () {
      final b = getBlueprintForDestination('Paris');
      expect(b, isNotNull);
      expect(b!.mustSeeQueries.any((q) => q.contains('Louvre')), isTrue);
      expect(b.mustSeeQueries.any((q) => q.contains('Eiffel Tower')), isTrue);
      expect(b.mustSeeQueries.any((q) => q.contains('Notre-Dame')), isTrue);
    });

    test('insensible accents — « Marseillé » non match (city pas blueprint)', () {
      // Marseille n'est PAS dans les blueprints V1 → null.
      // Utile pour vérifier que le default null fonctionne.
      expect(getBlueprintForDestination('Marseille'), isNull);
    });

    test('destinations broad (pays) → null (pas de blueprint pays)', () {
      expect(getBlueprintForDestination('France'), isNull);
      expect(getBlueprintForDestination('Thailand'), isNull);
      expect(getBlueprintForDestination('Brazil'), isNull);
    });

    test('null / vide → null', () {
      expect(getBlueprintForDestination(null), isNull);
      expect(getBlueprintForDestination(''), isNull);
      expect(getBlueprintForDestination('   '), isNull);
    });

    test('destination inconnue → null', () {
      expect(getBlueprintForDestination('Vladivostok'), isNull);
      expect(getBlueprintForDestination('Random City XYZ'), isNull);
    });

    test('markers blueprint sont distincts et non vides', () {
      // Évite les régressions style « les deux markers retournent
      // la même string » (silencieux mais kill le boost).
      expect(blueprintMustSeeMarker, isNotEmpty);
      expect(blueprintExperienceMarker, isNotEmpty);
      expect(blueprintMustSeeMarker == blueprintExperienceMarker, isFalse);
      // Préfixe `_` garantit non-collision avec les vrais intérêts
      // user-facing (Culture, Nature, Shopping, etc.).
      expect(blueprintMustSeeMarker.startsWith('_'), isTrue);
      expect(blueprintExperienceMarker.startsWith('_'), isTrue);
    });

    // V8.28a — sanity 5 nouvelles métropoles.
    test('V8.28a — Tokyo blueprint kind=majorCity', () {
      final bp = getBlueprintForDestination('Tokyo');
      expect(bp, isNotNull);
      expect(bp!.kind, DestinationKind.majorCity);
      expect(bp.mustSeeQueries.length, greaterThanOrEqualTo(8));
    });

    test('V8.28a — New York blueprint avec aliases NYC / Manhattan', () {
      final bp = getBlueprintForDestination('New York');
      expect(bp, isNotNull);
      expect(bp!.kind, DestinationKind.majorCity);
      expect(getBlueprintForDestination('NYC')?.destinationKey, 'new york');
      expect(getBlueprintForDestination('Manhattan')?.destinationKey,
          'new york');
      expect(getBlueprintForDestination('New York City')?.destinationKey,
          'new york');
    });

    test('V8.28a — London / Rome / Istanbul blueprints + aliases', () {
      expect(getBlueprintForDestination('London')?.kind,
          DestinationKind.majorCity);
      expect(getBlueprintForDestination('Londres')?.destinationKey,
          'london');
      expect(getBlueprintForDestination('Rome')?.kind,
          DestinationKind.majorCity);
      expect(getBlueprintForDestination('Roma')?.destinationKey, 'rome');
      expect(getBlueprintForDestination('Istanbul')?.kind,
          DestinationKind.majorCity);
      expect(getBlueprintForDestination('Constantinople')?.destinationKey,
          'istanbul');
    });

    test('V8.28a — getMetroProfileForCluster retourne le bon profile '
        'pour chaque centre canonique', () {
      // Tokyo : Shibuya area.
      expect(getMetroProfileForCluster(35.6762, 139.6503)?.cityKey, 'tokyo');
      // NYC : Times Square.
      expect(getMetroProfileForCluster(40.7589, -73.9851)?.cityKey,
          'new york');
      // London : Westminster.
      expect(getMetroProfileForCluster(51.5074, -0.1278)?.cityKey, 'london');
      // Rome : Pantheon area.
      expect(getMetroProfileForCluster(41.9028, 12.4964)?.cityKey, 'rome');
      // Istanbul : Sultanahmet.
      expect(getMetroProfileForCluster(41.0082, 28.9784)?.cityKey,
          'istanbul');
      // Hors zone : null.
      expect(getMetroProfileForCluster(0.0, 0.0), isNull);
    });

    // V8.28b — sanity +5 villes mégalopoles.
    test('V8.28b — Séoul blueprint + aliases', () {
      final bp = getBlueprintForDestination('Seoul');
      expect(bp, isNotNull);
      expect(bp!.kind, DestinationKind.majorCity);
      expect(bp.destinationKey, 'seoul');
      expect(bp.mustSeeQueries.length, greaterThanOrEqualTo(8));
      expect(getBlueprintForDestination('Séoul')?.destinationKey, 'seoul');
      expect(getBlueprintForDestination('Seul')?.destinationKey, 'seoul');
    });

    test('V8.28b — Barcelone blueprint + aliases', () {
      final bp = getBlueprintForDestination('Barcelona');
      expect(bp, isNotNull);
      expect(bp!.destinationKey, 'barcelona');
      expect(bp.kind, DestinationKind.majorCity);
      expect(getBlueprintForDestination('Barcelone')?.destinationKey,
          'barcelona');
      expect(getBlueprintForDestination('BCN')?.destinationKey, 'barcelona');
      expect(getBlueprintForDestination('Barça')?.destinationKey,
          'barcelona');
    });

    test('V8.28b — Lisbonne blueprint + aliases', () {
      final bp = getBlueprintForDestination('Lisbon');
      expect(bp, isNotNull);
      expect(bp!.destinationKey, 'lisbon');
      expect(bp.kind, DestinationKind.majorCity);
      expect(getBlueprintForDestination('Lisbonne')?.destinationKey,
          'lisbon');
      expect(getBlueprintForDestination('Lisboa')?.destinationKey, 'lisbon');
    });

    test('V8.28b — Ho Chi Minh blueprint + aliases (Saigon / HCM / HCMC)',
        () {
      final bp = getBlueprintForDestination('Ho Chi Minh');
      expect(bp, isNotNull);
      expect(bp!.destinationKey, 'ho chi minh');
      expect(bp.kind, DestinationKind.majorCity);
      expect(getBlueprintForDestination('Ho Chi Minh City')?.destinationKey,
          'ho chi minh');
      expect(getBlueprintForDestination('Saigon')?.destinationKey,
          'ho chi minh');
      expect(getBlueprintForDestination('HCMC')?.destinationKey,
          'ho chi minh');
      expect(getBlueprintForDestination('HCM')?.destinationKey,
          'ho chi minh');
    });

    test('V8.28b — Singapour blueprint + aliases', () {
      final bp = getBlueprintForDestination('Singapore');
      expect(bp, isNotNull);
      expect(bp!.destinationKey, 'singapore');
      expect(bp.kind, DestinationKind.majorCity);
      expect(getBlueprintForDestination('Singapour')?.destinationKey,
          'singapore');
      expect(getBlueprintForDestination('SG')?.destinationKey, 'singapore');
    });

    test('V8.28b — getMetroProfileForCluster pour les 5 nouvelles villes',
        () {
      // Séoul : Gyeongbokgung area.
      expect(getMetroProfileForCluster(37.5665, 126.9780)?.cityKey,
          'seoul');
      // Barcelone : centre.
      expect(getMetroProfileForCluster(41.3851, 2.1734)?.cityKey,
          'barcelona');
      // Lisbonne : Praça do Comércio area.
      expect(getMetroProfileForCluster(38.7223, -9.1393)?.cityKey,
          'lisbon');
      // HCM : District 1.
      expect(getMetroProfileForCluster(10.7769, 106.7009)?.cityKey,
          'ho chi minh');
      // Singapour : Marina Bay area.
      expect(getMetroProfileForCluster(1.3521, 103.8198)?.cityKey,
          'singapore');
    });

    test('V8.28b — MetroProfile.isMegaCity=true pour les 5 nouvelles',
        () {
      for (final city in [
        'seoul', 'barcelona', 'lisbon', 'ho chi minh', 'singapore',
      ]) {
        final profile = metroProfiles.firstWhere((p) => p.cityKey == city);
        expect(profile.isMegaCity, isTrue,
            reason: '$city doit être isMegaCity=true (cap 5 km '
                'maxTransitionKm activé)');
        expect(profile.zones.length, greaterThanOrEqualTo(4),
            reason: '$city doit avoir ≥4 zones (oldCity/riverside/'
                'market/modern)');
        expect(profile.touristAnchors.length, greaterThanOrEqualTo(7),
            reason: '$city doit avoir ≥7 tourist anchors curated');
      }
    });
  });

  group('V8.28f2 isRestaurantDisguisedForVisit', () {
    // V8.28f2 — bug Florence : Antica Trattoria da Tito dal 1913 sortait
    // à 09:30 comme « Culture » car primary=historical_landmark masquait
    // le secondary italian_restaurant. Détection étendue à ANY position
    // avec exception curated (blueprint/metroAnchor) et exception
    // marché emblématique.

    NearbyCandidate make({
      required String name,
      required List<String> types,
    }) =>
        NearbyCandidate(
          placeId: name.toLowerCase(),
          name: name,
          latitude: 0,
          longitude: 0,
          types: types,
        );

    test('Antica Trattoria primary=historical_landmark + secondary '
        'italian_restaurant → disguised (true)', () {
      final c = make(
        name: 'Antica Trattoria da Tito dal 1913',
        types: ['historical_landmark', 'night_club', 'italian_restaurant'],
      );
      expect(isRestaurantDisguisedForVisit(c, const []), isTrue,
          reason: 'italian_restaurant en secondaire doit déclencher le '
              'rejet (V8.28f2 any-position)');
    });

    test('Restaurant primary sans market context (legacy V8.7) → true',
        () {
      // Note : `tourist_attraction` figure dans _qualityMarketTravelTypes
      // donc un resto avec ce tag passerait (exception marché). Pour
      // tester la règle pure, on prend un resto sans aucun co-tag
      // marché.
      final c = make(
        name: 'Le Petit Bistrot',
        types: ['french_restaurant', 'point_of_interest'],
      );
      expect(isRestaurantDisguisedForVisit(c, const []), isTrue);
    });

    test('Pâtisserie primary (V8.28f2 addition) → true', () {
      final c = make(
        name: 'Pâtisserie Stohrer',
        types: ['pastry_shop', 'tourist_attraction'],
      );
      // tourist_attraction est dans _qualityMarketTravelTypes →
      // hasMarketContext=true → pas disguised. Edge case mais cohérent
      // avec V8.7 (marché emblématique). Pour patisserie sans tourist
      // tag :
      final c2 = make(
        name: 'Boulangerie du coin',
        types: ['pastry_shop', 'point_of_interest'],
      );
      expect(isRestaurantDisguisedForVisit(c, const []), isFalse,
          reason: 'pastry_shop + tourist_attraction → exception '
              'marché emblématique V8.7');
      expect(isRestaurantDisguisedForVisit(c2, const []), isTrue,
          reason: 'pastry_shop sans market context → disguised');
    });

    test('Marché touristique reste accepté (Borough Market) → false', () {
      // Borough Market : market + tourist_attraction + food_court.
      final c = make(
        name: 'Borough Market',
        types: ['market', 'tourist_attraction', 'food_court'],
      );
      expect(isRestaurantDisguisedForVisit(c, const []), isFalse,
          reason: 'food_court + market + tourist_attraction → exception '
              'marché V8.7 préservée');
    });

    test('Marché alimentaire farmers_market reste accepté → false', () {
      final c = make(
        name: 'Smorgasburg',
        types: ['farmers_market', 'food_court', 'food'],
      );
      expect(isRestaurantDisguisedForVisit(c, const []), isFalse);
    });

    test('Exception curated : blueprintMustSeeMarker accepte même '
        'avec italian_restaurant → false', () {
      // Cas hypothétique : un must-see curated avec un type food en
      // secondaire (ex: « Erawan Tea Room » dans un blueprint Bangkok).
      // Le curated wins, on garde.
      final c = make(
        name: 'Some Curated MustSee',
        types: ['historical_landmark', 'italian_restaurant'],
      );
      expect(
          isRestaurantDisguisedForVisit(c, const [blueprintMustSeeMarker]),
          isFalse,
          reason: 'must-see blueprint doit pouvoir porter type food '
              'secondaire (curated wins)');
    });

    test('Exception curated : blueprintExperienceMarker accepte → false',
        () {
      // Khaosan Road : tourist_attraction + bar typique. On ne veut
      // pas la rejeter à cause du `bar`.
      final c = make(
        name: 'Khaosan Road',
        types: ['tourist_attraction', 'bar'],
      );
      // (bar n'est pas dans _qualityFinalFoodTypes mais simulons le cas)
      final c2 = make(
        name: 'Khaosan Food Street',
        types: ['tourist_attraction', 'food'],
      );
      expect(
          isRestaurantDisguisedForVisit(
              c, const [blueprintExperienceMarker]),
          isFalse);
      // Même c2 avec `food` direct passe via curated (tourist_attraction
      // aussi neutralise, mais on vérifie quand même la priorité curated).
      expect(
          isRestaurantDisguisedForVisit(
              c2, const [blueprintExperienceMarker]),
          isFalse);
    });

    test('Exception curated : metroAnchorMarker accepte → false', () {
      // Fan-out V8.28d peut ramener un lieu type "food" légitime
      // (rare mais possible). Le marker garantit qu'il vient d'une
      // ancre tourisme curée → on garde.
      final c = make(
        name: 'Some metro anchor result',
        types: ['cafe', 'tourist_attraction'],
      );
      expect(
          isRestaurantDisguisedForVisit(c, const [metroAnchorMarker]),
          isFalse);
    });

    test('Lieu sans food type → false (pas disguised)', () {
      final c = make(
        name: 'Colosseum',
        types: ['tourist_attraction', 'historical_landmark', 'monument'],
      );
      expect(isRestaurantDisguisedForVisit(c, const []), isFalse);
    });

    test('Cafe primary sans market/curated → true (régression V8.7)', () {
      final c = make(name: 'Random Cafe', types: ['cafe']);
      expect(isRestaurantDisguisedForVisit(c, const []), isTrue);
    });
  });

  group('V8.28b1 Singapore hardening', () {
    // V8.28b1 — Singapore-specific filters.

    final singapore =
        getMetroProfileForCluster(1.3521, 103.8198)!;
    final tokyo = getMetroProfileForCluster(35.6812, 139.7671)!;

    NearbyCandidate make({
      required String name,
      List<String> types = const ['tourist_attraction'],
      String? address,
    }) =>
        NearbyCandidate(
          placeId: name.toLowerCase().replaceAll(' ', '_'),
          name: name,
          latitude: 0,
          longitude: 0,
          types: types,
          address: address,
        );

    group('A — out-of-country (Singapour vs Johor)', () {
      test('Singapore MetroProfile contient les patterns Johor/Malaysia',
          () {
        expect(singapore.blockedAddressPatterns,
            containsAll(['malaysia', 'johor']));
      });

      test('Candidat avec adresse "Johor Bahru, Malaysia" → rejeté '
          'sur Singapore', () {
        final c = make(
          name: 'KSL City Mall',
          address: 'Lebuh Daya Bumi, Johor Bahru, Johor Darul Ta\'zim, '
              'Malaysia',
        );
        expect(
            isCandidateAddressBlocked(
                c, singapore.blockedAddressPatterns),
            isTrue);
      });

      test('Candidat avec adresse Singapore valide → accepté', () {
        final c = make(
          name: 'Merlion Park',
          address: '1 Fullerton Rd, Singapore 049213',
        );
        expect(
            isCandidateAddressBlocked(
                c, singapore.blockedAddressPatterns),
            isFalse);
      });

      test('Gardens by the Bay (Singapore address) → accepté', () {
        final c = make(
          name: 'Gardens by the Bay',
          address: '18 Marina Gardens Dr, Singapore 018953',
        );
        expect(
            isCandidateAddressBlocked(
                c, singapore.blockedAddressPatterns),
            isFalse);
      });

      test('National Museum Singapore → accepté', () {
        final c = make(
          name: 'National Museum of Singapore',
          address: '93 Stamford Rd, Singapore 178897',
        );
        expect(
            isCandidateAddressBlocked(
                c, singapore.blockedAddressPatterns),
            isFalse);
      });

      test('JBCC / KSL City / KOMTAR patterns → tous rejetés', () {
        final cases = [
          ('Persada Johor', 'Persada Johor International Convention'),
          ('KSL Resort', 'KSL City, Johor Bahru'),
          ('KOMTAR JBCC', 'KOMTAR JBCC, Johor Bahru'),
        ];
        for (final entry in cases) {
          final c = make(name: entry.$1, address: entry.$2);
          expect(
              isCandidateAddressBlocked(
                  c, singapore.blockedAddressPatterns),
              isTrue,
              reason: 'address "${entry.$2}" doit être rejetée');
        }
      });

      test('Pas de blocage hors Singapour (Tokyo profile = empty)', () {
        // Tokyo n'a pas de blockedAddressPatterns → un candidat avec
        // une adresse Johor ne devrait pas être rejeté par ce
        // filter (mais il serait rejeté autrement, hors scope).
        final c = make(
          name: 'KSL City Mall',
          address: 'Johor Bahru, Malaysia',
        );
        expect(
            isCandidateAddressBlocked(c, tokyo.blockedAddressPatterns),
            isFalse,
            reason: 'Tokyo n\'a pas de blockedAddressPatterns → '
                'pas de rejet par ce filter');
      });

      test('Candidat sans address → not blocked (no signal)', () {
        final c = make(name: 'No Address Place');
        expect(
            isCandidateAddressBlocked(
                c, singapore.blockedAddressPatterns),
            isFalse);
      });
    });

    group('C — hawker centres visit-slot blocked', () {
      test('Singapore MetroProfile contient les patterns hawker', () {
        expect(singapore.visitBlockedNamePatterns,
            containsAll(['lau pa sat', 'maxwell food centre']));
      });

      test('Lau Pa Sat (tourist_attraction + food) → blocked visit-slot',
          () {
        final c = make(
          name: 'Lau Pa Sat',
          types: ['tourist_attraction', 'restaurant', 'food'],
        );
        expect(
            isCandidateNameVisitBlocked(
                c, singapore.visitBlockedNamePatterns),
            isTrue);
      });

      test('Maxwell Food Centre → blocked visit-slot', () {
        final c = make(
          name: 'Maxwell Food Centre',
          types: ['tourist_attraction', 'food_court'],
        );
        expect(
            isCandidateNameVisitBlocked(
                c, singapore.visitBlockedNamePatterns),
            isTrue);
      });

      test('Hong Lim Market & Food Centre → blocked visit-slot', () {
        final c = make(
          name: 'Hong Lim Market & Food Centre',
          types: ['food_court'],
        );
        expect(
            isCandidateNameVisitBlocked(
                c, singapore.visitBlockedNamePatterns),
            isTrue);
      });

      test('Generic "Food Centre" → blocked (catch-all)', () {
        final c = make(
          name: 'Random Food Centre Singapore',
          types: ['food_court'],
        );
        expect(
            isCandidateNameVisitBlocked(
                c, singapore.visitBlockedNamePatterns),
            isTrue);
      });

      test('Chinatown Singapore (touristique, pas food centre) → '
          'pas blocked', () {
        final c = make(
          name: 'Chinatown Singapore',
          types: ['tourist_attraction'],
        );
        expect(
            isCandidateNameVisitBlocked(
                c, singapore.visitBlockedNamePatterns),
            isFalse);
      });

      test('Merlion Park → pas blocked', () {
        final c = make(name: 'Merlion Park');
        expect(
            isCandidateNameVisitBlocked(
                c, singapore.visitBlockedNamePatterns),
            isFalse);
      });

      test('Hors Singapore (Tokyo profile) : Lau Pa Sat ne serait pas '
          'blocked par ce filter (mais voyage Tokyo n\'a pas Lau Pa Sat '
          'dans le pool, hors scope simu réelle)', () {
        final c = make(name: 'Lau Pa Sat');
        expect(
            isCandidateNameVisitBlocked(
                c, tokyo.visitBlockedNamePatterns),
            isFalse);
      });
    });

    test('Singapore MetroProfile : 5 zones spécifiques + 4 legacy disabled',
        () {
      expect(
          singapore.disabledArchetypes,
          containsAll([
            DayPackType.oldCityDay,
            DayPackType.riversideDay,
            DayPackType.marketDay,
            DayPackType.modernDay,
          ]));
      final zoneTypes = singapore.zones.map((z) => z.type).toSet();
      expect(
          zoneTypes,
          containsAll([
            DayPackType.singaporeMarinaBayDay,
            DayPackType.singaporeSentosaDay,
            DayPackType.singaporeChinatownCivicDay,
            DayPackType.singaporeOrchardBotanicDay,
            DayPackType.singaporeKampongGlamLittleIndiaDay,
          ]));
    });
  });

  group('V8.28b1.2 Singapore extended hardening', () {
    // V8.28b1.2 — extensions du Singapore hardening :
    // - Patterns Indonésie ajoutés à blockedAddressPatterns
    //   (Bintan/Batam frontière Sud).
    // - Canonical "Singapore" pour clean segment resolution.
    // - Fallback trip-destination MetroProfile au pipeline (testé
    //   indirectement via les patterns présents).

    final singapore = getMetroProfileForCluster(1.3521, 103.8198)!;

    NearbyCandidate make({
      required String name,
      List<String> types = const ['tourist_attraction'],
      String? address,
    }) =>
        NearbyCandidate(
          placeId: name.toLowerCase().replaceAll(' ', '_'),
          name: name,
          latitude: 0,
          longitude: 0,
          types: types,
          address: address,
        );

    test('A2 — Singapore.blockedAddressPatterns inclut Indonésie/Bintan/'
        'Batam (V8.28b1.2)', () {
      expect(
          singapore.blockedAddressPatterns,
          containsAll([
            'indonesia',
            'bintan',
            'batam',
            'lagoi',
            'tanjung pinang',
            'kepulauan riau',
            'riau islands',
          ]));
    });

    test('A2 — Candidat à Bintan (Indonesia) → rejeté', () {
      final c = make(
        name: 'Bintan Lagoi Resort',
        address: 'Jalan Perigi Raja, Lagoi, Bintan, Kepulauan Riau, '
            'Indonesia',
      );
      expect(
          isCandidateAddressBlocked(
              c, singapore.blockedAddressPatterns),
          isTrue);
    });

    test('A2 — Candidat à Batam → rejeté', () {
      final c = make(
        name: 'Batam Centre Mall',
        address: 'Batam, Kepulauan Riau, Indonesia',
      );
      expect(
          isCandidateAddressBlocked(
              c, singapore.blockedAddressPatterns),
          isTrue);
    });

    test('A2 — Candidat à Tanjung Pinang → rejeté', () {
      final c = make(
        name: 'Vihara Ksitigarbha Bodhisattva',
        address: 'Tanjung Pinang, Kepulauan Riau, Indonesia',
      );
      expect(
          isCandidateAddressBlocked(
              c, singapore.blockedAddressPatterns),
          isTrue);
    });

    test('A2 — Singapore valide reste accepté malgré nouveaux patterns',
        () {
      final c = make(
        name: 'Gardens by the Bay',
        address: '18 Marina Gardens Dr, Singapore 018953',
      );
      expect(
          isCandidateAddressBlocked(
              c, singapore.blockedAddressPatterns),
          isFalse);
    });

    test('A3 — Canonical "singapore" résout sur (1.3521, 103.8198)', () {
      final canonical = getCanonicalSegmentCity('Singapore');
      expect(canonical, isNotNull);
      expect(canonical!.expectedLat, closeTo(1.3521, 0.01));
      expect(canonical.expectedLng, closeTo(103.8198, 0.01));
      expect(canonical.countryCode, 'sg');
    });

    test('A3 — Canonical "singapour" (FR) résout pareil', () {
      final canonical = getCanonicalSegmentCity('Singapour');
      expect(canonical, isNotNull);
      expect(canonical!.expectedLat, closeTo(1.3521, 0.01));
      expect(canonical.expectedLng, closeTo(103.8198, 0.01));
    });

    test('A3 — Canonical case-insensitive ("SINGAPORE")', () {
      final canonical = getCanonicalSegmentCity('SINGAPORE');
      expect(canonical, isNotNull);
      expect(canonical!.canonicalQuery, 'Singapore');
    });

    test('A3 — Canonical resolve avec country fourni ne casse pas', () {
      final canonical =
          getCanonicalSegmentCity('Singapore', country: 'Singapore');
      // Pas de match composé "singapore, singapore" mais fallback
      // sur "singapore" seul.
      expect(canonical, isNotNull);
      expect(canonical!.expectedLat, closeTo(1.3521, 0.01));
    });

    test('A1 — Singapore trip destination résout vers le MetroProfile '
        'Singapore (via blueprint + registry lookup)', () {
      // Simule la résolution dans le pipeline V8.28b1.2 :
      // trip.destination -> getBlueprintForDestination ->
      // metroProfiles.firstWhere(cityKey)
      final blueprint = getBlueprintForDestination('Singapore');
      expect(blueprint, isNotNull);
      expect(blueprint!.destinationKey, 'singapore');

      MetroProfile? resolved;
      for (final p in metroProfiles) {
        if (p.cityKey == blueprint.destinationKey) {
          resolved = p;
          break;
        }
      }
      expect(resolved, isNotNull);
      expect(resolved!.cityKey, 'singapore');
      expect(resolved.blockedAddressPatterns, contains('indonesia'),
          reason: 'Le MetroProfile résolu doit avoir les patterns '
              'V8.28b1.2 (Indonésie) pour appliquer le filtre fallback');
    });

    test('A1 — Trip avec destination "Singapour" (FR) résout pareil', () {
      final blueprint = getBlueprintForDestination('Singapour');
      expect(blueprint?.destinationKey, 'singapore');
    });
  });
}
