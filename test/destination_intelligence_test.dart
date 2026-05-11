// Phase 1 / Tâche 1.4 — Tests d'intégration DestinationIntelligence.
//
// Vérifie que les pièces des Tâches 1.1 + 1.2 + 1.3 fonctionnent
// ENSEMBLE :
//   - 1.1 modèle `DestinationIntelligence` + sous-modèles + enums
//   - 1.2 données Singapour (`lib/data/destinations/singapore.dart`)
//   - 1.3 loader (`lib/services/destination_intelligence_loader.dart`)
//
// **Pas un remplacement** des tests unitaires existants — focus sur
// l'intégration end-to-end (loader → builder → modèle → validate →
// JSON → fromJson → validate).
//
// Aucun test réseau, aucun Supabase, aucun Google Places. Aucun
// mock lourd. Le loader est utilisé avec son registry local par
// défaut (qui pointe vers `buildSingaporeDestinationIntelligence`).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/models/destination_intelligence.dart';
import 'package:voyage/services/destination_intelligence_loader.dart';

/// Normalise un titre de zone/anchor pour comparaison robuste aux
/// variations de casse / whitespace. Ne fait PAS de strip
/// d'accents ici car les noms Singapour ne contiennent pas de
/// diacritiques européens. Comparison stricte sur le contenu
/// post-lowercase / post-trim / collapse.
String _norm(String s) =>
    s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

Set<String> _zoneNames(DestinationIntelligence di) =>
    di.zones.map((z) => _norm(z.name)).toSet();

Set<String> _anchorNames(DestinationIntelligence di) =>
    di.anchors.map((a) => _norm(a.name)).toSet();

void main() {
  // ─── 1. Chargement Singapour via loader ────────────────────────────

  group('1. Chargement Singapour via loader', () {
    test('load("singapore") retourne objet valide avec les champs '
        'essentiels Phase 1.2', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');

      expect(di.validate(), isEmpty);
      expect(di.destinationKey, equals('singapore'));
      expect(di.countryCode, equals('SG'));
      expect(di.allowedCountryCodes, contains('SG'));
      expect(di.blockedCountryCodes, contains('MY'));
      expect(di.blockedCountryCodes, contains('ID'));
      expect(di.borderSensitivity, equals(BorderSensitivity.high));
      expect(di.tripMode, equals(TripMode.megaCity));
      expect(di.transportRules.maxTransitionKm, equals(5.0));
      expect(di.transportRules.hasMetro, isTrue);
      expect(di.transportRules.hasMetroAnchorLogic, isTrue);
    });

    test('canonicalCenter Singapour cohérent (~1.3521, 103.8198)',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      expect(di.canonicalCenter.lat, closeTo(1.3521, 0.0001));
      expect(di.canonicalCenter.lng, closeTo(103.8198, 0.0001));
    });
  });

  // ─── 2. Zones Singapour ─────────────────────────────────────────────

  group('2. Zones Singapour via loader', () {
    test('Au minimum 4 zones essentielles présentes '
        '(Marina Bay, Chinatown, Sentosa, Orchard)', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      final names = _zoneNames(di);

      // Test minimum strict (spec Tâche 1.4).
      expect(names, contains(_norm('Marina Bay')));
      expect(names, contains(_norm('Chinatown')));
      expect(names, contains(_norm('Sentosa')));
      expect(names, contains(_norm('Orchard')));
    });

    test('Les 10 zones définies en Tâche 1.2 sont toutes présentes',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      final names = _zoneNames(di);

      final expectedZones = [
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
      ];
      for (final zone in expectedZones) {
        expect(names, contains(_norm(zone)),
            reason: 'Zone "$zone" manquante (cf. spec Tâche 1.2)');
      }
      expect(di.zones, hasLength(10),
          reason: 'Spec Tâche 1.2 = exactement 10 zones');
    });

    test('Chaque zone est valide individuellement', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      for (final zone in di.zones) {
        expect(zone.validate(), isEmpty,
            reason: 'Zone "${zone.name}" invalide : ${zone.validate()}');
      }
    });
  });

  // ─── 3. Anchors Singapour ───────────────────────────────────────────

  group('3. Anchors Singapour via loader', () {
    test('Au minimum 3 anchors essentiels présents '
        '(Gardens by the Bay, Buddha Tooth Relic Temple, Sentosa)',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      final names = _anchorNames(di);

      // Test minimum strict (spec Tâche 1.4).
      expect(names, contains(_norm('Gardens by the Bay')));
      expect(names, contains(_norm('Buddha Tooth Relic Temple')));
      // "Sentosa" peut être stocké comme "Sentosa Island" — on
      // accepte tout anchor dont le titre normalisé commence par
      // "sentosa".
      final hasSentosa = names.any((n) => n.startsWith('sentosa'));
      expect(hasSentosa, isTrue,
          reason: 'Anchor commençant par "Sentosa" attendu');
    });

    test('15 anchors présents (cf. spec Tâche 1.2 : 10 mustSee + '
        '5 experience)', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      expect(di.anchors, hasLength(15),
          reason: 'Spec Tâche 1.2 = exactement 15 anchors');
    });

    test('Tous les anchors essentiels du blueprint sont présents',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      final names = _anchorNames(di);

      // 10 mustSee du blueprint Singapour.
      final mustSee = [
        'Marina Bay Sands',
        'Gardens by the Bay',
        'Chinatown',
        'Little India',
        'Singapore Botanic Gardens',
        'Merlion Park',
        'Orchard Road',
        'ArtScience Museum',
        'Buddha Tooth Relic Temple',
      ];
      for (final name in mustSee) {
        expect(names, contains(_norm(name)),
            reason: 'Must-see "$name" manquant');
      }
      // Sentosa peut être stocké comme "Sentosa" ou "Sentosa Island".
      expect(names.any((n) => n.startsWith('sentosa')), isTrue);

      // 5 experience.
      final experience = [
        'Clarke Quay',
        'Lau Pa Sat',
        'Maxwell Food Centre',
        'Singapore Flyer',
      ];
      for (final name in experience) {
        expect(names, contains(_norm(name)),
            reason: 'Experience "$name" manquante');
      }
      // Kampong Glam peut être "Kampong Glam / Arab Street".
      expect(
          names.any((n) => n.startsWith('kampong glam')),
          isTrue);
    });

    test('Chaque anchor a importance dans [1, 5] + duration > 0',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('singapore');
      for (final anchor in di.anchors) {
        expect(anchor.importance, inInclusiveRange(1, 5),
            reason: 'Anchor "${anchor.name}" importance hors plage');
        expect(anchor.recommendedDuration.inMinutes, greaterThan(0),
            reason: 'Anchor "${anchor.name}" duration <= 0');
      }
    });
  });

  // ─── 4. Sérialisation intégrée ──────────────────────────────────────

  group('4. Sérialisation round-trip end-to-end', () {
    test('loader → toJson → fromJson → validate → champs conservés',
        () async {
      final loader = DestinationIntelligenceLoader();
      final original = await loader.load('singapore');

      // Sérialisation.
      final json = original.toJson();
      // Reconstruction.
      final decoded = DestinationIntelligence.fromJson(json);

      // Modèle reconstruit valide.
      expect(decoded.validate(), isEmpty,
          reason: 'L\'objet reconstruit doit être valide');

      // Champs essentiels conservés.
      expect(decoded.destinationKey, equals(original.destinationKey));
      expect(decoded.countryCode, equals(original.countryCode));
      expect(decoded.borderSensitivity,
          equals(original.borderSensitivity));
      expect(decoded.tripMode, equals(original.tripMode));
      expect(decoded.canonicalCenter.lat,
          equals(original.canonicalCenter.lat));
      expect(decoded.canonicalCenter.lng,
          equals(original.canonicalCenter.lng));
      expect(decoded.allowedCountryCodes,
          equals(original.allowedCountryCodes));
      expect(decoded.blockedCountryCodes,
          equals(original.blockedCountryCodes));

      // Zones et anchors conservés en nombre.
      expect(decoded.zones, hasLength(original.zones.length));
      expect(decoded.anchors, hasLength(original.anchors.length));

      // Zones attendues toujours présentes après round-trip.
      final decodedZoneNames = _zoneNames(decoded);
      expect(decodedZoneNames, contains(_norm('Marina Bay')));
      expect(decodedZoneNames, contains(_norm('Sentosa')));
      expect(decodedZoneNames, contains(_norm('Bugis')));

      // Anchors attendus toujours présents après round-trip.
      final decodedAnchorNames = _anchorNames(decoded);
      expect(decodedAnchorNames, contains(_norm('Gardens by the Bay')));
      expect(decodedAnchorNames,
          contains(_norm('Buddha Tooth Relic Temple')));

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
  });

  // ─── 5. Fallback destination inconnue ──────────────────────────────

  group('5. Fallback destination inconnue (intégration)', () {
    test('load("unknown_city") via loader retourne fallback valide',
        () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('unknown_city');

      expect(di.validate(), isEmpty,
          reason: 'Fallback doit être valide pour passer en pipeline');
      expect(di.destinationKey, equals('unknown_city'));
      expect(di.tripMode, equals(TripMode.cityBreak));
      expect(di.borderSensitivity, equals(BorderSensitivity.medium));
      expect(di.blockedCountryCodes, isEmpty);
      expect(di.zones, isNotEmpty);
      expect(di.anchors, isNotEmpty);
      expect(di.transportRules.maxTransitionKm, greaterThan(0));
    });

    test('Fallback est sérialisable round-trip', () async {
      final loader = DestinationIntelligenceLoader();
      final di = await loader.load('zzz_unknown');
      final json = di.toJson();
      final decoded = DestinationIntelligence.fromJson(json);
      expect(decoded.validate(), isEmpty);
      expect(decoded.destinationKey, equals(di.destinationKey));
      expect(decoded.tripMode, equals(TripMode.cityBreak));
    });
  });

  // ─── 6. Cache intégré ───────────────────────────────────────────────

  group('6. Cache intégré + normalisation clé', () {
    test('Premier load Singapour → isCached("singapore") true', () async {
      final loader = DestinationIntelligenceLoader();
      expect(loader.isCached('singapore'), isFalse);
      await loader.load('singapore');
      expect(loader.isCached('singapore'), isTrue);
    });

    test('Cache utilise la clé normalisée (case + whitespace)',
        () async {
      final loader = DestinationIntelligenceLoader();
      await loader.load('SINGAPORE');
      expect(loader.isCached('singapore'), isTrue);
      expect(loader.isCached(' Singapore '), isTrue);
      expect(loader.isCached('SINGAPORE'), isTrue);
    });

    test('Deux loads consécutifs avec keys normalisées différentes '
        'retournent des objets valides et équivalents (comportement, '
        'pas identité)', () async {
      final loader = DestinationIntelligenceLoader();
      final a = await loader.load(' Singapore ');
      final b = await loader.load('SINGAPORE');

      // Les deux objets doivent être valides.
      expect(a.validate(), isEmpty);
      expect(b.validate(), isEmpty);
      // Et représenter la même destination (champs identiques).
      expect(a.destinationKey, equals(b.destinationKey));
      expect(a.countryCode, equals(b.countryCode));
      expect(a.zones.length, equals(b.zones.length));
      expect(a.anchors.length, equals(b.anchors.length));
      expect(a.tripMode, equals(b.tripMode));
    });

    test('clearCache + reload reste fonctionnel et valide', () async {
      final loader = DestinationIntelligenceLoader();
      await loader.load('singapore');
      loader.clearCache();
      expect(loader.isCached('singapore'), isFalse);
      final reloaded = await loader.load('singapore');
      expect(reloaded.validate(), isEmpty);
      expect(reloaded.destinationKey, equals('singapore'));
      expect(loader.isCached('singapore'), isTrue);
    });
  });

  // ─── 7. Robustesse globale (sanity) ─────────────────────────────────

  group('7. Robustesse globale (sanity)', () {
    test('Loader avec aucune source injectée fonctionne pour '
        'Singapour + fallback inconnu sans crash', () async {
      final loader = DestinationIntelligenceLoader();
      final sg = await loader.load('singapore');
      final unk = await loader.load('zzz');
      expect(sg.validate(), isEmpty);
      expect(unk.validate(), isEmpty);
      expect(sg.tripMode, equals(TripMode.megaCity));
      expect(unk.tripMode, equals(TripMode.cityBreak));
    });

    test('Loader peut servir plusieurs destinations différentes '
        'en mémoire simultanément', () async {
      final loader = DestinationIntelligenceLoader();
      await loader.load('singapore');
      await loader.load('paris_unknown');
      await loader.load('rio_unknown');
      // Toutes les 3 sont cachées indépendamment.
      expect(loader.isCached('singapore'), isTrue);
      expect(loader.isCached('paris_unknown'), isTrue);
      expect(loader.isCached('rio_unknown'), isTrue);
      // clearCache vide les 3.
      loader.clearCache();
      expect(loader.isCached('singapore'), isFalse);
      expect(loader.isCached('paris_unknown'), isFalse);
      expect(loader.isCached('rio_unknown'), isFalse);
    });
  });
}
