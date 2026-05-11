/// Phase 0 / Tâche 0.3 — Feature flags pour la refonte progressive
/// du moteur de planning Lunao.
///
/// 4 flags désactivés par défaut, destinés à activer progressivement
/// les futures phases :
///   - `useDestinationIntelligence` (Phase 1)
///   - `useSameComplexDedup`        (Phase 2 — SameComplexGroup)
///   - `useDestinationScope`        (Phase 3)
///   - `useDayTemplates`            (Phase 4 — DayTemplate)
///
/// **Aucun de ces flags n'est consommé par le pipeline actuel.** Ils
/// servent uniquement de squelette pour les phases futures. La règle
/// d'or 1 du plan de refonte (*"Ne JAMAIS casser le pipeline existant.
/// Toute nouvelle logique doit être derrière un feature flag,
/// désactivé par défaut."*) est respectée par construction : les
/// flags existent, sont OFF, et seront branchés au pipeline UNIQUEMENT
/// quand la phase correspondante introduira le nouveau code.
///
/// 3 niveaux de configuration (du plus prioritaire au moins) :
///
///   1. **Override Supabase** (futur) via `applyOverrides({...})`.
///   2. **Variables d'environnement** via `--dart-define=USE_*=true`
///      lues par `FeatureFlags.fromEnvironment()`.
///   3. **Défauts** : tous false.
///
/// ## Design
///
/// Class **immutable**, **pure**, **sans état global**. Une instance
/// est créée explicitement et passée là où c'est nécessaire (DI).
/// Évite les pièges de singletons mutables :
/// - tests faciles à isoler (chaque test crée son `FeatureFlags`)
/// - pas de fuite d'état entre tests
/// - thread-safe par construction
///
/// ## Exemples
///
/// ```dart
/// // Production : compile-time `--dart-define` + override Supabase futur.
/// final base = FeatureFlags.fromEnvironment();
/// final flags = base.applyOverrides(supabaseOverrides);
///
/// // Tests unitaires : map en mémoire.
/// final flags = FeatureFlags.fromEnvironmentMap(const {
///   'USE_DAY_TEMPLATES': 'true',
/// });
/// expect(flags.useDayTemplates, isTrue);
/// ```
library;

/// Names ENV (compatible `--dart-define`). SCREAMING_SNAKE_CASE
/// suit la convention shell standard.
const _envKeyDestinationIntelligence = 'USE_DESTINATION_INTELLIGENCE';
const _envKeySameComplexDedup = 'USE_SAME_COMPLEX_DEDUP';
const _envKeyDestinationScope = 'USE_DESTINATION_SCOPE';
const _envKeyDayTemplates = 'USE_DAY_TEMPLATES';

/// Names de flag (camelCase). Servent de clés dans `applyOverrides`
/// et `toMap`. Cohérent avec la convention Dart pour les noms de
/// propriétés ; servira aussi de clé primaire dans la table
/// Supabase `public.feature_flags`.
const _flagKeyDestinationIntelligence = 'useDestinationIntelligence';
const _flagKeySameComplexDedup = 'useSameComplexDedup';
const _flagKeyDestinationScope = 'useDestinationScope';
const _flagKeyDayTemplates = 'useDayTemplates';

/// Parse une string en bool selon la convention spec :
///   `true | TRUE | 1 | yes | YES` → true
///   `false | FALSE | 0 | no | NO` → false
///   tout autre (y compris null, '') → null (= défaut s'applique)
///
/// Volontairement permissif pour absorber les valeurs venant de
/// shell scripts, fichiers de config, etc.
bool? _parseBoolString(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  switch (s) {
    case 'true':
    case '1':
    case 'yes':
      return true;
    case 'false':
    case '0':
    case 'no':
      return false;
  }
  return null;
}

/// Coerce une valeur dynamique d'override (typiquement venue d'une
/// table Supabase ou d'un JSON) vers bool. Retourne `null` si la
/// valeur ne peut pas être interprétée → l'appelant préserve la
/// valeur existante (cf. `applyOverrides`).
bool? _coerceBool(dynamic v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return _parseBoolString(v);
  return null;
}

/// Snapshot immutable des feature flags du moteur de planning Lunao.
///
/// Tous les flags sont `false` par défaut. Cf. doc du fichier pour la
/// philosophie d'utilisation (DI, pas de singleton).
class FeatureFlags {
  /// Active la nouvelle abstraction `DestinationIntelligence`
  /// (centralisation par destination de blueprint + MetroProfile +
  /// canonicals). À brancher en Phase 1.
  final bool useDestinationIntelligence;

  /// Active la dédup des complexes sémantiques (Sentosa / Sentosa
  /// Island, Tokyo Skytree / Skytree Tower, etc.) via
  /// `SameComplexGroup`. À brancher en Phase 2.
  final bool useSameComplexDedup;

  /// Active le concept `DestinationScope` (limitation explicite du
  /// périmètre géographique d'un voyage à une destination, sans
  /// dépendance au geocoder). À brancher en Phase 3.
  final bool useDestinationScope;

  /// Active les `DayTemplate` (gabarits de journées thématiques par
  /// destination, remplacent le Day Builder greedy actuel). À
  /// brancher en Phase 4.
  final bool useDayTemplates;

  const FeatureFlags({
    this.useDestinationIntelligence = false,
    this.useSameComplexDedup = false,
    this.useDestinationScope = false,
    this.useDayTemplates = false,
  });

  /// Instance par défaut : tous les flags `false`. Équivalent à
  /// `const FeatureFlags()`. Fourni pour la lisibilité côté call site.
  factory FeatureFlags.defaults() => const FeatureFlags();

  /// Lit les flags depuis les variables d'environnement compile-time
  /// (`--dart-define=USE_*=...`). Les noms `String.fromEnvironment`
  /// doivent être des literals (limitation Dart compile-time const).
  ///
  /// Un flag absent ou avec valeur non reconnaissable → défaut false.
  factory FeatureFlags.fromEnvironment() {
    return FeatureFlags.fromEnvironmentMap(const {
      _envKeyDestinationIntelligence:
          String.fromEnvironment(_envKeyDestinationIntelligence),
      _envKeySameComplexDedup:
          String.fromEnvironment(_envKeySameComplexDedup),
      _envKeyDestinationScope:
          String.fromEnvironment(_envKeyDestinationScope),
      _envKeyDayTemplates: String.fromEnvironment(_envKeyDayTemplates),
    });
  }

  /// Construit des flags depuis une `Map<String, String>` simulant
  /// les variables d'environnement. Utilisé par les tests pour
  /// éviter la magie compile-time `--dart-define`.
  ///
  /// Clés attendues : `USE_DESTINATION_INTELLIGENCE`, etc.
  /// Cf. constantes `_envKey*`.
  factory FeatureFlags.fromEnvironmentMap(Map<String, String> env) {
    return FeatureFlags(
      useDestinationIntelligence:
          _parseBoolString(env[_envKeyDestinationIntelligence]) ?? false,
      useSameComplexDedup:
          _parseBoolString(env[_envKeySameComplexDedup]) ?? false,
      useDestinationScope:
          _parseBoolString(env[_envKeyDestinationScope]) ?? false,
      useDayTemplates: _parseBoolString(env[_envKeyDayTemplates]) ?? false,
    );
  }

  /// Applique des overrides (typiquement venus d'une table Supabase
  /// `public.feature_flags` chargée en mémoire) sur cette instance.
  /// Retourne une **nouvelle instance** ; l'instance source n'est pas
  /// mutée (immutabilité préservée).
  ///
  /// Comportement par clé :
  /// - clé connue + valeur coerciable → flag mis à jour
  /// - clé connue + valeur non coerciable (null, type inattendu,
  ///   string invalide) → flag inchangé (préserve valeur existante)
  /// - clé inconnue → ignorée silencieusement (forward-compat avec
  ///   futurs flags non encore implémentés Dart-side)
  ///
  /// Keys attendues : `useDestinationIntelligence`, etc. (camelCase,
  /// cohérent avec les fields Dart et la colonne `key` SQL).
  FeatureFlags applyOverrides(Map<String, dynamic> overrides) {
    bool resolve(String key, bool current) {
      if (!overrides.containsKey(key)) return current;
      final coerced = _coerceBool(overrides[key]);
      return coerced ?? current;
    }

    return FeatureFlags(
      useDestinationIntelligence: resolve(
        _flagKeyDestinationIntelligence,
        useDestinationIntelligence,
      ),
      useSameComplexDedup: resolve(
        _flagKeySameComplexDedup,
        useSameComplexDedup,
      ),
      useDestinationScope: resolve(
        _flagKeyDestinationScope,
        useDestinationScope,
      ),
      useDayTemplates: resolve(_flagKeyDayTemplates, useDayTemplates),
    );
  }

  /// Snapshot `Map<String, bool>` des 4 flags, keyé par camelCase.
  /// Utile pour la sérialisation (logs, debug, persistence Supabase
  /// inverse, etc.).
  Map<String, bool> toMap() => {
        _flagKeyDestinationIntelligence: useDestinationIntelligence,
        _flagKeySameComplexDedup: useSameComplexDedup,
        _flagKeyDestinationScope: useDestinationScope,
        _flagKeyDayTemplates: useDayTemplates,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FeatureFlags) return false;
    return useDestinationIntelligence == other.useDestinationIntelligence &&
        useSameComplexDedup == other.useSameComplexDedup &&
        useDestinationScope == other.useDestinationScope &&
        useDayTemplates == other.useDayTemplates;
  }

  @override
  int get hashCode => Object.hash(
        useDestinationIntelligence,
        useSameComplexDedup,
        useDestinationScope,
        useDayTemplates,
      );

  @override
  String toString() => 'FeatureFlags(${toMap()})';
}
