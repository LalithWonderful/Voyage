import 'package:flutter_test/flutter_test.dart';
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
}
