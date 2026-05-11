// Phase 1 / Tâche 1.1 — Tests unitaires DestinationIntelligence.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places. Toutes les `DestinationIntelligence`
// sont construites en mémoire.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/models/destination_intelligence.dart';

// ─── Helper builders ───────────────────────────────────────────────────

DestinationIntelligence _validFixture() {
  return DestinationIntelligence(
    destinationKey: 'singapore',
    canonicalCenter: const GeoPoint(lat: 1.3521, lng: 103.8198),
    countryCode: 'SG',
    allowedCountryCodes: const ['SG'],
    blockedCountryCodes: const ['MY', 'ID'],
    borderSensitivity: BorderSensitivity.high,
    tripMode: TripMode.megaCity,
    zones: [
      const TouristZone(
        name: 'Marina Bay',
        center: GeoPoint(lat: 1.283, lng: 103.860),
        radiusKm: 2.0,
        theme: 'waterfront_iconic',
      ),
    ],
    anchors: [
      const DestinationAnchor(
        name: 'Gardens by the Bay',
        placeQueries: ['Gardens by the Bay Singapore'],
        importance: 5,
        recommendedDuration: Duration(minutes: 180),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 5.0,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: true,
    ),
  );
}

void main() {
  // ─── 1. Sérialisation / désérialisation round-trip ────────────────────

  group('Round-trip JSON', () {
    test('toJson() puis fromJson() conserve toutes les valeurs', () {
      final original = _validFixture();
      final json = original.toJson();
      final decoded = DestinationIntelligence.fromJson(json);

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
      expect(decoded.zones.length, equals(original.zones.length));
      expect(decoded.zones.first.name, equals('Marina Bay'));
      expect(decoded.zones.first.radiusKm, equals(2.0));
      expect(decoded.zones.first.theme, equals('waterfront_iconic'));
      expect(decoded.anchors.length, equals(original.anchors.length));
      expect(decoded.anchors.first.placeQueries,
          equals(['Gardens by the Bay Singapore']));
      expect(decoded.anchors.first.importance, equals(5));
      expect(decoded.anchors.first.recommendedDuration.inMinutes,
          equals(180));
      expect(decoded.transportRules.maxTransitionKm, equals(5.0));
      expect(decoded.transportRules.dominantMode,
          equals('public_transport'));
      expect(decoded.transportRules.hasMetro, isTrue);
      expect(decoded.transportRules.hasMetroAnchorLogic, isTrue);
    });

    test('JSON keys utilisent snake_case (cohérent avec le projet)', () {
      final json = _validFixture().toJson();
      // Top-level
      expect(json, contains('destination_key'));
      expect(json, contains('canonical_center'));
      expect(json, contains('country_code'));
      expect(json, contains('allowed_country_codes'));
      expect(json, contains('blocked_country_codes'));
      expect(json, contains('border_sensitivity'));
      expect(json, contains('trip_mode'));
      expect(json, contains('zones'));
      expect(json, contains('anchors'));
      expect(json, contains('transport_rules'));
      // Anchor
      final anchor = (json['anchors'] as List).first as Map;
      expect(anchor, contains('place_queries'));
      expect(anchor, contains('recommended_duration_minutes'));
      // Zone
      final zone = (json['zones'] as List).first as Map;
      expect(zone, contains('radius_km'));
      expect(zone, contains('center'));
      // Transport rules
      final transport = json['transport_rules'] as Map;
      expect(transport, contains('max_transition_km'));
      expect(transport, contains('dominant_mode'));
      expect(transport, contains('has_metro'));
      expect(transport, contains('has_metro_anchor_logic'));
    });

    test('Duration sérialisé en minutes int', () {
      final json = _validFixture().toJson();
      final anchor = (json['anchors'] as List).first as Map;
      expect(anchor['recommended_duration_minutes'], equals(180));
      expect(anchor['recommended_duration_minutes'], isA<int>());
    });
  });

  // ─── 2. Validation d'un modèle valide ─────────────────────────────────

  group('Validation modèle valide', () {
    test('Modèle complet valide → errors empty + isValid true', () {
      final model = _validFixture();
      expect(model.validate(), isEmpty);
      expect(model.isValid, isTrue);
    });
  });

  // ─── 3. Champs obligatoires ───────────────────────────────────────────

  group('Champs obligatoires rejetés si vides', () {
    test('destination_key vide rejeté', () {
      final model = DestinationIntelligence(
        destinationKey: '',
        canonicalCenter: const GeoPoint(lat: 1, lng: 1),
        countryCode: 'SG',
        allowedCountryCodes: const ['SG'],
        blockedCountryCodes: const [],
        borderSensitivity: BorderSensitivity.low,
        tripMode: TripMode.cityBreak,
        zones: [
          const TouristZone(
            name: 'Z',
            center: GeoPoint(lat: 1, lng: 1),
            radiusKm: 1,
            theme: 't',
          ),
        ],
        anchors: [
          const DestinationAnchor(
            name: 'A',
            placeQueries: ['q'],
            importance: 1,
            recommendedDuration: Duration(minutes: 1),
          ),
        ],
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      expect(
          model.validate(),
          contains('destination_key must be non-empty'));
      expect(model.isValid, isFalse);
    });

    test('allowed_country_codes vide rejeté', () {
      final model = DestinationIntelligence(
        destinationKey: 'singapore',
        canonicalCenter: const GeoPoint(lat: 1, lng: 1),
        countryCode: 'SG',
        allowedCountryCodes: const [], // vide
        blockedCountryCodes: const [],
        borderSensitivity: BorderSensitivity.low,
        tripMode: TripMode.cityBreak,
        zones: [
          const TouristZone(
            name: 'Z',
            center: GeoPoint(lat: 1, lng: 1),
            radiusKm: 1,
            theme: 't',
          ),
        ],
        anchors: [
          const DestinationAnchor(
            name: 'A',
            placeQueries: ['q'],
            importance: 1,
            recommendedDuration: Duration(minutes: 1),
          ),
        ],
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      expect(
          model.validate(),
          contains('allowed_country_codes must have at least one entry'));
    });

    test('zones vide rejeté', () {
      final model = DestinationIntelligence(
        destinationKey: 'singapore',
        canonicalCenter: const GeoPoint(lat: 1, lng: 1),
        countryCode: 'SG',
        allowedCountryCodes: const ['SG'],
        blockedCountryCodes: const [],
        borderSensitivity: BorderSensitivity.low,
        tripMode: TripMode.cityBreak,
        zones: const [], // vide
        anchors: [
          const DestinationAnchor(
            name: 'A',
            placeQueries: ['q'],
            importance: 1,
            recommendedDuration: Duration(minutes: 1),
          ),
        ],
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      expect(
          model.validate(),
          contains('zones must have at least one entry'));
    });

    test('anchors vide rejeté', () {
      final model = DestinationIntelligence(
        destinationKey: 'singapore',
        canonicalCenter: const GeoPoint(lat: 1, lng: 1),
        countryCode: 'SG',
        allowedCountryCodes: const ['SG'],
        blockedCountryCodes: const [],
        borderSensitivity: BorderSensitivity.low,
        tripMode: TripMode.cityBreak,
        zones: [
          const TouristZone(
            name: 'Z',
            center: GeoPoint(lat: 1, lng: 1),
            radiusKm: 1,
            theme: 't',
          ),
        ],
        anchors: const [], // vide
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      expect(
          model.validate(),
          contains('anchors must have at least one entry'));
    });

    test('country_code vide rejeté', () {
      final model = DestinationIntelligence(
        destinationKey: 'singapore',
        canonicalCenter: const GeoPoint(lat: 1, lng: 1),
        countryCode: '',
        allowedCountryCodes: const ['SG'],
        blockedCountryCodes: const [],
        borderSensitivity: BorderSensitivity.low,
        tripMode: TripMode.cityBreak,
        zones: [
          const TouristZone(
            name: 'Z',
            center: GeoPoint(lat: 1, lng: 1),
            radiusKm: 1,
            theme: 't',
          ),
        ],
        anchors: [
          const DestinationAnchor(
            name: 'A',
            placeQueries: ['q'],
            importance: 1,
            recommendedDuration: Duration(minutes: 1),
          ),
        ],
        transportRules: const TransportRules(
          maxTransitionKm: 5,
          dominantMode: 'walk',
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      expect(model.validate(), contains('country_code must be non-empty'));
    });
  });

  // ─── 4. Coordonnées hors plage ────────────────────────────────────────

  group('Coordonnées invalides', () {
    test('Latitude > 90 rejetée', () {
      const point = GeoPoint(lat: 95, lng: 0);
      expect(point.validate(),
          contains('GeoPoint.lat must be in [-90, 90], got 95.0'));
    });

    test('Latitude < -90 rejetée', () {
      const point = GeoPoint(lat: -100, lng: 0);
      expect(point.validate(), isNotEmpty);
    });

    test('Longitude > 180 rejetée', () {
      const point = GeoPoint(lat: 0, lng: 200);
      expect(point.validate(),
          contains('GeoPoint.lng must be in [-180, 180], got 200.0'));
    });

    test('Longitude < -180 rejetée', () {
      const point = GeoPoint(lat: 0, lng: -200);
      expect(point.validate(), isNotEmpty);
    });

    test('NaN lat ou lng rejeté', () {
      const a = GeoPoint(lat: double.nan, lng: 0);
      const b = GeoPoint(lat: 0, lng: double.nan);
      expect(a.validate(), isNotEmpty);
      expect(b.validate(), isNotEmpty);
    });

    test('Coordonnées valides aux bornes acceptées (90, -180)', () {
      const a = GeoPoint(lat: 90, lng: 180);
      const b = GeoPoint(lat: -90, lng: -180);
      expect(a.validate(), isEmpty);
      expect(b.validate(), isEmpty);
    });

    test('GeoPoint invalide remonte dans validate() du model', () {
      final model = _validFixture();
      final invalid = DestinationIntelligence(
        destinationKey: model.destinationKey,
        canonicalCenter: const GeoPoint(lat: 999, lng: 0),
        countryCode: model.countryCode,
        allowedCountryCodes: model.allowedCountryCodes,
        blockedCountryCodes: model.blockedCountryCodes,
        borderSensitivity: model.borderSensitivity,
        tripMode: model.tripMode,
        zones: model.zones,
        anchors: model.anchors,
        transportRules: model.transportRules,
      );
      final errors = invalid.validate();
      expect(errors, isNotEmpty);
      expect(errors.any((e) => e.contains('canonical_center.lat')), isTrue);
    });
  });

  // ─── 5. Enums : parsing + valeurs inconnues ───────────────────────────

  group('Enums BorderSensitivity / TripMode', () {
    test('Parsing JSON "high" → BorderSensitivity.high', () {
      expect(BorderSensitivity.fromJsonString('high'),
          equals(BorderSensitivity.high));
      expect(BorderSensitivity.fromJsonString('medium'),
          equals(BorderSensitivity.medium));
      expect(BorderSensitivity.fromJsonString('low'),
          equals(BorderSensitivity.low));
    });

    test('Parsing JSON "megaCity" → TripMode.megaCity', () {
      expect(TripMode.fromJsonString('megaCity'),
          equals(TripMode.megaCity));
      expect(TripMode.fromJsonString('island'), equals(TripMode.island));
      expect(TripMode.fromJsonString('cityBreak'),
          equals(TripMode.cityBreak));
      expect(TripMode.fromJsonString('multiRegion'),
          equals(TripMode.multiRegion));
      expect(TripMode.fromJsonString('historicCity'),
          equals(TripMode.historicCity));
      expect(TripMode.fromJsonString('beachResort'),
          equals(TripMode.beachResort));
    });

    test('Sérialisation round-trip enum', () {
      for (final v in BorderSensitivity.values) {
        expect(BorderSensitivity.fromJsonString(v.toJsonString()),
            equals(v));
      }
      for (final v in TripMode.values) {
        expect(TripMode.fromJsonString(v.toJsonString()), equals(v));
      }
    });

    test('Valeur enum inconnue → FormatException (strict-by-default)',
        () {
      expect(
          () => BorderSensitivity.fromJsonString('extreme'),
          throwsA(isA<FormatException>()));
      expect(() => TripMode.fromJsonString('roadtrip'),
          throwsA(isA<FormatException>()));
    });

    test('Valeurs inconnues fail dans DestinationIntelligence.fromJson',
        () {
      final json = _validFixture().toJson();
      json['border_sensitivity'] = 'unknown';
      expect(() => DestinationIntelligence.fromJson(json),
          throwsA(isA<FormatException>()));
    });
  });

  // ─── 6. Anchor : importance + duration + queries ──────────────────────

  group('DestinationAnchor validation', () {
    test('Importance < 1 rejetée', () {
      const a = DestinationAnchor(
        name: 'A',
        placeQueries: ['q'],
        importance: 0,
        recommendedDuration: Duration(minutes: 30),
      );
      expect(a.validate(),
          contains('DestinationAnchor.importance must be in [1, 5], got 0'));
    });

    test('Importance > 5 rejetée', () {
      const a = DestinationAnchor(
        name: 'A',
        placeQueries: ['q'],
        importance: 7,
        recommendedDuration: Duration(minutes: 30),
      );
      expect(a.validate(), isNotEmpty);
    });

    test('recommended_duration <= 0 rejeté', () {
      const a = DestinationAnchor(
        name: 'A',
        placeQueries: ['q'],
        importance: 3,
        recommendedDuration: Duration(minutes: 0),
      );
      expect(
          a.validate(),
          contains(
              'DestinationAnchor.recommended_duration_minutes must be > 0, got 0'));
    });

    test('placeQueries vide rejeté', () {
      const a = DestinationAnchor(
        name: 'A',
        placeQueries: [],
        importance: 3,
        recommendedDuration: Duration(minutes: 30),
      );
      expect(a.validate(), isNotEmpty);
    });

    test('placeQueries avec uniquement strings vides rejeté', () {
      const a = DestinationAnchor(
        name: 'A',
        placeQueries: ['', '  '],
        importance: 3,
        recommendedDuration: Duration(minutes: 30),
      );
      expect(
          a.validate(),
          contains(
              'DestinationAnchor.place_queries must have at least one non-empty query'));
    });

    test('name vide rejeté', () {
      const a = DestinationAnchor(
        name: '',
        placeQueries: ['q'],
        importance: 3,
        recommendedDuration: Duration(minutes: 30),
      );
      expect(a.validate(),
          contains('DestinationAnchor.name must be non-empty'));
    });

    test('Anchor valide aux bornes (importance 1 et 5)', () {
      const a = DestinationAnchor(
        name: 'A',
        placeQueries: ['q'],
        importance: 1,
        recommendedDuration: Duration(minutes: 30),
      );
      const b = DestinationAnchor(
        name: 'B',
        placeQueries: ['q'],
        importance: 5,
        recommendedDuration: Duration(minutes: 30),
      );
      expect(a.validate(), isEmpty);
      expect(b.validate(), isEmpty);
    });
  });

  // ─── 7. TransportRules ────────────────────────────────────────────────

  group('TransportRules validation', () {
    test('max_transition_km <= 0 rejeté', () {
      const r = TransportRules(
        maxTransitionKm: 0,
        dominantMode: 'walk',
        hasMetro: false,
        hasMetroAnchorLogic: false,
      );
      expect(
          r.validate(),
          contains('TransportRules.max_transition_km must be > 0, got 0.0'));
    });

    test('max_transition_km négatif rejeté', () {
      const r = TransportRules(
        maxTransitionKm: -5,
        dominantMode: 'walk',
        hasMetro: false,
        hasMetroAnchorLogic: false,
      );
      expect(r.validate(), isNotEmpty);
    });

    test('dominant_mode vide rejeté', () {
      const r = TransportRules(
        maxTransitionKm: 5,
        dominantMode: '',
        hasMetro: false,
        hasMetroAnchorLogic: false,
      );
      expect(r.validate(),
          contains('TransportRules.dominant_mode must be non-empty'));
    });

    test('TransportRules valide → errors empty', () {
      const r = TransportRules(
        maxTransitionKm: 5,
        dominantMode: 'public_transport',
        hasMetro: true,
        hasMetroAnchorLogic: true,
      );
      expect(r.validate(), isEmpty);
    });
  });

  // ─── 8. TouristZone validation ────────────────────────────────────────

  group('TouristZone validation', () {
    test('name vide rejeté', () {
      const z = TouristZone(
        name: '',
        center: GeoPoint(lat: 1, lng: 1),
        radiusKm: 1,
        theme: 't',
      );
      expect(z.validate(),
          contains('TouristZone.name must be non-empty'));
    });

    test('radius_km <= 0 rejeté', () {
      const z = TouristZone(
        name: 'Z',
        center: GeoPoint(lat: 1, lng: 1),
        radiusKm: 0,
        theme: 't',
      );
      expect(
          z.validate(),
          contains('TouristZone.radius_km must be > 0, got 0.0'));
    });

    test('theme vide rejeté', () {
      const z = TouristZone(
        name: 'Z',
        center: GeoPoint(lat: 1, lng: 1),
        radiusKm: 1,
        theme: '',
      );
      expect(z.validate(),
          contains('TouristZone.theme must be non-empty'));
    });

    test('Zone valide → errors empty', () {
      const z = TouristZone(
        name: 'Marina Bay',
        center: GeoPoint(lat: 1.283, lng: 103.860),
        radiusKm: 2.0,
        theme: 'waterfront_iconic',
      );
      expect(z.validate(), isEmpty);
    });
  });

  // ─── 9. Multiple erreurs agrégées en un seul appel validate() ─────────

  group('Validation agrégation multiple erreurs', () {
    test('Modèle avec plusieurs problèmes : toutes les erreurs '
        'retournées en un seul appel', () {
      final model = DestinationIntelligence(
        destinationKey: '', // erreur 1
        canonicalCenter: const GeoPoint(lat: 200, lng: 999), // erreur 2 + 3
        countryCode: '', // erreur 4
        allowedCountryCodes: const [], // erreur 5
        blockedCountryCodes: const [],
        borderSensitivity: BorderSensitivity.low,
        tripMode: TripMode.cityBreak,
        zones: const [], // erreur 6
        anchors: const [], // erreur 7
        transportRules: const TransportRules(
          maxTransitionKm: 0, // erreur 8
          dominantMode: '', // erreur 9
          hasMetro: false,
          hasMetroAnchorLogic: false,
        ),
      );
      final errors = model.validate();
      expect(errors.length, greaterThanOrEqualTo(8),
          reason:
              'Validation doit retourner toutes les erreurs en un appel, '
              'obtenu ${errors.length} : $errors');
    });
  });

  // ─── 10. fromJson erreurs explicites ──────────────────────────────────

  group('fromJson erreurs explicites', () {
    test('GeoPoint sans lat → FormatException', () {
      expect(() => GeoPoint.fromJson({'lng': 1}),
          throwsA(isA<FormatException>()));
    });

    test('GeoPoint avec lat non-numeric → FormatException', () {
      expect(() => GeoPoint.fromJson({'lat': 'abc', 'lng': 1}),
          throwsA(isA<FormatException>()));
    });

    test('DestinationIntelligence sans champ obligatoire → '
        'FormatException', () {
      expect(() => DestinationIntelligence.fromJson(const {}),
          throwsA(isA<FormatException>()));
    });

    test('blocked_country_codes optionnel (peut être absent)', () {
      final json = _validFixture().toJson();
      json.remove('blocked_country_codes');
      // Ne doit pas crash — fallback empty list.
      final decoded = DestinationIntelligence.fromJson(json);
      expect(decoded.blockedCountryCodes, isEmpty);
    });
  });
}
