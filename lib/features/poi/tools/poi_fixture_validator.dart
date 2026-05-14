// POI-0.2 — Validateur offline du fixture JSON.
//
// Logique pure Dart, aucun accès réseau, aucun write Supabase,
// aucune dépendance Flutter hors `flutter_test` (côté test uniquement).
// Ce fichier est importable comme bibliothèque par les tests et les
// scripts de dry-run.

library;

/// Rapport de validation d'un fixture POI.
class PoiDryRunReport {
  final bool isValid;
  final List<String> errors;
  final List<String> warnings;
  final PoiDryRunStats stats;

  const PoiDryRunReport({
    required this.isValid,
    required this.errors,
    required this.warnings,
    required this.stats,
  });

  Map<String, dynamic> toJson() => {
    'is_valid': isValid,
    'error_count': errors.length,
    'warning_count': warnings.length,
    'errors': errors,
    'warnings': warnings,
    'stats': stats.toJson(),
  };

  @override
  String toString() {
    final buf = StringBuffer();
    buf.writeln('=== POI Dry-Run Report ===');
    buf.writeln('Valid: $isValid');
    buf.writeln('Errors: ${errors.length}');
    for (final e in errors) {
      buf.writeln('  [ERROR] $e');
    }
    buf.writeln('Warnings: ${warnings.length}');
    for (final w in warnings) {
      buf.writeln('  [WARN]  $w');
    }
    buf.writeln(stats);
    return buf.toString();
  }
}

/// Statistiques agrégées du fixture validé.
class PoiDryRunStats {
  final int sourceCount;
  final int poiCount;
  final int aliasCount;
  final int tagCount;
  final int canonicalAliasCount;
  final int mustSeeCount;
  final int freeCount;
  final int familyFriendlyCount;
  final int rainFriendlyCount;
  final Set<String> categoriesUsed;
  final Set<String> destinationKeysUsed;
  final Set<String> complexGroupKeysUsed;

  const PoiDryRunStats({
    required this.sourceCount,
    required this.poiCount,
    required this.aliasCount,
    required this.tagCount,
    required this.canonicalAliasCount,
    required this.mustSeeCount,
    required this.freeCount,
    required this.familyFriendlyCount,
    required this.rainFriendlyCount,
    required this.categoriesUsed,
    required this.destinationKeysUsed,
    required this.complexGroupKeysUsed,
  });

  Map<String, dynamic> toJson() => {
    'source_count': sourceCount,
    'poi_count': poiCount,
    'alias_count': aliasCount,
    'tag_count': tagCount,
    'canonical_alias_count': canonicalAliasCount,
    'must_see_count': mustSeeCount,
    'free_count': freeCount,
    'family_friendly_count': familyFriendlyCount,
    'rain_friendly_count': rainFriendlyCount,
    'categories_used': categoriesUsed.toList()..sort(),
    'destination_keys_used': destinationKeysUsed.toList()..sort(),
    'complex_group_keys_used': complexGroupKeysUsed.toList()..sort(),
  };

  @override
  String toString() {
    return 'PoiDryRunStats(sources=$sourceCount, pois=$poiCount, '
        'aliases=$aliasCount, tags=$tagCount, canonical=$canonicalAliasCount, '
        'mustSee=$mustSeeCount, free=$freeCount, family=$familyFriendlyCount, '
        'rain=$rainFriendlyCount, categories=$categoriesUsed, '
        'destinations=$destinationKeysUsed, complexes=$complexGroupKeysUsed)';
  }
}

/// Validateur offline d'un fixture POI Lunao.
///
/// Vérifie la conformité au schéma `poi_knowledge_base.sql` (POI-0.1)
/// sans aucun write base ni appel réseau.
class PoiFixtureValidator {
  static const allowedCategories = {
    'must_see',
    'museum',
    'monument',
    'viewpoint',
    'park',
    'nature',
    'beach',
    'neighborhood',
    'market',
    'food',
    'shopping',
    'nightlife',
    'family',
    'wellness',
    'transport_hub',
    'photo_spot',
    'rainy_day',
    'local_experience',
  };

  static const allowedSourceTypes = {
    'official_board',
    'official_venue',
    'unesco',
    'wikidata',
    'openstreetmap',
    'open_data_gov',
    'editorial',
  };

  static const allowedTagCategories = {
    'vibe',
    'accessibility',
    'activity_type',
    'audience',
    'season',
  };

  static final _uuidRegExp = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Normalise un nom selon la règle du schéma POI :
  /// lower, trim, collapse espaces multiples.
  static String normalizeName(String name) {
    return name.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Valide un fixture JSON déjà parsé et retourne un [PoiDryRunReport].
  PoiDryRunReport validate(Map<String, dynamic> json) {
    final errors = <String>[];
    final warnings = <String>[];

    final sourcesRaw = json['sources'];
    final poisRaw = json['pois'];

    if (sourcesRaw == null) {
      errors.add('Missing top-level key: sources');
    }
    if (poisRaw == null) {
      errors.add('Missing top-level key: pois');
    }

    if (errors.isNotEmpty) {
      return _emptyReport(errors, warnings);
    }

    final sourcesList = _asMapList(sourcesRaw);
    final poisList = _asMapList(poisRaw);

    // ─── Validation des sources ───
    final sourceIds = <String>{};
    for (var i = 0; i < sourcesList.length; i++) {
      final src = sourcesList[i];
      final p = 'sources[$i]';

      final sid = _string(src, 'source_id');
      if (sid == null || sid.isEmpty) {
        errors.add('$p: missing or empty source_id');
      } else if (!_isUuid(sid)) {
        errors.add('$p: invalid UUID format for source_id "$sid"');
      }

      final name = _string(src, 'name');
      if (name == null || name.isEmpty) {
        errors.add('$p: missing or empty name');
      }

      final st = _string(src, 'source_type');
      if (st == null || !allowedSourceTypes.contains(st)) {
        errors.add('$p: invalid source_type "$st"');
      }

      final tl = _int(src, 'trust_level');
      if (tl == null || tl < 1 || tl > 5) {
        errors.add('$p: trust_level must be 1..5, got $tl');
      }

      final active = src['is_active'];
      if (active is! bool) {
        errors.add('$p: is_active must be a boolean');
      }

      if (sid != null && sid.isNotEmpty && !sourceIds.add(sid)) {
        errors.add('$p: duplicate source_id "$sid"');
      }
    }

    // ─── Validation des POIs ───
    final poiIds = <String>{};
    final poiNamesByDestination = <String, Set<String>>{};
    final poiAliasesByDestination = <String, Set<String>>{};
    final googlePlaceIdOwners = <String, String>{};

    var aliasCount = 0;
    var tagCount = 0;
    var canonicalAliasCount = 0;
    var mustSeeCount = 0;
    var freeCount = 0;
    var familyFriendlyCount = 0;
    var rainFriendlyCount = 0;
    final categoriesUsed = <String>{};
    final destinationKeysUsed = <String>{};
    final complexGroupKeysUsed = <String>{};

    for (var i = 0; i < poisList.length; i++) {
      final poi = poisList[i];
      final p = 'pois[$i]';

      final pid = _string(poi, 'poi_id');
      if (pid == null || pid.isEmpty) {
        errors.add('$p: missing or empty poi_id');
      } else if (!_isUuid(pid)) {
        errors.add('$p: invalid UUID format for poi_id "$pid"');
      }
      if (pid != null && pid.isNotEmpty && !poiIds.add(pid)) {
        errors.add('$p: duplicate poi_id "$pid"');
      }

      final destKey = _string(poi, 'destination_key');
      if (destKey == null || destKey.isEmpty) {
        errors.add('$p: missing or empty destination_key');
      } else {
        destinationKeysUsed.add(destKey);
      }

      final name = _string(poi, 'name');
      if (name == null || name.isEmpty) {
        errors.add('$p: missing or empty name');
      }

      final normName = _string(poi, 'normalized_name');
      if (normName == null || normName.isEmpty) {
        errors.add('$p: missing or empty normalized_name');
      } else if (name != null && normName != normalizeName(name)) {
        errors.add(
          '$p: normalized_name mismatch: expected '
          '"${normalizeName(name)}" got "$normName"',
        );
      }

      // Doublon de nom normalisé au sein d'une même destination
      if (destKey != null && normName != null && normName.isNotEmpty) {
        final existing = poiNamesByDestination.putIfAbsent(
          destKey,
          () => <String>{},
        );
        if (!existing.add(normName)) {
          errors.add(
            '$p: duplicate normalized_name "$normName" '
            'within destination "$destKey"',
          );
        }
      }

      final category = _string(poi, 'category');
      if (category == null || !allowedCategories.contains(category)) {
        errors.add('$p: invalid category "$category"');
      } else {
        categoriesUsed.add(category);
      }

      // Coordonnées
      final lat = _double(poi, 'lat');
      if (lat != null && (lat < -90.0 || lat > 90.0)) {
        errors.add('$p: lat out of range [-90,90]: $lat');
      }
      final lng = _double(poi, 'lng');
      if (lng != null && (lng < -180.0 || lng > 180.0)) {
        errors.add('$p: lng out of range [-180,180]: $lng');
      }

      // Source primaire
      final srcPrimary = _string(poi, 'source_primary_id');
      if (srcPrimary == null || srcPrimary.isEmpty) {
        errors.add('$p: missing source_primary_id');
      } else if (!sourceIds.contains(srcPrimary)) {
        errors.add('$p: source_primary_id "$srcPrimary" not found in sources');
      }

      // Scores & niveaux
      final edScore = _int(poi, 'editorial_score');
      if (edScore != null && (edScore < 0 || edScore > 100)) {
        errors.add('$p: editorial_score must be 0..100, got $edScore');
      }

      final tImportance = _int(poi, 'touristic_importance');
      if (tImportance != null && (tImportance < 1 || tImportance > 5)) {
        errors.add('$p: touristic_importance must be 1..5, got $tImportance');
      }

      final duration = _int(poi, 'typical_duration_minutes');
      if (duration != null && duration <= 0) {
        errors.add('$p: typical_duration_minutes must be > 0, got $duration');
      }

      final price = _int(poi, 'price_level');
      if (price != null && (price < 1 || price > 4)) {
        errors.add('$p: price_level must be 1..4, got $price');
      }

      // Booléens
      final mustSee = poi['is_must_see'];
      if (mustSee is! bool) {
        errors.add('$p: is_must_see must be a boolean');
      } else if (mustSee) {
        mustSeeCount++;
      }

      final family = poi['is_family_friendly'];
      if (family is! bool && family != null) {
        errors.add('$p: is_family_friendly must be a boolean or null');
      } else if (family == true) {
        familyFriendlyCount++;
      }

      final rain = poi['is_rain_friendly'];
      if (rain is! bool && rain != null) {
        errors.add('$p: is_rain_friendly must be a boolean or null');
      } else if (rain == true) {
        rainFriendlyCount++;
      }

      final free = poi['is_free'];
      if (free is! bool && free != null) {
        errors.add('$p: is_free must be a boolean or null');
      } else if (free == true) {
        freeCount++;
      }

      // google_place_id : optionnel, jamais obligatoire
      final gpid = poi['google_place_id'];
      if (gpid != null && gpid is! String) {
        errors.add('$p: google_place_id must be a string or null');
      }
      if (gpid is String && gpid.isNotEmpty) {
        final existing = googlePlaceIdOwners[gpid];
        if (existing != null) {
          errors.add('$p: google_place_id "$gpid" already used by $existing');
        } else {
          googlePlaceIdOwners[gpid] = p;
        }
      }

      // same_complex_group_key
      final scgk = _string(poi, 'same_complex_group_key');
      if (scgk != null && scgk.isNotEmpty) {
        complexGroupKeysUsed.add(scgk);
      }

      // Aliases
      final aliasesRaw = poi['aliases'];
      if (aliasesRaw == null) {
        errors.add('$p: missing aliases array');
      } else if (aliasesRaw is! List) {
        errors.add('$p: aliases must be a list');
      } else {
        final aliasNorms = <String>{};
        var canonicalInPoi = 0;
        for (var j = 0; j < aliasesRaw.length; j++) {
          aliasCount++;
          final alias = aliasesRaw[j] as Map<String, dynamic>;
          final ap = '$p.aliases[$j]';

          final aText = _string(alias, 'alias');
          if (aText == null || aText.isEmpty) {
            errors.add('$ap: missing or empty alias');
          }

          final aNorm = _string(alias, 'alias_normalized');
          if (aNorm == null || aNorm.isEmpty) {
            errors.add('$ap: missing or empty alias_normalized');
          } else if (aText != null && aNorm != normalizeName(aText)) {
            errors.add(
              '$ap: alias_normalized mismatch: expected '
              '"${normalizeName(aText)}" got "$aNorm"',
            );
          }

          final isCanonical = alias['is_canonical'];
          if (isCanonical is! bool) {
            errors.add('$ap: is_canonical must be a boolean');
          } else if (isCanonical) {
            canonicalInPoi++;
            canonicalAliasCount++;
          }

          if (aNorm != null && aNorm.isNotEmpty) {
            if (!aliasNorms.add(aNorm)) {
              errors.add('$ap: duplicate alias_normalized "$aNorm" within POI');
            }
            if (destKey != null) {
              final existingAliases = poiAliasesByDestination.putIfAbsent(
                destKey,
                () => <String>{},
              );
              if (!existingAliases.add(aNorm)) {
                warnings.add(
                  '$ap: alias_normalized "$aNorm" already used by '
                  'another POI in destination "$destKey"',
                );
              }
            }
          }
        }
        if (canonicalInPoi > 1) {
          warnings.add('$p: multiple canonical aliases ($canonicalInPoi)');
        }
      }

      // Tags
      final tagsRaw = poi['tags'];
      if (tagsRaw == null) {
        errors.add('$p: missing tags array');
      } else if (tagsRaw is! List) {
        errors.add('$p: tags must be a list');
      } else {
        final tagValuesInPoi = <String>{};
        for (var j = 0; j < tagsRaw.length; j++) {
          tagCount++;
          final tag = tagsRaw[j] as Map<String, dynamic>;
          final tp = '$p.tags[$j]';

          final tValue = _string(tag, 'tag');
          if (tValue == null || tValue.isEmpty) {
            errors.add('$tp: missing or empty tag');
          } else if (!tagValuesInPoi.add(tValue)) {
            errors.add(
              '$tp: duplicate tag "$tValue" within POI '
              '(would break upsert onConflict)',
            );
          }

          final tCat = _string(tag, 'tag_category');
          if (tCat != null && !allowedTagCategories.contains(tCat)) {
            errors.add('$tp: invalid tag_category "$tCat"');
          }

          final conf = _int(tag, 'confidence');
          if (conf != null && (conf < 0 || conf > 100)) {
            errors.add('$tp: confidence must be 0..100, got $conf');
          }
        }
      }
    }

    if (poisList.isNotEmpty && mustSeeCount == 0) {
      warnings.add('No must-see POIs found in fixture');
    }

    return PoiDryRunReport(
      isValid: errors.isEmpty,
      errors: errors,
      warnings: warnings,
      stats: PoiDryRunStats(
        sourceCount: sourcesList.length,
        poiCount: poisList.length,
        aliasCount: aliasCount,
        tagCount: tagCount,
        canonicalAliasCount: canonicalAliasCount,
        mustSeeCount: mustSeeCount,
        freeCount: freeCount,
        familyFriendlyCount: familyFriendlyCount,
        rainFriendlyCount: rainFriendlyCount,
        categoriesUsed: categoriesUsed,
        destinationKeysUsed: destinationKeysUsed,
        complexGroupKeysUsed: complexGroupKeysUsed,
      ),
    );
  }

  PoiDryRunReport _emptyReport(List<String> errors, List<String> warnings) {
    return PoiDryRunReport(
      isValid: false,
      errors: errors,
      warnings: warnings,
      stats: const PoiDryRunStats(
        sourceCount: 0,
        poiCount: 0,
        aliasCount: 0,
        tagCount: 0,
        canonicalAliasCount: 0,
        mustSeeCount: 0,
        freeCount: 0,
        familyFriendlyCount: 0,
        rainFriendlyCount: 0,
        categoriesUsed: {},
        destinationKeysUsed: {},
        complexGroupKeysUsed: {},
      ),
    );
  }

  static bool _isUuid(String value) => _uuidRegExp.hasMatch(value);

  static String? _string(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is String) return v;
    return null;
  }

  static int? _int(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return null;
  }

  static double? _double(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  static List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.cast<Map<String, dynamic>>();
  }
}
