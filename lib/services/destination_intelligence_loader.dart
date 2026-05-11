/// Phase 1 / Tâche 1.3 — Loader + cache pour `DestinationIntelligence`.
///
/// **Service disponible mais dormant** : créé mais **non branché** au
/// pipeline production. Aucune consommation du flag
/// `useDestinationIntelligence` à ce stade. La règle d'or 1 du plan
/// de refonte est respectée (*"Toute nouvelle logique doit être
/// derrière un feature flag, désactivé par défaut"*).
///
/// ## Responsabilités
///
/// 1. Charger un `DestinationIntelligence` depuis le **registre
///    local** (data Dart curated, ex: `lib/data/destinations/
///    singapore.dart`).
/// 2. **Optionnellement** charger depuis Supabase si un
///    `DestinationIntelligenceRemoteSource` est injecté.
/// 3. **Cache mémoire de session** (pas de persistence) pour éviter
///    de reconstruire un objet immutable plusieurs fois.
/// 4. **Fallback gracieux** pour destinations inconnues : objet
///    minimal valide construit en mémoire, éventuellement enrichi
///    par un `DestinationCenterResolver` optionnel.
///
/// ## Testabilité sans réseau
///
/// Le loader **ne fait jamais d'appel réseau direct**. Les sources
/// externes (Supabase, Google Geocoding) sont représentées par des
/// **interfaces abstraites injectables** :
/// - `DestinationIntelligenceRemoteSource`
/// - `DestinationCenterResolver`
///
/// Les tests utilisent des fakes en mémoire. Aucun mock framework
/// requis.
///
/// ## Ordre de priorité (recommandation produit)
///
/// 1. **Cache mémoire** (clé normalisée)
/// 2. **Registre local** (data Dart curated, source de vérité
///    stable)
/// 3. **Remote source** (Supabase, si injectée — pour destinations
///    non embarquées en Dart ou corrections dynamiques futures)
/// 4. **Fallback** (DI minimal valide, éventuellement enrichi par
///    `centerResolver`)
///
/// **Justification du choix local-first** : les données validées
/// en code (`lib/data/destinations/*.dart`) ont déjà passé les
/// tests (10 zones / 15 anchors / validate() vide / round-trip
/// JSON). Une mise à jour Supabase mal configurée ne doit pas
/// pouvoir dégrader silencieusement une destination embarquée.
/// Une phase ultérieure peut inverser cet ordre si un besoin de
/// kill-switch dynamique émerge — il suffira d'inverser 2 lignes
/// dans `load()`.
///
/// ## Pas d'appel Google Places direct
///
/// La spec mentionne *"fallback gracieux : retourne un DI minimal
/// basé sur Google Places"*. Pour ne pas coupler ce loader à
/// l'API Google Places ni rendre les tests dépendants du réseau,
/// le résolveur de centre géographique est abstrait via
/// `DestinationCenterResolver`. Sans resolver injecté, le fallback
/// utilise un centre neutre documenté `GeoPoint(0, 0)`. Une phase
/// ultérieure pourra brancher un `GeocodingService` réel via une
/// implémentation concrète de l'interface.
library;

import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/models/destination_intelligence.dart';

/// Construit un `DestinationIntelligence` à la demande. Permet au
/// registre local de stocker des références de fonctions plutôt
/// que des instances pré-construites (économise mémoire si la
/// destination n'est jamais demandée).
typedef DestinationIntelligenceBuilder = DestinationIntelligence Function();

/// Source distante (typiquement Supabase) optionnelle. Implémenter
/// cette interface pour permettre au loader de récupérer des
/// destinations non embarquées en Dart.
///
/// **Retour** : `null` si la destination n'existe pas dans la
/// source (équivalent 404). Toute autre exception est attrapée
/// par le loader et fait fall through au fallback — voir la
/// section "Erreurs remote" de la doc migration.
abstract class DestinationIntelligenceRemoteSource {
  Future<DestinationIntelligence?> loadDestinationIntelligence(
      String destinationKey);
}

/// Résolveur de centre géographique optionnel. Une implémentation
/// concrète pourrait wrapper `GeocodingService` du projet ou un
/// appel Google Geocoding direct. Maintenu hors du loader pour
/// préserver sa testabilité.
abstract class DestinationCenterResolver {
  /// Résout un `GeoPoint` pour une destination donnée. Retourne
  /// `null` si la résolution échoue (le loader retombe alors sur
  /// un centre neutre). Toute exception est attrapée par le loader.
  Future<GeoPoint?> resolveCenter(String destinationKey);
}

/// Registre local par défaut. Map `destination_key normalisé` →
/// builder. Étendre cette map à chaque destination embarquée (cf.
/// Tâche 1.2 pour Singapour ; tâches ultérieures pour Bangkok,
/// Tokyo, etc.).
///
/// Les clés sont en lowercase trim — cohérent avec
/// `_normalizeKey`. Si un caller passe `"Singapore"` ou
/// `"SINGAPORE"`, la clé est normalisée avant lookup.
final Map<String, DestinationIntelligenceBuilder>
    defaultLocalDestinationRegistry = <String, DestinationIntelligenceBuilder>{
  'singapore': buildSingaporeDestinationIntelligence,
};

/// Centre neutre utilisé en fallback ultime quand aucun
/// `centerResolver` n'est fourni. Documenté `GeoPoint(0, 0)` =
/// océan Atlantique, hors toute zone touristique réaliste. Tout
/// caller production qui voit ce centre dans un planning indique
/// qu'il manque un resolver et/ou une entrée de registry.
const GeoPoint _kNeutralFallbackCenter = GeoPoint(lat: 0, lng: 0);

/// Nom de zone fallback générique. Cohérent et valide pour
/// `validate()`.
const String _kFallbackZoneName = 'Unknown area';

/// Nom de l'anchor fallback quand le key est vide. Le validateur
/// `DestinationAnchor` exige un name non-vide.
const String _kFallbackAnchorNameWhenEmpty = 'unknown_destination';

class DestinationIntelligenceLoader {
  /// Source distante optionnelle (Supabase, etc.). Null = pas de
  /// remote → fallthrough direct au fallback si destination
  /// absente du registre local.
  final DestinationIntelligenceRemoteSource? remoteSource;

  /// Résolveur de centre géographique optionnel (Google Geocoding,
  /// etc.). Null = fallback utilise `_kNeutralFallbackCenter`.
  final DestinationCenterResolver? centerResolver;

  /// Registre local de builders. Initialisé avec
  /// `defaultLocalDestinationRegistry` si non fourni. Injectable
  /// pour les tests (fake builders avec compteurs).
  final Map<String, DestinationIntelligenceBuilder> localRegistry;

  /// Cache mémoire de session. Clé = key normalisée.
  final Map<String, DestinationIntelligence> _cache =
      <String, DestinationIntelligence>{};

  DestinationIntelligenceLoader({
    this.remoteSource,
    this.centerResolver,
    Map<String, DestinationIntelligenceBuilder>? localRegistry,
  }) : localRegistry = localRegistry ?? defaultLocalDestinationRegistry;

  /// Charge une `DestinationIntelligence` selon l'ordre de
  /// priorité documenté en tête de fichier :
  ///   cache → local → remote → fallback.
  ///
  /// Toutes les exceptions internes (remote, centerResolver) sont
  /// attrapées silencieusement et déclenchent le fallback. Cela
  /// garantit que `load()` ne lève **jamais** d'exception en
  /// production — l'appelant reçoit toujours un
  /// `DestinationIntelligence` valide (`validate().isEmpty`).
  Future<DestinationIntelligence> load(String destinationKey) async {
    final key = _normalizeKey(destinationKey);

    // 1. Cache.
    final cached = _cache[key];
    if (cached != null) return cached;

    // 2. Local registry.
    final localBuilder = localRegistry[key];
    if (localBuilder != null) {
      final di = localBuilder();
      _cache[key] = di;
      return di;
    }

    // 3. Remote source (optionnelle).
    if (remoteSource != null) {
      try {
        final remote = await remoteSource!.loadDestinationIntelligence(key);
        if (remote != null) {
          _cache[key] = remote;
          return remote;
        }
      } catch (_) {
        // Volontairement silencieux : une remote source défectueuse
        // ne doit pas casser le pipeline. Fall through au fallback.
        // Documenté dans phase1_task1_3.md.
      }
    }

    // 4. Fallback.
    final fallback = await _buildFallback(key);
    _cache[key] = fallback;
    return fallback;
  }

  /// Vide complètement le cache mémoire. Utile pour les tests et
  /// pour le futur kill-switch admin.
  void clearCache() => _cache.clear();

  /// True si la clé (normalisée) a déjà été chargée et mise en
  /// cache.
  bool isCached(String destinationKey) =>
      _cache.containsKey(_normalizeKey(destinationKey));

  /// Normalise une clé de destination : trim + lowercase. Pas
  /// d'aliasing complexe (cf. spec : *"Ne pas ajouter une logique
  /// d'aliases complexe"*). Un caller production passant
  /// "Singapore", " singapore ", "SINGAPORE" obtient la même
  /// entrée de cache et la même destination.
  String _normalizeKey(String s) => s.trim().toLowerCase();

  /// Construit un `DestinationIntelligence` minimal valide pour
  /// une destination inconnue.
  ///
  /// Stratégie :
  /// - `canonicalCenter` ← `centerResolver?.resolveCenter(key)` si
  ///   resolver fourni et retour non-null, sinon
  ///   `_kNeutralFallbackCenter` (GeoPoint(0,0)).
  /// - `countryCode = 'XX'` (ISO 3166-1 reserved code "unknown").
  /// - `borderSensitivity = medium` (par prudence, ni laxiste
  ///   ni paranoïaque sur destination inconnue).
  /// - `tripMode = cityBreak` (mode neutre raisonnable).
  /// - Une zone générique + un anchor générique pour passer
  ///   `validate()`.
  /// - `transportRules` neutres : 5 km cap, public_transport,
  ///   pas de métro / pas de fan-out métro (on ne sait pas).
  Future<DestinationIntelligence> _buildFallback(String key) async {
    GeoPoint center = _kNeutralFallbackCenter;
    if (centerResolver != null) {
      try {
        final resolved = await centerResolver!.resolveCenter(key);
        if (resolved != null && resolved.validate().isEmpty) {
          center = resolved;
        }
      } catch (_) {
        // Silencieux — fallback au centre neutre.
      }
    }

    final anchorName =
        key.isEmpty ? _kFallbackAnchorNameWhenEmpty : key;

    return DestinationIntelligence(
      destinationKey: key.isEmpty ? _kFallbackAnchorNameWhenEmpty : key,
      canonicalCenter: center,
      countryCode: 'XX',
      allowedCountryCodes: const ['XX'],
      blockedCountryCodes: const [],
      borderSensitivity: BorderSensitivity.medium,
      tripMode: TripMode.cityBreak,
      zones: [
        TouristZone(
          name: _kFallbackZoneName,
          center: center,
          radiusKm: 5.0,
          theme: 'generic_unknown',
        ),
      ],
      anchors: [
        DestinationAnchor(
          name: anchorName,
          placeQueries: [anchorName],
          importance: 3,
          recommendedDuration: const Duration(minutes: 90),
        ),
      ],
      transportRules: const TransportRules(
        maxTransitionKm: 5.0,
        dominantMode: 'public_transport',
        hasMetro: false,
        hasMetroAnchorLogic: false,
      ),
    );
  }
}
