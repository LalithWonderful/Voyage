import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/data/destination_blueprints.dart';
import 'package:voyage/features/planning/data/metro_profile.dart';
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';

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
  });
}
