// Phase 1 / Tâche 1.2 — Tests des données Singapour DestinationIntelligence.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places. Vérifient :
//   - l'objet Singapour passe la validation
//   - les champs essentiels sont conformes à la spec
//   - les 10 zones sont présentes
//   - les 15 anchors sont présents (avec subset minimum vérifié)
//   - les règles transport sont cohérentes mégacité
//   - round-trip JSON conservé

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/models/destination_intelligence.dart';

void main() {
  group('Singapore DestinationIntelligence — validation globale', () {
    test('Objet construit + validate() retourne liste vide', () {
      final singapore = buildSingaporeDestinationIntelligence();
      final errors = singapore.validate();
      expect(errors, isEmpty,
          reason: 'Singapour doit passer la validation sans erreur. '
              'Erreurs obtenues : $errors');
      expect(singapore.isValid, isTrue);
    });
  });

  group('Singapore — champs essentiels', () {
    final singapore = buildSingaporeDestinationIntelligence();

    test('destinationKey == "singapore"', () {
      expect(singapore.destinationKey, equals('singapore'));
    });

    test('canonicalCenter = (1.3521, 103.8198)', () {
      expect(singapore.canonicalCenter.lat, closeTo(1.3521, 0.0001));
      expect(singapore.canonicalCenter.lng, closeTo(103.8198, 0.0001));
    });

    test('countryCode == "SG" (uppercase ISO 3166-1 alpha-2)', () {
      expect(singapore.countryCode, equals('SG'));
    });

    test('allowedCountryCodes contient SG', () {
      expect(singapore.allowedCountryCodes, contains('SG'));
      expect(singapore.allowedCountryCodes, hasLength(1));
    });

    test('blockedCountryCodes contient MY et ID', () {
      expect(singapore.blockedCountryCodes, contains('MY'));
      expect(singapore.blockedCountryCodes, contains('ID'));
    });

    test('borderSensitivity == high (frontière Johor + Bintan)', () {
      expect(singapore.borderSensitivity, equals(BorderSensitivity.high));
    });

    test('tripMode == megaCity', () {
      expect(singapore.tripMode, equals(TripMode.megaCity));
    });
  });

  group('Singapore — zones (10 attendues)', () {
    final singapore = buildSingaporeDestinationIntelligence();

    test('Exactement 10 zones', () {
      expect(singapore.zones, hasLength(10));
    });

    test('Toutes les zones sont valides individuellement', () {
      for (final zone in singapore.zones) {
        expect(zone.validate(), isEmpty,
            reason: 'Zone "${zone.name}" invalide : ${zone.validate()}');
      }
    });

    test('Contient les 10 zones nommées de la spec', () {
      final names = singapore.zones.map((z) => z.name).toSet();
      expect(
          names,
          containsAll([
            'Marina Bay',
            'Chinatown',
            'Civic District',
            'Orchard',
            'Sentosa',
            'Little India',
            'Kampong Glam',
            'Botanic Gardens',
            'Bugis',
            'Clarke Quay',
          ]),
          reason: 'Zones manquantes : '
              '${{'Marina Bay', 'Chinatown', 'Civic District', 'Orchard', 'Sentosa', 'Little India', 'Kampong Glam', 'Botanic Gardens', 'Bugis', 'Clarke Quay'}.difference(names)}');
    });

    test('Marina Bay coordonnées cohérentes avec MetroProfile '
        '(touristAnchor `Marina Bay Sands`)', () {
      final marinaBay =
          singapore.zones.firstWhere((z) => z.name == 'Marina Bay');
      // Touch anchor MetroProfile : (1.2834, 103.8607) — zone centre
      // doit être dans le voisinage immédiat.
      expect(marinaBay.center.lat, closeTo(1.283, 0.01));
      expect(marinaBay.center.lng, closeTo(103.860, 0.01));
    });

    test('Sentosa coordonnées cohérentes avec MetroProfile '
        '(touristAnchor `Sentosa`, lat 1.2494)', () {
      final sentosa = singapore.zones.firstWhere((z) => z.name == 'Sentosa');
      expect(sentosa.center.lat, closeTo(1.2494, 0.001));
      expect(sentosa.center.lng, closeTo(103.8303, 0.001));
      // Sentosa = île étendue, rayon plus grand.
      expect(sentosa.radiusKm, greaterThanOrEqualTo(2.0));
    });

    test('Thèmes snake_case sur les 10 zones', () {
      for (final zone in singapore.zones) {
        expect(zone.theme, isNotEmpty);
        // Thème en snake_case : pas d'espace ni majuscule.
        expect(zone.theme, isNot(contains(' ')),
            reason: 'Thème "${zone.theme}" contient espace');
        expect(zone.theme, equals(zone.theme.toLowerCase()),
            reason: 'Thème "${zone.theme}" non lowercase');
      }
    });

    test('Bugis présent (ajout user, non MetroProfile standalone)', () {
      final bugis = singapore.zones.firstWhere((z) => z.name == 'Bugis');
      expect(bugis.center.lat, closeTo(1.30, 0.05));
      expect(bugis.center.lng, closeTo(103.85, 0.05));
    });
  });

  group('Singapore — anchors (15 attendus)', () {
    final singapore = buildSingaporeDestinationIntelligence();

    test('Exactement 15 anchors', () {
      expect(singapore.anchors, hasLength(15));
    });

    test('Tous les anchors sont valides individuellement', () {
      for (final anchor in singapore.anchors) {
        expect(anchor.validate(), isEmpty,
            reason:
                'Anchor "${anchor.name}" invalide : ${anchor.validate()}');
      }
    });

    test('Contient les 3 anchors test minimum (spec)', () {
      final names = singapore.anchors.map((a) => a.name).toSet();
      expect(names, contains('Gardens by the Bay'));
      expect(names, contains('Buddha Tooth Relic Temple'));
      // Sentosa peut être "Sentosa" ou "Sentosa Island" — chercher
      // par préfixe.
      final hasSentosa = singapore.anchors.any((a) =>
          a.name.toLowerCase().startsWith('sentosa'));
      expect(hasSentosa, isTrue, reason: 'Anchor Sentosa attendu');
    });

    test('Contient les 10 mustSee du blueprint', () {
      final names = singapore.anchors.map((a) => a.name).toSet();
      // Marina Bay Sands, Gardens by the Bay, Sentosa Island,
      // Chinatown, Little India, Singapore Botanic Gardens,
      // Merlion Park, Orchard Road, ArtScience Museum,
      // Buddha Tooth Relic Temple
      expect(names, contains('Marina Bay Sands'));
      expect(names, contains('Gardens by the Bay'));
      expect(names, contains('Chinatown'));
      expect(names, contains('Little India'));
      expect(names, contains('Singapore Botanic Gardens'));
      expect(names, contains('Merlion Park'));
      expect(names, contains('Orchard Road'));
      expect(names, contains('ArtScience Museum'));
      expect(names, contains('Buddha Tooth Relic Temple'));
    });

    test('Contient les 5 experience du blueprint', () {
      final names = singapore.anchors.map((a) => a.name).toSet();
      expect(names, contains('Clarke Quay'));
      expect(names, contains('Lau Pa Sat'));
      expect(names, contains('Maxwell Food Centre'));
      expect(names, contains('Singapore Flyer'));
      expect(names, contains('Kampong Glam / Arab Street'));
    });

    test('Importance dans [1, 5] pour chaque anchor', () {
      for (final anchor in singapore.anchors) {
        expect(anchor.importance, greaterThanOrEqualTo(1));
        expect(anchor.importance, lessThanOrEqualTo(5));
      }
    });

    test('recommendedDuration > 0 pour chaque anchor', () {
      for (final anchor in singapore.anchors) {
        expect(anchor.recommendedDuration.inMinutes, greaterThan(0));
      }
    });

    test('Anchors incontournables ont importance 5', () {
      final mustSee5 = ['Marina Bay Sands', 'Gardens by the Bay',
        'Singapore Botanic Gardens', 'Buddha Tooth Relic Temple'];
      for (final name in mustSee5) {
        final a = singapore.anchors.firstWhere((x) => x.name == name);
        expect(a.importance, equals(5),
            reason: '$name doit avoir importance 5 (incontournable)');
      }
    });

    test('placeQueries non vide pour chaque anchor', () {
      for (final anchor in singapore.anchors) {
        expect(anchor.placeQueries, isNotEmpty);
        for (final q in anchor.placeQueries) {
          expect(q.trim(), isNotEmpty);
        }
      }
    });
  });

  group('Singapore — transportRules', () {
    final singapore = buildSingaporeDestinationIntelligence();

    test('maxTransitionKm > 0', () {
      expect(singapore.transportRules.maxTransitionKm, greaterThan(0));
    });

    test('maxTransitionKm == 5.0 (mégacité V8.28d-fix)', () {
      expect(singapore.transportRules.maxTransitionKm, equals(5.0));
    });

    test('dominantMode == "public_transport"', () {
      expect(singapore.transportRules.dominantMode,
          equals('public_transport'));
    });

    test('hasMetro == true', () {
      expect(singapore.transportRules.hasMetro, isTrue);
    });

    test('hasMetroAnchorLogic == true', () {
      expect(singapore.transportRules.hasMetroAnchorLogic, isTrue);
    });
  });

  group('Singapore — round-trip JSON', () {
    test('toJson() puis fromJson() conserve l\'objet entier valide', () {
      final original = buildSingaporeDestinationIntelligence();
      final json = original.toJson();
      final decoded = DestinationIntelligence.fromJson(json);

      // Modèle décodé valide.
      expect(decoded.validate(), isEmpty);

      // Champs top-level conservés.
      expect(decoded.destinationKey, equals(original.destinationKey));
      expect(decoded.canonicalCenter.lat,
          equals(original.canonicalCenter.lat));
      expect(decoded.canonicalCenter.lng,
          equals(original.canonicalCenter.lng));
      expect(decoded.countryCode, equals(original.countryCode));
      expect(decoded.allowedCountryCodes,
          equals(original.allowedCountryCodes));
      expect(decoded.blockedCountryCodes,
          equals(original.blockedCountryCodes));
      expect(decoded.borderSensitivity, equals(original.borderSensitivity));
      expect(decoded.tripMode, equals(original.tripMode));

      // Zones et anchors conservés en nombre.
      expect(decoded.zones, hasLength(original.zones.length));
      expect(decoded.anchors, hasLength(original.anchors.length));

      // Sample : 1 zone + 1 anchor conservés en détail.
      final originalMarinaBay =
          original.zones.firstWhere((z) => z.name == 'Marina Bay');
      final decodedMarinaBay =
          decoded.zones.firstWhere((z) => z.name == 'Marina Bay');
      expect(decodedMarinaBay.center.lat,
          equals(originalMarinaBay.center.lat));
      expect(decodedMarinaBay.radiusKm,
          equals(originalMarinaBay.radiusKm));
      expect(decodedMarinaBay.theme, equals(originalMarinaBay.theme));

      final originalGardens = original.anchors
          .firstWhere((a) => a.name == 'Gardens by the Bay');
      final decodedGardens = decoded.anchors
          .firstWhere((a) => a.name == 'Gardens by the Bay');
      expect(decodedGardens.importance, equals(originalGardens.importance));
      expect(decodedGardens.recommendedDuration.inMinutes,
          equals(originalGardens.recommendedDuration.inMinutes));
      expect(decodedGardens.placeQueries,
          equals(originalGardens.placeQueries));

      // TransportRules conservé.
      expect(decoded.transportRules.maxTransitionKm,
          equals(original.transportRules.maxTransitionKm));
      expect(decoded.transportRules.dominantMode,
          equals(original.transportRules.dominantMode));
      expect(decoded.transportRules.hasMetro,
          equals(original.transportRules.hasMetro));
      expect(decoded.transportRules.hasMetroAnchorLogic,
          equals(original.transportRules.hasMetroAnchorLogic));
    });

    test('Sérialisation JSON utilise snake_case (cohérent projet)', () {
      final json = buildSingaporeDestinationIntelligence().toJson();
      expect(json, contains('destination_key'));
      expect(json, contains('canonical_center'));
      expect(json, contains('country_code'));
      expect(json, contains('allowed_country_codes'));
      expect(json, contains('blocked_country_codes'));
      expect(json, contains('border_sensitivity'));
      expect(json, contains('trip_mode'));
      expect(json, contains('transport_rules'));
      // Pas de camelCase pour les clés top-level.
      expect(json.containsKey('destinationKey'), isFalse);
      expect(json.containsKey('canonicalCenter'), isFalse);
    });
  });

  group('Singapore — invariants Phase 1', () {
    // Vérifie que les choix produit documentés tiennent.
    final singapore = buildSingaporeDestinationIntelligence();

    test('borderSensitivity is HIGH (frontière critique)', () {
      // Justification : Singapour bordée par Johor Bahru (Malaisie,
      // ~25km de Woodlands) et Bintan/Batam (Indonésie, ~50-75km).
      // Le pipeline a historiquement dérivé dans ces deux pays
      // (V8.28b1 + V8.28b1.2).
      expect(singapore.borderSensitivity, BorderSensitivity.high);
    });

    test('tripMode is megaCity (cohérent isMegaCity=true du MetroProfile)',
        () {
      expect(singapore.tripMode, TripMode.megaCity);
    });

    test('Au moins 1 zone par grand pôle touristique (10 attendus)', () {
      // Liste minimale couvrant la diversité Singapour.
      final names = singapore.zones.map((z) => z.name).toSet();
      // 10 zones distinctes (vérifié plus haut), pas de doublon.
      expect(names.length, equals(singapore.zones.length),
          reason: 'Zones nommées doivent être uniques');
    });

    test('Anchors couvrent au moins 5 catégories sémantiques distinctes',
        () {
      // Sanity check sémantique : pas que des temples ou que des
      // mall. Au moins 5 anchors avec des thèmes/noms variés.
      final names = singapore.anchors.map((a) => a.name).toList();
      // Heuristique simple : présence de mots-clés variés.
      final hasSands = names.any((n) => n.contains('Marina Bay Sands'));
      final hasGarden = names.any((n) => n.contains('Garden'));
      final hasTemple =
          names.any((n) => n.contains('Temple') || n.contains('Buddha'));
      final hasMuseum =
          names.any((n) => n.contains('Museum') || n.contains('ArtScience'));
      final hasMall = names.any((n) => n.contains('Orchard'));
      final categories = [hasSands, hasGarden, hasTemple, hasMuseum, hasMall]
          .where((b) => b)
          .length;
      expect(categories, greaterThanOrEqualTo(5),
          reason:
              'Anchors doivent couvrir ≥5 catégories sémantiques distinctes');
    });
  });
}
