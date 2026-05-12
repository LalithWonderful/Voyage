/// API-0.2 — Central live API guardrails for Lunao.
///
/// This module is pure, immutable, and has no dependency on network,
/// Supabase, Flutter services, or mutable global state. It only parses
/// compile-time `--dart-define` values and exposes a small policy object
/// that future call sites can inject before making live API calls.
///
/// Defaults are deliberately closed: every live API family is blocked unless
/// explicitly allowed.
///
/// Global flag semantics:
/// - `ALLOW_LIVE_APIS=true` allows every known family.
/// - Otherwise, each family must be allowed with its specific flag.
///
/// A specific `false` does not override the global allow flag in API-0.2. This
/// keeps the rule unambiguous because absent `String.fromEnvironment` values
/// and explicit false both parse to "not enabled" for this module.
library;

const _envKeyAllowLiveApis = 'ALLOW_LIVE_APIS';
const _envKeyGooglePlaces = 'ALLOW_LIVE_GOOGLE_PLACES';
const _envKeyGoogleRoutes = 'ALLOW_LIVE_GOOGLE_ROUTES';
const _envKeyGoogleGeocoding = 'ALLOW_LIVE_GOOGLE_GEOCODING';
const _envKeyGemini = 'ALLOW_LIVE_GEMINI';
const _envKeySupabase = 'ALLOW_LIVE_SUPABASE';
const _envKeyNetworkImages = 'ALLOW_LIVE_NETWORK_IMAGES';
const _envKeyDeviceLocation = 'ALLOW_LIVE_DEVICE_LOCATION';
const _envKeyCurrencyApi = 'ALLOW_LIVE_CURRENCY_API';

const _flagKeyGooglePlaces = 'googlePlaces';
const _flagKeyGoogleRoutes = 'googleRoutes';
const _flagKeyGoogleGeocoding = 'googleGeocoding';
const _flagKeyGemini = 'gemini';
const _flagKeySupabase = 'supabase';
const _flagKeyNetworkImages = 'networkImages';
const _flagKeyDeviceLocation = 'deviceLocation';
const _flagKeyCurrencyApi = 'currencyApi';

/// Families of live APIs that can be guarded centrally.
enum LiveApiFamily {
  googlePlaces,
  googleRoutes,
  googleGeocoding,
  gemini,
  supabase,
  networkImages,
  deviceLocation,
  currencyApi,
}

/// Parse a string as a permissive bool:
/// - `true`, `1`, `yes` => true
/// - `false`, `0`, `no` => false
/// - null, empty, or unknown values => null
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

/// Immutable snapshot of live API permissions.
class LiveApiGuards {
  final bool allowGooglePlaces;
  final bool allowGoogleRoutes;
  final bool allowGoogleGeocoding;
  final bool allowGemini;
  final bool allowSupabase;
  final bool allowNetworkImages;
  final bool allowDeviceLocation;
  final bool allowCurrencyApi;

  const LiveApiGuards({
    this.allowGooglePlaces = false,
    this.allowGoogleRoutes = false,
    this.allowGoogleGeocoding = false,
    this.allowGemini = false,
    this.allowSupabase = false,
    this.allowNetworkImages = false,
    this.allowDeviceLocation = false,
    this.allowCurrencyApi = false,
  });

  /// Default closed policy: no live API family is allowed.
  factory LiveApiGuards.defaults() => const LiveApiGuards();

  /// Read guards from compile-time environment values passed with
  /// `--dart-define`.
  factory LiveApiGuards.fromEnvironment() {
    return LiveApiGuards.fromEnvironmentMap(const {
      _envKeyAllowLiveApis: String.fromEnvironment(_envKeyAllowLiveApis),
      _envKeyGooglePlaces: String.fromEnvironment(_envKeyGooglePlaces),
      _envKeyGoogleRoutes: String.fromEnvironment(_envKeyGoogleRoutes),
      _envKeyGoogleGeocoding: String.fromEnvironment(_envKeyGoogleGeocoding),
      _envKeyGemini: String.fromEnvironment(_envKeyGemini),
      _envKeySupabase: String.fromEnvironment(_envKeySupabase),
      _envKeyNetworkImages: String.fromEnvironment(_envKeyNetworkImages),
      _envKeyDeviceLocation: String.fromEnvironment(_envKeyDeviceLocation),
      _envKeyCurrencyApi: String.fromEnvironment(_envKeyCurrencyApi),
    });
  }

  /// Build guards from a testable map that mirrors `--dart-define` keys.
  factory LiveApiGuards.fromEnvironmentMap(Map<String, String> env) {
    final allowAll = _parseBoolString(env[_envKeyAllowLiveApis]) ?? false;

    bool resolve(String key) =>
        allowAll || (_parseBoolString(env[key]) ?? false);

    return LiveApiGuards(
      allowGooglePlaces: resolve(_envKeyGooglePlaces),
      allowGoogleRoutes: resolve(_envKeyGoogleRoutes),
      allowGoogleGeocoding: resolve(_envKeyGoogleGeocoding),
      allowGemini: resolve(_envKeyGemini),
      allowSupabase: resolve(_envKeySupabase),
      allowNetworkImages: resolve(_envKeyNetworkImages),
      allowDeviceLocation: resolve(_envKeyDeviceLocation),
      allowCurrencyApi: resolve(_envKeyCurrencyApi),
    );
  }

  /// True if at least one live API family is allowed.
  bool get allowsAnyLiveApi => toMap().values.any((v) => v);

  /// Return whether a specific live API family is allowed.
  bool allows(LiveApiFamily family) {
    switch (family) {
      case LiveApiFamily.googlePlaces:
        return allowGooglePlaces;
      case LiveApiFamily.googleRoutes:
        return allowGoogleRoutes;
      case LiveApiFamily.googleGeocoding:
        return allowGoogleGeocoding;
      case LiveApiFamily.gemini:
        return allowGemini;
      case LiveApiFamily.supabase:
        return allowSupabase;
      case LiveApiFamily.networkImages:
        return allowNetworkImages;
      case LiveApiFamily.deviceLocation:
        return allowDeviceLocation;
      case LiveApiFamily.currencyApi:
        return allowCurrencyApi;
    }
  }

  /// Throw if [family] is not allowed for [operation].
  void assertAllowed(LiveApiFamily family, {required String operation}) {
    if (allows(family)) return;
    throw LiveApiBlockedException(family: family, operation: operation);
  }

  /// Snapshot keyed by stable camelCase family names.
  Map<String, bool> toMap() => {
    _flagKeyGooglePlaces: allowGooglePlaces,
    _flagKeyGoogleRoutes: allowGoogleRoutes,
    _flagKeyGoogleGeocoding: allowGoogleGeocoding,
    _flagKeyGemini: allowGemini,
    _flagKeySupabase: allowSupabase,
    _flagKeyNetworkImages: allowNetworkImages,
    _flagKeyDeviceLocation: allowDeviceLocation,
    _flagKeyCurrencyApi: allowCurrencyApi,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! LiveApiGuards) return false;
    return allowGooglePlaces == other.allowGooglePlaces &&
        allowGoogleRoutes == other.allowGoogleRoutes &&
        allowGoogleGeocoding == other.allowGoogleGeocoding &&
        allowGemini == other.allowGemini &&
        allowSupabase == other.allowSupabase &&
        allowNetworkImages == other.allowNetworkImages &&
        allowDeviceLocation == other.allowDeviceLocation &&
        allowCurrencyApi == other.allowCurrencyApi;
  }

  @override
  int get hashCode => Object.hash(
    allowGooglePlaces,
    allowGoogleRoutes,
    allowGoogleGeocoding,
    allowGemini,
    allowSupabase,
    allowNetworkImages,
    allowDeviceLocation,
    allowCurrencyApi,
  );

  @override
  String toString() => 'LiveApiGuards(${toMap()})';
}

/// Error thrown before a blocked live API call is attempted.
class LiveApiBlockedException implements Exception {
  final LiveApiFamily family;
  final String operation;
  final String message;

  LiveApiBlockedException({
    required this.family,
    required this.operation,
    String? message,
  }) : message =
           message ??
           'Live API call blocked for ${family.name}: $operation. '
               'Enable it with the matching ALLOW_LIVE_* dart-define.';

  @override
  String toString() => message;
}
