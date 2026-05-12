/// POI-1.2 — Pipeline de review et d'enrichment offline pour fixtures POI.
///
/// Prend un fixture brut (typiquement généré par [OsmOverpassExtractor])
/// et un fichier d'overrides manuels optionnels, produisant un fixture
/// "reviewed" compatible avec [PoiFixtureValidator].
///
/// ## Workflow
///
/// ```
/// raw_fixture.json ──▶ PoiFixtureReviewer ──▶ reviewed_fixture.json
///                            │
///                            ▼
///                      quality_report.md
/// ```
///
/// ## Format d'override
///
/// ```json
/// {
///   "overrides": {
///     "poi-uuid-001": {
///       "name": "Nom corrigé",
///       "category": "park",
///       "editorial_score": 95,
///       "removed": false
///     },
///     "poi-uuid-002": { "removed": true }
///   }
/// }
/// ```
///
/// Tous les champs sont optionnels sauf `removed`. Les champs absents
/// préservent la valeur brute.
library;

import 'dart:math';

// ─── Modèles d'override ───

/// Correction manuelle pour un POI donné.
class PoiOverride {
  final String? name;
  final String? category;
  final int? editorialScore;
  final int? touristicImportance;
  final int? typicalDurationMinutes;
  final int? priceLevel;
  final bool? isMustSee;
  final bool? isFamilyFriendly;
  final bool? isRainFriendly;
  final bool? isFree;
  final List<Map<String, dynamic>>? tags;
  final List<Map<String, dynamic>>? aliases;
  final bool removed;

  const PoiOverride({
    this.name,
    this.category,
    this.editorialScore,
    this.touristicImportance,
    this.typicalDurationMinutes,
    this.priceLevel,
    this.isMustSee,
    this.isFamilyFriendly,
    this.isRainFriendly,
    this.isFree,
    this.tags,
    this.aliases,
    this.removed = false,
  });

  factory PoiOverride.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>>? readList(String key) {
      final raw = json[key];
      if (raw == null) return null;
      if (raw is! List) return null;
      return raw.cast<Map<String, dynamic>>();
    }

    return PoiOverride(
      name: json['name'] as String?,
      category: json['category'] as String?,
      editorialScore: json['editorial_score'] as int?,
      touristicImportance: json['touristic_importance'] as int?,
      typicalDurationMinutes: json['typical_duration_minutes'] as int?,
      priceLevel: json['price_level'] as int?,
      isMustSee: json['is_must_see'] as bool?,
      isFamilyFriendly: json['is_family_friendly'] as bool?,
      isRainFriendly: json['is_rain_friendly'] as bool?,
      isFree: json['is_free'] as bool?,
      tags: readList('tags'),
      aliases: readList('aliases'),
      removed: json['removed'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (name != null) map['name'] = name;
    if (category != null) map['category'] = category;
    if (editorialScore != null) map['editorial_score'] = editorialScore;
    if (touristicImportance != null) {
      map['touristic_importance'] = touristicImportance;
    }
    if (typicalDurationMinutes != null) {
      map['typical_duration_minutes'] = typicalDurationMinutes;
    }
    if (priceLevel != null) map['price_level'] = priceLevel;
    if (isMustSee != null) map['is_must_see'] = isMustSee;
    if (isFamilyFriendly != null) map['is_family_friendly'] = isFamilyFriendly;
    if (isRainFriendly != null) map['is_rain_friendly'] = isRainFriendly;
    if (isFree != null) map['is_free'] = isFree;
    if (tags != null) map['tags'] = tags;
    if (aliases != null) map['aliases'] = aliases;
    if (removed) map['removed'] = true;
    return map;
  }
}

// ─── Rapport qualité ───

/// Niveau de sévérité d'un problème qualité.
enum PoiIssueSeverity { info, warning, error }

/// Problème qualité détecté sur un POI.
class PoiQualityIssue {
  final String poiId;
  final String poiName;
  final String message;
  final PoiIssueSeverity severity;

  const PoiQualityIssue({
    required this.poiId,
    required this.poiName,
    required this.message,
    required this.severity,
  });

  Map<String, dynamic> toJson() => {
    'poi_id': poiId,
    'poi_name': poiName,
    'message': message,
    'severity': severity.name,
  };
}

/// Rapport qualité complet d'un fixture.
class PoiQualityReport {
  final List<PoiQualityIssue> issues;
  final int totalPois;
  final int reviewedPois;
  final int removedPois;
  final DateTime generatedAt;

  const PoiQualityReport({
    required this.issues,
    required this.totalPois,
    required this.reviewedPois,
    required this.removedPois,
    required this.generatedAt,
  });

  List<PoiQualityIssue> get errors =>
      issues.where((i) => i.severity == PoiIssueSeverity.error).toList();

  List<PoiQualityIssue> get warnings =>
      issues.where((i) => i.severity == PoiIssueSeverity.warning).toList();

  List<PoiQualityIssue> get infos =>
      issues.where((i) => i.severity == PoiIssueSeverity.info).toList();

  Map<String, dynamic> toJson() => {
    'generated_at': generatedAt.toIso8601String(),
    'total_pois': totalPois,
    'reviewed_pois': reviewedPois,
    'removed_pois': removedPois,
    'issue_count': issues.length,
    'errors': errors.map((e) => e.toJson()).toList(),
    'warnings': warnings.map((e) => e.toJson()).toList(),
    'infos': infos.map((e) => e.toJson()).toList(),
  };

  /// Rendu Markdown pour lecture humaine.
  String toMarkdown() {
    final buf = StringBuffer();
    buf.writeln('# Rapport qualité POI');
    buf.writeln();
    buf.writeln('**Généré le** : ${generatedAt.toIso8601String()}');
    buf.writeln('**POI bruts** : $totalPois');
    buf.writeln('**POI reviewés** : $reviewedPois');
    buf.writeln('**POI supprimés** : $removedPois');
    buf.writeln('**Problèmes** : ${issues.length}');
    buf.writeln();

    void writeSection(String title, List<PoiQualityIssue> items) {
      if (items.isEmpty) return;
      buf.writeln('## $title (${items.length})');
      buf.writeln();
      for (final item in items) {
        buf.writeln('- **${item.poiName}** (`${item.poiId}`) — ${item.message}');
      }
      buf.writeln();
    }

    writeSection('Erreurs', errors);
    writeSection('Avertissements', warnings);
    writeSection('Infos', infos);

    if (issues.isEmpty) {
      buf.writeln('Aucun problème détecté. ✅');
    }

    return buf.toString();
  }
}

// ─── Reviewer ───

/// Reviewer offline de fixture POI.
///
/// Applique des overrides manuels sur un fixture brut et génère un
/// rapport qualité.
class PoiFixtureReviewer {
  final Map<String, dynamic> rawFixture;
  final Map<String, PoiOverride> overrides;

  /// Distance minimale (en mètres) pour considérer deux POI comme
  /// doublons de localisation.
  final double duplicateDistanceThreshold;

  /// Score en dessous duquel un POI est signalé comme "faible qualité".
  final int lowScoreThreshold;

  /// Noms génériques suspects à signaler.
  static const _suspiciousNamePatterns = {
    'building',
    'house',
    'shop',
    'store',
    'restaurant',
    'cafe',
    'hotel',
    'office',
    'apartments',
    'residential',
    'unknown',
    'unnamed',
    'no name',
    'null',
  };

  PoiFixtureReviewer({
    required this.rawFixture,
    Map<String, PoiOverride>? overrides,
    this.duplicateDistanceThreshold = 100.0,
    this.lowScoreThreshold = 50,
  }) : overrides = overrides ?? const {};

  /// Charge des overrides depuis un JSON déjà parsé.
  static Map<String, PoiOverride> loadOverrides(
    Map<String, dynamic> overridesJson,
  ) {
    final map = <String, PoiOverride>{};
    final raw = overridesJson['overrides'] as Map<String, dynamic>?;
    if (raw == null) return map;
    for (final entry in raw.entries) {
      map[entry.key] = PoiOverride.fromJson(entry.value as Map<String, dynamic>);
    }
    return map;
  }

  // ═══════════════════════════════════════════════════════════
  //  Construction du fixture reviewed
  // ═══════════════════════════════════════════════════════════

  /// Construit le fixture final en appliquant les overrides sur le raw.
  /// Le raw n'est pas modifié (deep copy).
  Map<String, dynamic> buildReviewedFixture() {
    final rawSources = rawFixture['sources'];
    final rawPois = (rawFixture['pois'] as List<dynamic>).cast<Map<String, dynamic>>();

    final reviewedPois = <Map<String, dynamic>>[];

    for (final rawPoi in rawPois) {
      final poiId = rawPoi['poi_id'] as String;
      final ov = overrides[poiId];

      if (ov?.removed == true) continue;

      // Deep copy minimale du POI brut
      final poi = Map<String, dynamic>.from(rawPoi);

      if (ov == null) {
        reviewedPois.add(poi);
        continue;
      }

      // Appliquer les overrides champs par champs
      if (ov.name != null) {
        poi['name'] = ov.name;
        poi['normalized_name'] = _normalizeName(ov.name!);
      }
      if (ov.category != null) poi['category'] = ov.category;
      if (ov.editorialScore != null) poi['editorial_score'] = ov.editorialScore;
      if (ov.touristicImportance != null) {
        poi['touristic_importance'] = ov.touristicImportance;
      }
      if (ov.typicalDurationMinutes != null) {
        poi['typical_duration_minutes'] = ov.typicalDurationMinutes;
      }
      if (ov.priceLevel != null) poi['price_level'] = ov.priceLevel;
      if (ov.isMustSee != null) poi['is_must_see'] = ov.isMustSee;
      if (ov.isFamilyFriendly != null) {
        poi['is_family_friendly'] = ov.isFamilyFriendly;
      }
      if (ov.isRainFriendly != null) {
        poi['is_rain_friendly'] = ov.isRainFriendly;
      }
      if (ov.isFree != null) poi['is_free'] = ov.isFree;
      if (ov.tags != null) poi['tags'] = ov.tags;

      if (ov.aliases != null) {
        poi['aliases'] = ov.aliases;
      } else if (ov.name != null) {
        // Mise à jour de l'alias canonical si le nom a changé
        // mais que les aliases ne sont pas overridés
        final aliases = (poi['aliases'] as List<dynamic>).cast<Map<String, dynamic>>();
        final updatedAliases = aliases.map((a) => Map<String, dynamic>.from(a)).toList();
        for (final a in updatedAliases) {
          if (a['is_canonical'] == true) {
            a['alias'] = ov.name;
            a['alias_normalized'] = _normalizeName(ov.name!);
          }
        }
        poi['aliases'] = updatedAliases;
      }

      reviewedPois.add(poi);
    }

    return {
      '_comment': rawFixture['_comment'],
      'sources': rawSources,
      'pois': reviewedPois,
    };
  }

  // ═══════════════════════════════════════════════════════════
  //  Rapport qualité
  // ═══════════════════════════════════════════════════════════

  /// Analyse le fixture brut (avant application des overrides) et
  /// produit un rapport qualité.
  PoiQualityReport generateQualityReport() {
    final issues = <PoiQualityIssue>[];
    final rawPois = (rawFixture['pois'] as List<dynamic>).cast<Map<String, dynamic>>();
    final removedCount = overrides.values.where((o) => o.removed).length;

    final poisToAnalyze = <Map<String, dynamic>>[];
    final poiIdsToAnalyze = <String>{};

    for (final poi in rawPois) {
      final poiId = poi['poi_id'] as String;
      final override = overrides[poiId];
      if (override?.removed == true) continue;
      poisToAnalyze.add(poi);
      poiIdsToAnalyze.add(poiId);
    }

    // Index pour détection de doublons
    final nameIndex = <String, List<Map<String, dynamic>>>{};
    final coordIndex = <Map<String, dynamic>>[];

    for (final poi in poisToAnalyze) {
      final normName = poi['normalized_name'] as String? ?? '';
      nameIndex.putIfAbsent(normName, () => []).add(poi);

      final lat = poi['lat'] as double?;
      final lng = poi['lng'] as double?;
      if (lat != null && lng != null) {
        coordIndex.add(poi);
      }
    }

    for (final poi in poisToAnalyze) {
      final poiId = poi['poi_id'] as String;
      final name = poi['name'] as String;
      final normName = poi['normalized_name'] as String? ?? '';
      final category = poi['category'] as String?;
      final score = poi['editorial_score'] as int?;
      final tags = (poi['tags'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      final subcategory = poi['subcategory'] as String?;
      final lat = poi['lat'] as double?;
      final lng = poi['lng'] as double?;

      // 1. Score faible
      if (score != null && score < lowScoreThreshold) {
        issues.add(PoiQualityIssue(
          poiId: poiId,
          poiName: name,
          message: 'Score éditorial faible ($score < $lowScoreThreshold)',
          severity: PoiIssueSeverity.warning,
        ));
      }

      // 2. Pas de wiki/website (score de base = 60)
      if (score == 60) {
        issues.add(PoiQualityIssue(
          poiId: poiId,
          poiName: name,
          message: 'Aucune source secondaire (pas de wikipedia, wikidata, ni website)',
          severity: PoiIssueSeverity.info,
        ));
      }

      // 3. Catégorie fallback must_see (attraction générique)
      if (category == 'must_see' && subcategory == 'attraction') {
        issues.add(PoiQualityIssue(
          poiId: poiId,
          poiName: name,
          message: 'Catégorie fallback "must_see" (tourism=attraction sans tag spécifique)',
          severity: PoiIssueSeverity.warning,
        ));
      }

      // 4. Noms suspects / génériques
      final lowerName = normName.toLowerCase();
      for (final pattern in _suspiciousNamePatterns) {
        if (lowerName == pattern || lowerName.contains(' $pattern')) {
          issues.add(PoiQualityIssue(
            poiId: poiId,
            poiName: name,
            message: 'Nom suspect ou trop générique ("$pattern")',
            severity: PoiIssueSeverity.warning,
          ));
          break;
        }
      }

      // 5. Tags pauvres
      if (tags.length < 3) {
        issues.add(PoiQualityIssue(
          poiId: poiId,
          poiName: name,
          message: 'Peu de tags (${tags.length} < 3)',
          severity: PoiIssueSeverity.info,
        ));
      }

      // 6. Doublons par nom
      final sameName = nameIndex[normName] ?? [];
      if (sameName.length > 1) {
        final others = sameName
            .where((p) => p['poi_id'] != poiId)
            .map((p) => p['poi_id'])
            .join(', ');
        issues.add(PoiQualityIssue(
          poiId: poiId,
          poiName: name,
          message: 'Doublon probable par nom (même normalized_name) avec $others',
          severity: PoiIssueSeverity.error,
        ));
      }

      // 7. Doublons par coordonnées proches
      if (lat != null && lng != null) {
        for (final other in coordIndex) {
          final otherId = other['poi_id'] as String;
          if (otherId == poiId) continue;
          final otherLat = other['lat'] as double;
          final otherLng = other['lng'] as double;
          final dist = _haversine(lat, lng, otherLat, otherLng);
          if (dist < duplicateDistanceThreshold) {
            issues.add(PoiQualityIssue(
              poiId: poiId,
              poiName: name,
              message:
                  'Doublon probable par proximité (${dist.toStringAsFixed(0)}m < ${duplicateDistanceThreshold}m) avec $otherId',
              severity: PoiIssueSeverity.error,
            ));
            break; // un seul doublon de distance par POI
          }
        }
      }
    }

    return PoiQualityReport(
      issues: issues,
      totalPois: rawPois.length,
      reviewedPois: poisToAnalyze.length,
      removedPois: removedCount,
      generatedAt: DateTime.now(),
    );
  }

  // ═══════════════════════════════════════════════════════════
  //  Helpers
  // ═══════════════════════════════════════════════════════════

  static String _normalizeName(String name) =>
      name.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Distance haversine entre deux points WGS-84 (en mètres).
  static double _haversine(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const R = 6371000.0; // Rayon terrestre en mètres
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) *
            cos(_toRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static double _toRad(double deg) => deg * pi / 180.0;
}
