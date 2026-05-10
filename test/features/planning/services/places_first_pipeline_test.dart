import 'package:flutter_test/flutter_test.dart';
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
}
