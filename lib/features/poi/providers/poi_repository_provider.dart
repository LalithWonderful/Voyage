/// POI-0.9 — Provider d'injection du repository POI.
///
/// Par défaut, ce provider retourne un repository offline basé sur les
/// fixtures MVP Paris/Lisbon (aucun appel réseau, aucun credential requis).
/// L'implémentation Supabase runtime reste volontairement différée.
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

import '../data/fixture_poi_repository.dart';
import '../domain/poi.dart';
import '../domain/poi_repository.dart';

/// Provider racine pour l'injection de [PoiRepository].
///
/// Default : fixtures MVP locales (offline, sans réseau).
/// Override possible en test et futur runtime Supabase.
final poiRepositoryProvider = Provider<PoiRepository>(
  (ref) => LazyFixturePoiRepository.loadDefaultFixtures(),
  name: 'poiRepositoryProvider',
);

/// Lazy adapter that keeps [poiRepositoryProvider] synchronous while loading
/// fixture JSON only when a repository method is first used.
class LazyFixturePoiRepository implements PoiRepository {
  final Future<FixturePoiRepository> Function() _load;
  Future<FixturePoiRepository>? _repositoryFuture;

  LazyFixturePoiRepository(this._load);

  factory LazyFixturePoiRepository.loadDefaultFixtures({
    String repoRoot = '.',
  }) {
    return LazyFixturePoiRepository(
      () => FixturePoiRepository.loadDefaultFixtures(repoRoot: repoRoot),
    );
  }

  Future<FixturePoiRepository> _repository() {
    return _repositoryFuture ??= _load();
  }

  @override
  Future<List<Poi>> listPoisByDestination(String destinationKey) async {
    return (await _repository()).listPoisByDestination(destinationKey);
  }

  @override
  Future<Poi?> getPoiById(String poiId) async {
    return (await _repository()).getPoiById(poiId);
  }

  @override
  Future<List<Poi>> getTopPoisForDestination(
    String destinationKey,
    int limit,
  ) async {
    return (await _repository()).getTopPoisForDestination(
      destinationKey,
      limit,
    );
  }

  @override
  Future<List<Poi>> getPoisByCategories(
    String destinationKey,
    List<PoiCategory> categories,
  ) async {
    return (await _repository()).getPoisByCategories(
      destinationKey,
      categories,
    );
  }

  @override
  Future<List<Poi>> searchPois({
    required String destinationKey,
    String? query,
    List<String>? tags,
    PoiCategory? category,
    bool mustSeeOnly = false,
    int? limit,
  }) async {
    return (await _repository()).searchPois(
      destinationKey: destinationKey,
      query: query,
      tags: tags,
      category: category,
      mustSeeOnly: mustSeeOnly,
      limit: limit,
    );
  }
}
