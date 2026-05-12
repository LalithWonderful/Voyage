// POI-1.3 — Importer contrôlé vers Supabase.
//
// Orchestration complète : validation → staging plan → upsert idempotent.
//
// Par défaut : dry-run uniquement (aucun write).
// Write réel uniquement avec :
//   --dart-define=ALLOW_POI_SUPABASE_WRITE=true
//
// Stratégie d'idempotence : upsert par table avec onConflict sur les
// clés naturelles (source_id, poi_id, poi_id+alias_normalized, etc.).
// Ré-import du même fixture = mise à jour des lignes existantes, pas de
// doublons.

import 'package:supabase/supabase.dart';

import 'poi_staging_importer.dart';

/// Flag de compilation pour autoriser les écritures Supabase.
const bool _allowWrite = bool.fromEnvironment(
  'ALLOW_POI_SUPABASE_WRITE',
  defaultValue: false,
);

/// Exception levée si l'import Supabase échoue de manière irrécupérable.
class PoiSupabaseImportException implements Exception {
  final String message;
  PoiSupabaseImportException(this.message);
  @override
  String toString() => 'PoiSupabaseImportException: $message';
}

/// Write executor réel utilisant Supabase PostgREST avec upsert/idempotence.
///
/// L'ordre d'écriture respecte les contraintes de clés étrangères :
/// 1. poi_sources
/// 2. pois
/// 3. poi_aliases
/// 4. poi_source_links
/// 5. poi_tags
/// 6. poi_quality_flags
class SupabasePoiStagingWriteExecutor {
  final SupabaseClient _client;

  SupabasePoiStagingWriteExecutor(this._client);

  Future<void> call(PoiStagingPlan plan) async {
    // 1. poi_sources (parent)
    if (plan.poiSources.isNotEmpty) {
      await _client.from('poi_sources').upsert(
            plan.poiSources,
            onConflict: 'source_id',
          );
    }

    // 2. pois (child de poi_sources)
    if (plan.pois.isNotEmpty) {
      await _client.from('pois').upsert(
            plan.pois,
            onConflict: 'poi_id',
          );
    }

    // 3. poi_aliases
    if (plan.poiAliases.isNotEmpty) {
      await _client.from('poi_aliases').upsert(
            plan.poiAliases,
            onConflict: 'poi_id,alias_normalized',
          );
    }

    // 4. poi_source_links
    if (plan.poiSourceLinks.isNotEmpty) {
      await _client.from('poi_source_links').upsert(
            plan.poiSourceLinks,
            onConflict: 'poi_id,source_id,source_poi_identifier_key',
          );
    }

    // 5. poi_tags
    if (plan.poiTags.isNotEmpty) {
      await _client.from('poi_tags').upsert(
            plan.poiTags,
            onConflict: 'poi_id,tag',
          );
    }

    // 6. poi_quality_flags
    if (plan.poiQualityFlags.isNotEmpty) {
      await _client.from('poi_quality_flags').upsert(
            plan.poiQualityFlags,
            onConflict: 'poi_id,flag_type,flag_reason',
          );
    }
  }
}

/// Importer contrôlé vers Supabase.
///
/// Par défaut : dry-run uniquement (validation + plan sans write).
/// Write réel uniquement si :
///   - [dryRun] = false
///   - const bool.fromEnvironment('ALLOW_POI_SUPABASE_WRITE') == true
///   - un [SupabaseClient] est fourni
///
/// Pour les tests, [allowWriteOverride] et [writeExecutor] peuvent être
/// injectés.
class PoiSupabaseImporter {
  final PoiStagingImporter _stagingImporter;
  final SupabaseClient? _client;
  final bool? _allowWriteOverride;
  final PoiStagingWriteExecutor? _writeExecutor;

  PoiSupabaseImporter({
    PoiStagingImporter? stagingImporter,
    SupabaseClient? client,
    bool? allowWriteOverride,
    PoiStagingWriteExecutor? writeExecutor,
  })  : _stagingImporter = stagingImporter ?? PoiStagingImporter(),
        _client = client,
        _allowWriteOverride = allowWriteOverride,
        _writeExecutor = writeExecutor;

  /// Importe un fixture JSON validé vers Supabase.
  ///
  /// Toujours en dry-run d'abord pour valider et construire le plan.
  /// Si [dryRun] est false, vérifie l'opt-in `ALLOW_POI_SUPABASE_WRITE`
  /// et exécute le write via Supabase (ou via [writeExecutor] injecté).
  Future<PoiStagingReport> import(
    Map<String, dynamic> fixtureJson, {
    bool dryRun = true,
  }) async {
    // Étape 1 : validation et plan (toujours dry-run)
    final stagingReport = await _stagingImporter.run(
      fixtureJson,
      dryRun: true,
    );

    if (!stagingReport.canProceed) {
      return stagingReport;
    }

    if (dryRun) {
      return stagingReport;
    }

    // Étape 2 : write — opt-in obligatoire
    final allowWrite = _allowWriteOverride ?? _allowWrite;
    if (!allowWrite) {
      return PoiStagingReport(
        dryRun: false,
        validationPassed: stagingReport.validationPassed,
        validationReport: stagingReport.validationReport,
        plan: stagingReport.plan,
        blockingErrors: [
          ...stagingReport.blockingErrors,
          'ALLOW_POI_SUPABASE_WRITE is not set. '
              'Real writes are disabled by default. '
              'Run with --dart-define=ALLOW_POI_SUPABASE_WRITE=true to enable.',
        ],
        warnings: stagingReport.warnings,
        canProceed: false,
      );
    }

    final PoiStagingWriteExecutor? executor = _writeExecutor ??
        (_client != null
            ? SupabasePoiStagingWriteExecutor(_client!).call
            : null);

    if (executor == null) {
      return PoiStagingReport(
        dryRun: false,
        validationPassed: stagingReport.validationPassed,
        validationReport: stagingReport.validationReport,
        plan: stagingReport.plan,
        blockingErrors: [
          ...stagingReport.blockingErrors,
          'SupabaseClient or writeExecutor is required for real writes.',
        ],
        warnings: stagingReport.warnings,
        canProceed: false,
      );
    }

    // Étape 3 : exécution du write réel
    final writeReport = await _stagingImporter.run(
      fixtureJson,
      dryRun: false,
      writeExecutor: executor,
    );

    return writeReport;
  }
}
