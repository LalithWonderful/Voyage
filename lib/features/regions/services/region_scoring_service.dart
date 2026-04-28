import 'package:voyage/features/regions/data/region_tags.dart';
import 'package:voyage/features/regions/models/country_region.dart';

/// Résultat du scoring d'une région : la région elle-même, son score numérique
/// et les tags qui ont matché (pour l'explication "Choisi pour : ...").
class RegionScore {
  final CountryRegion region;
  final double score;

  /// Tags de la région qui ont matché avec interests/travelerType de l'user.
  /// Utilisé pour afficher l'explication user-facing sur la card "Recommandé".
  final List<String> matchedTags;

  const RegionScore({
    required this.region,
    required this.score,
    required this.matchedTags,
  });
}

/// Scoring déterministe "Je ne sais pas quoi choisir".
///
/// Algorithme V1 (validé Lalith) :
/// - matches `interestTags ∩ region.tags` × **1.0**
/// - matches `travelerTags ∩ region.tags` × **0.5**
/// - bonus `+0.3` si `userInterests.length < 3` ET `region.tags` contient `first_time`
/// - tie-breaker : `priority` croissante (1 = "first_time" donc plus accessible)
/// - re-tie-breaker : ordre initial dans la liste (stable)
///
/// Pas d'appel Gemini. Pure intersection de sets.
class RegionScoringService {
  const RegionScoringService();

  /// Score chaque région du pays selon les préférences utilisateur.
  /// Retourne la liste triée par score décroissant (top-1 en premier).
  ///
  /// [regions] : la liste à scorer (typiquement les 5 régions d'un pays).
  /// [userInterests] : intérêts cochés (ex: ['Culture', 'Plage']).
  /// [travelerType] : type voyageur (ex: 'Famille'). Null si non défini.
  List<RegionScore> scoreRegions({
    required List<CountryRegion> regions,
    required List<String> userInterests,
    String? travelerType,
  }) {
    // Calcule les tags privilégiés depuis les inputs utilisateur.
    final interestTags = <String>{};
    for (final interest in userInterests) {
      final tags = interestToTags[interest];
      if (tags != null) interestTags.addAll(tags);
    }
    final travelerTags = <String>{
      if (travelerType != null) ...?travelerTypeToTags[travelerType],
    };

    // Bonus first_time : actif uniquement si l'user a peu de préférences
    // (signale un voyageur "novice" qui veut une expérience accessible).
    final firstTimeBonusActive = userInterests.length < 3;

    // Score chaque région.
    final scored = <RegionScore>[];
    for (final region in regions) {
      final regionTagSet = region.tags.toSet();
      final matchedInterest = regionTagSet.intersection(interestTags);
      final matchedTraveler = regionTagSet.intersection(travelerTags);

      double score = matchedInterest.length * 1.0 + matchedTraveler.length * 0.5;
      if (firstTimeBonusActive && regionTagSet.contains('first_time')) {
        score += 0.3;
      }

      // Pour l'explication UI : on garde les tags matchés (interests > traveler).
      // On dédupe et on tronque à 3 (cohérent avec tagsToFrLabels(maxCount: 3)).
      final allMatched = <String>{
        ...matchedInterest,
        ...matchedTraveler,
      }.toList();

      scored.add(RegionScore(
        region: region,
        score: score,
        matchedTags: allMatched,
      ));
    }

    // Tri : score desc, puis priority asc, puis ordre original.
    // mergeSort serait plus stable mais sort() en Dart est stable depuis 2.18+.
    final indexed = scored.asMap().entries.toList();
    indexed.sort((a, b) {
      final scoreCmp = b.value.score.compareTo(a.value.score);
      if (scoreCmp != 0) return scoreCmp;
      final prioCmp = a.value.region.priority.compareTo(b.value.region.priority);
      if (prioCmp != 0) return prioCmp;
      return a.key.compareTo(b.key); // ordre initial
    });
    return indexed.map((e) => e.value).toList();
  }

  /// Raccourci : la meilleure région selon le scoring (= top-1).
  /// Null si la liste de régions est vide.
  RegionScore? bestRegion({
    required List<CountryRegion> regions,
    required List<String> userInterests,
    String? travelerType,
  }) {
    if (regions.isEmpty) return null;
    final scored = scoreRegions(
      regions: regions,
      userInterests: userInterests,
      travelerType: travelerType,
    );
    return scored.first;
  }
}
