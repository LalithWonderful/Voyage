// POI-0.3 — Staging importer dry-run.
//
// Transforme un fixture JSON validé en plan d'insertion SQL
// (poi_sources, pois, poi_aliases, poi_source_links, poi_tags,
// poi_quality_flags). Par défaut : dry-run uniquement (aucun write).
// Le write réel nécessite dryRun=false + injection d'un exécuteur.
//
// Aucun appel réseau par défaut. Aucune dépendance Flutter.

library;

import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

/// Plan d'insertion dénormalisé correspondant au schéma
/// `poi_knowledge_base.sql` (POI-0.1).
class PoiStagingPlan {
  final List<Map<String, dynamic>> poiSources;
  final List<Map<String, dynamic>> pois;
  final List<Map<String, dynamic>> poiAliases;
  final List<Map<String, dynamic>> poiSourceLinks;
  final List<Map<String, dynamic>> poiTags;
  final List<Map<String, dynamic>> poiQualityFlags;

  const PoiStagingPlan({
    required this.poiSources,
    required this.pois,
    required this.poiAliases,
    required this.poiSourceLinks,
    required this.poiTags,
    required this.poiQualityFlags,
  });

  Map<String, int> get counts => {
    'poi_sources': poiSources.length,
    'pois': pois.length,
    'poi_aliases': poiAliases.length,
    'poi_source_links': poiSourceLinks.length,
    'poi_tags': poiTags.length,
    'poi_quality_flags': poiQualityFlags.length,
  };
}

/// Rapport final de l'opération d'import (dry-run ou réel).
class PoiStagingReport {
  final bool dryRun;
  final bool validationPassed;
  final PoiDryRunReport? validationReport;
  final PoiStagingPlan? plan;
  final List<String> blockingErrors;
  final List<String> warnings;
  final bool canProceed;
  final bool writeExecuted;

  const PoiStagingReport({
    required this.dryRun,
    required this.validationPassed,
    this.validationReport,
    this.plan,
    required this.blockingErrors,
    required this.warnings,
    required this.canProceed,
    this.writeExecuted = false,
  });

  Map<String, dynamic> toJson() => {
    'dry_run': dryRun,
    'validation_passed': validationPassed,
    'can_proceed': canProceed,
    'write_executed': writeExecuted,
    'blocking_errors': blockingErrors,
    'warnings': warnings,
    'insert_counts': plan?.counts,
    'validation': validationReport?.toJson(),
  };

  @override
  String toString() {
    final buf = StringBuffer();
    buf.writeln('=== POI Staging Report ===');
    buf.writeln('Dry-run: $dryRun');
    buf.writeln('Validation passed: $validationPassed');
    buf.writeln('Can proceed: $canProceed');
    buf.writeln('Write executed: $writeExecuted');
    if (plan != null) {
      buf.writeln('Insert counts: ${plan!.counts}');
    }
    buf.writeln('Blocking errors: ${blockingErrors.length}');
    for (final e in blockingErrors) {
      buf.writeln('  [ERROR] $e');
    }
    buf.writeln('Warnings: ${warnings.length}');
    for (final w in warnings) {
      buf.writeln('  [WARN]  $w');
    }
    return buf.toString();
  }
}

/// Callback exécuté quand dryRun=false et canProceed=true.
typedef PoiStagingWriteExecutor = Future<void> Function(PoiStagingPlan plan);

/// Importer staging offline.
///
/// 1. Valide le fixture via [PoiFixtureValidator].
/// 2. Construit un [PoiStagingPlan] dénormalisé.
/// 3. Simule les contraintes DB (unique, FK).
/// 4. Génère des quality flags depuis les warnings.
/// 5. Si dryRun=false + [writeExecutor] valide, exécute le write.
class PoiStagingImporter {
  Future<PoiStagingReport> run(
    Map<String, dynamic> fixtureJson, {
    bool dryRun = true,
    PoiStagingWriteExecutor? writeExecutor,
  }) async {
    // ─── Étape 1 : validation du fixture ───
    final validator = PoiFixtureValidator();
    final validationReport = validator.validate(fixtureJson);

    if (!validationReport.isValid) {
      return PoiStagingReport(
        dryRun: dryRun,
        validationPassed: false,
        validationReport: validationReport,
        blockingErrors: [...validationReport.errors],
        warnings: validationReport.warnings,
        canProceed: false,
      );
    }

    // ─── Étape 2 : construction du plan ───
    final plan = _buildPlan(fixtureJson, validationReport);

    // ─── Étape 3 : simulation contraintes DB ───
    final dbErrors = _simulateDbConstraints(plan);
    final dbWarnings = _simulateDbWarnings(plan);

    final blockingErrors = <String>[...dbErrors];
    final warnings = <String>[...validationReport.warnings, ...dbWarnings];
    final canProceed = blockingErrors.isEmpty;

    // ─── Étape 4 : write optionnel ───
    var writeExecuted = false;
    if (!dryRun) {
      if (writeExecutor == null) {
        blockingErrors.add(
          'dryRun=false requires a writeExecutor. '
          'Real Supabase writes are not implemented in POI-0.3.',
        );
      } else if (!canProceed) {
        blockingErrors.add(
          'Cannot execute write: blocking errors exist.',
        );
      } else {
        await writeExecutor(plan);
        writeExecuted = true;
      }
    }

    return PoiStagingReport(
      dryRun: dryRun,
      validationPassed: true,
      validationReport: validationReport,
      plan: plan,
      blockingErrors: blockingErrors,
      warnings: warnings,
      canProceed: canProceed && (dryRun || writeExecuted),
      writeExecuted: writeExecuted,
    );
  }

  // ───────────────────────────────────────────────
  // Construction du plan
  // ───────────────────────────────────────────────

  PoiStagingPlan _buildPlan(
    Map<String, dynamic> fixtureJson,
    PoiDryRunReport validationReport,
  ) {
    final sources =
        (fixtureJson['sources'] as List).cast<Map<String, dynamic>>();
    final pois =
        (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();

    final poiSources = sources.map(_transformSource).toList();
    final poiRows = <Map<String, dynamic>>[];
    final aliases = <Map<String, dynamic>>[];
    final sourceLinks = <Map<String, dynamic>>[];
    final tags = <Map<String, dynamic>>[];
    final flags = <Map<String, dynamic>>[];

    for (final poi in pois) {
      poiRows.add(_transformPoi(poi));

      final poiId = poi['poi_id'] as String;
      final sourcePrimaryId = poi['source_primary_id'] as String;
      final officialUrl = poi['official_url'] as String?;

      // Aliases
      final aliasesRaw =
          (poi['aliases'] as List).cast<Map<String, dynamic>>();
      for (final alias in aliasesRaw) {
        aliases.add(_transformAlias(alias, poiId, sourcePrimaryId));
      }

      // Lien source primaire
      sourceLinks.add({
        'poi_id': poiId,
        'source_id': sourcePrimaryId,
        'source_poi_identifier': '',
        'source_url': officialUrl,
        'source_raw_data': <String, dynamic>{},
      });

      // Tags
      final tagsRaw = (poi['tags'] as List).cast<Map<String, dynamic>>();
      for (final tag in tagsRaw) {
        tags.add(_transformTag(tag, poiId, sourcePrimaryId));
      }
    }

    // Quality flags auto-générés depuis les warnings du validateur
    for (final warning in validationReport.warnings) {
      flags.addAll(_warningToFlags(warning, pois));
    }

    return PoiStagingPlan(
      poiSources: poiSources,
      pois: poiRows,
      poiAliases: aliases,
      poiSourceLinks: sourceLinks,
      poiTags: tags,
      poiQualityFlags: flags,
    );
  }

  Map<String, dynamic> _transformSource(Map<String, dynamic> source) {
    return {
      'source_id': source['source_id'],
      'name': source['name'],
      'source_type': source['source_type'],
      'base_url': source['base_url'],
      'license_name': source['license_name'],
      'license_url': source['license_url'],
      'trust_level': source['trust_level'],
      'is_active': source['is_active'] ?? true,
      'notes': source['notes'],
    };
  }

  Map<String, dynamic> _transformPoi(Map<String, dynamic> poi) {
    return {
      'poi_id': poi['poi_id'],
      'destination_key': poi['destination_key'],
      'name': poi['name'],
      'normalized_name': poi['normalized_name'],
      'category': poi['category'],
      'subcategory': poi['subcategory'],
      'lat': poi['lat'],
      'lng': poi['lng'],
      'address': poi['address'],
      'country_code': poi['country_code'],
      'zone_name': poi['zone_name'],
      'official_url': poi['official_url'],
      'source_primary_id': poi['source_primary_id'],
      'editorial_score': poi['editorial_score'],
      'touristic_importance': poi['touristic_importance'],
      'is_must_see': poi['is_must_see'] ?? false,
      'is_family_friendly': poi['is_family_friendly'],
      'is_rain_friendly': poi['is_rain_friendly'],
      'is_free': poi['is_free'],
      'typical_duration_minutes': poi['typical_duration_minutes'],
      'opening_notes': poi['opening_notes'],
      'price_level': poi['price_level'],
      'google_place_id': poi['google_place_id'],
      'same_complex_group_key': poi['same_complex_group_key'],
      'payload': <String, dynamic>{},
    };
  }

  Map<String, dynamic> _transformAlias(
    Map<String, dynamic> alias,
    String poiId,
    String sourceId,
  ) {
    return {
      'poi_id': poiId,
      'alias': alias['alias'],
      'alias_normalized': alias['alias_normalized'],
      'is_canonical': alias['is_canonical'] ?? false,
      'source_id': sourceId,
    };
  }

  Map<String, dynamic> _transformTag(
    Map<String, dynamic> tag,
    String poiId,
    String sourceId,
  ) {
    return {
      'poi_id': poiId,
      'tag': tag['tag'],
      'tag_category': tag['tag_category'],
      'confidence': tag['confidence'],
      'source_id': sourceId,
    };
  }

  List<Map<String, dynamic>> _warningToFlags(
    String warning,
    List<Map<String, dynamic>> pois,
  ) {
    final flags = <Map<String, dynamic>>[];

    // Alias partagé entre deux POI d'une même destination
    final dupAliasMatch = RegExp(
      r'pois\[(\d+)\]\.aliases\[(\d+)\]: alias_normalized "([^"]+)" '
      r'already used by another POI in destination "([^"]+)"',
    ).firstMatch(warning);

    if (dupAliasMatch != null) {
      final poiIndex = int.parse(dupAliasMatch.group(1)!);
      final aliasText = dupAliasMatch.group(3)!;
      final poiId = pois[poiIndex]['poi_id'] as String;
      flags.add({
        'poi_id': poiId,
        'flag_type': 'duplicate',
        'flag_reason':
            'Alias "$aliasText" shared with another POI in the same destination',
        'reported_by': 'system',
      });
    }

    // Plusieurs aliases canoniques dans le même POI
    final multiCanonMatch = RegExp(
      r'pois\[(\d+)\]: multiple canonical aliases \((\d+)\)',
    ).firstMatch(warning);

    if (multiCanonMatch != null) {
      final poiIndex = int.parse(multiCanonMatch.group(1)!);
      final count = int.parse(multiCanonMatch.group(2)!);
      final poiId = pois[poiIndex]['poi_id'] as String;
      flags.add({
        'poi_id': poiId,
        'flag_type': 'needs_review',
        'flag_reason': 'POI has $count canonical aliases (expected 0 or 1)',
        'reported_by': 'system',
      });
    }

    return flags;
  }

  // ───────────────────────────────────────────────
  // Simulation contraintes DB (offline)
  // ───────────────────────────────────────────────

  List<String> _simulateDbConstraints(PoiStagingPlan plan) {
    final errors = <String>[];

    // Unique source_id
    final sourceIds = <String>{};
    for (final source in plan.poiSources) {
      final id = source['source_id'] as String;
      if (!sourceIds.add(id)) {
        errors.add('DB constraint: duplicate source_id "$id"');
      }
    }

    // Unique poi_id
    final poiIds = <String>{};
    for (final poi in plan.pois) {
      final id = poi['poi_id'] as String;
      if (!poiIds.add(id)) {
        errors.add('DB constraint: duplicate poi_id "$id"');
      }
    }

    // Unique (destination_key, normalized_name)
    final nameKeys = <String>{};
    for (final poi in plan.pois) {
      final key = '${poi['destination_key']}|${poi['normalized_name']}';
      if (!nameKeys.add(key)) {
        errors.add(
          'DB constraint: duplicate (destination_key, normalized_name) "$key"',
        );
      }
    }

    // Unique google_place_id where not null
    final gpidOwners = <String, String>{};
    for (final poi in plan.pois) {
      final gpid = poi['google_place_id'] as String?;
      if (gpid != null && gpid.isNotEmpty) {
        if (gpidOwners.containsKey(gpid)) {
          errors.add(
            'DB constraint: duplicate google_place_id "$gpid"',
          );
        } else {
          gpidOwners[gpid] = poi['poi_id'] as String;
        }
      }
    }

    // FK : source_primary_id → poi_sources
    final validSourceIds = sourceIds;
    for (final poi in plan.pois) {
      final sid = poi['source_primary_id'] as String;
      if (!validSourceIds.contains(sid)) {
        errors.add(
          'DB FK: poi "${poi['name']}" references unknown source "$sid"',
        );
      }
    }

    // FK : aliases/tags/links → pois
    for (final alias in plan.poiAliases) {
      final pid = alias['poi_id'] as String;
      if (!poiIds.contains(pid)) {
        errors.add('DB FK: alias references unknown poi_id "$pid"');
      }
    }
    for (final tag in plan.poiTags) {
      final pid = tag['poi_id'] as String;
      if (!poiIds.contains(pid)) {
        errors.add('DB FK: tag references unknown poi_id "$pid"');
      }
    }
    for (final link in plan.poiSourceLinks) {
      final pid = link['poi_id'] as String;
      if (!poiIds.contains(pid)) {
        errors.add('DB FK: source_link references unknown poi_id "$pid"');
      }
    }

    return errors;
  }

  List<String> _simulateDbWarnings(PoiStagingPlan plan) {
    final warnings = <String>[];

    for (final poi in plan.pois) {
      if (poi['lat'] == null || poi['lng'] == null) {
        warnings.add(
          'POI "${poi['name']}" has no coordinates — will not appear on map',
        );
      }
      if (poi['official_url'] == null) {
        warnings.add('POI "${poi['name']}" has no official_url');
      }
      if (poi['address'] == null || (poi['address'] as String).isEmpty) {
        warnings.add('POI "${poi['name']}" has no address');
      }
    }

    return warnings;
  }
}
