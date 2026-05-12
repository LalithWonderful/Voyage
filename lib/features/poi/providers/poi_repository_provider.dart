/// POI-0.9 — Provider d'injection du repository POI.
///
/// Par défaut, ce provider retourne un [FakePoiRepository] vide (aucun
/// appel réseau, aucun credential requis). L'application réelle doit
/// override ce provider pour injecter une implémentation live si
/// nécessaire.
///
/// ## Usage dans l'app
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     poiRepositoryProvider.overrideWithValue(
///       SupabasePoiRepository(
///         LivePoiSupabaseClient(Supabase.instance.client),
///       ),
///     ),
///   ],
///   child: MyApp(),
/// )
/// ```
///
/// ## Usage dans les tests
///
/// ```dart
/// final container = ProviderContainer(
///   overrides: [
///     poiRepositoryProvider.overrideWithValue(fakeRepo),
///   ],
/// );
/// ```
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/fake_poi_repository.dart';
import '../domain/poi_repository.dart';

/// Provider racine pour l'injection de [PoiRepository].
///
/// Default : [FakePoiRepository] vide (offline, sans réseau).
/// Override obligatoire en app réelle pour brancher Supabase live.
final poiRepositoryProvider = Provider<PoiRepository>(
  (ref) => const FakePoiRepository(),
  name: 'poiRepositoryProvider',
);
