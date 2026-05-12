import 'package:voyage/config/live_api_guards.dart';

const _requiredSnapshotFamilies = <LiveApiFamily>[
  LiveApiFamily.googlePlaces,
  LiveApiFamily.googleGeocoding,
];

const _requiredHarnessFamilies = <LiveApiFamily>[
  LiveApiFamily.googlePlaces,
  LiveApiFamily.googleGeocoding,
];

const _dartDefineByFamily = <LiveApiFamily, String>{
  LiveApiFamily.googlePlaces: 'ALLOW_LIVE_GOOGLE_PLACES=true',
  LiveApiFamily.googleGeocoding: 'ALLOW_LIVE_GOOGLE_GEOCODING=true',
  LiveApiFamily.googleRoutes: 'ALLOW_LIVE_GOOGLE_ROUTES=true',
  LiveApiFamily.gemini: 'ALLOW_LIVE_GEMINI=true',
  LiveApiFamily.supabase: 'ALLOW_LIVE_SUPABASE=true',
  LiveApiFamily.networkImages: 'ALLOW_LIVE_NETWORK_IMAGES=true',
  LiveApiFamily.deviceLocation: 'ALLOW_LIVE_DEVICE_LOCATION=true',
  LiveApiFamily.currencyApi: 'ALLOW_LIVE_CURRENCY_API=true',
};

List<LiveApiFamily> missingLiveApiFamiliesForGenerateBaseline(
  LiveApiGuards guards,
) {
  return _missingFamilies(guards, _requiredSnapshotFamilies);
}

List<LiveApiFamily> missingLiveApiFamiliesForPlacesFirstHarness(
  LiveApiGuards guards,
) {
  return _missingFamilies(guards, _requiredHarnessFamilies);
}

void assertLiveApisAllowedForGenerateBaseline({LiveApiGuards? guards}) {
  final effectiveGuards = guards ?? LiveApiGuards.fromEnvironment();
  final missing = missingLiveApiFamiliesForGenerateBaseline(effectiveGuards);
  if (missing.isEmpty) return;
  throw LiveApiScriptGuardException(
    liveApiScriptGuardMessage(
      scriptName: 'test/snapshots/generate_baseline.dart',
      missingFamilies: missing,
      requiredFamilies: _requiredSnapshotFamilies,
    ),
  );
}

void assertLiveApisAllowedForPlacesFirstHarness({LiveApiGuards? guards}) {
  final effectiveGuards = guards ?? LiveApiGuards.fromEnvironment();
  final missing = missingLiveApiFamiliesForPlacesFirstHarness(effectiveGuards);
  if (missing.isEmpty) return;
  throw LiveApiScriptGuardException(
    liveApiScriptGuardMessage(
      scriptName: 'test/dev/places_first_harness.dart',
      missingFamilies: missing,
      requiredFamilies: _requiredHarnessFamilies,
    ),
  );
}

String liveApiScriptGuardMessage({
  required String scriptName,
  required List<LiveApiFamily> missingFamilies,
  required List<LiveApiFamily> requiredFamilies,
}) {
  final missing = missingFamilies.map((f) => f.name).join(', ');
  final defines = requiredFamilies
      .map((f) => '--dart-define=${_dartDefineByFamily[f]}')
      .join(' ');
  return 'Live API calls are disabled for this script: $scriptName.\n'
      'Missing live API permissions: $missing.\n'
      'Use $defines only for controlled runs.';
}

List<LiveApiFamily> _missingFamilies(
  LiveApiGuards guards,
  List<LiveApiFamily> requiredFamilies,
) {
  return [
    for (final family in requiredFamilies)
      if (!guards.allows(family)) family,
  ];
}

class LiveApiScriptGuardException implements Exception {
  final String message;

  const LiveApiScriptGuardException(this.message);

  @override
  String toString() => message;
}
