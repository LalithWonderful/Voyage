#!/usr/bin/env dart
// POI-1.1 — Script CLI pour extraire des POI OSM via Overpass
// et générer un fixture JSON Lunao.
//
// Usage :
//   dart tool/poi/extract_osm_pois.dart --destination singapore --country SG
//   dart tool/poi/extract_osm_pois.dart --destination paris --country FR --bbox 48.81,2.22,48.90,2.47
//
// Le résultat est écrit sur stdout (rediriger avec > fichier.json).

import 'dart:convert';
import 'dart:io';

import 'package:voyage/features/poi/tools/osm_overpass_extractor.dart';

final _usage = '''
Usage: dart tool/poi/extract_osm_pois.dart [options]

Options:
  --destination <key>   Clé destination (ex: singapore, paris). Requis.
  --country <code>      Code pays ISO-3166-1 alpha-2 (ex: SG, FR). Requis.
  --bbox <s,w,n,e>      Bounding box manuelle (défaut = bbox intégrée de la destination).
  --source-id <uuid>    UUID de la source OSM (défaut = UUID aléatoire).
  --help                Affiche cette aide.

Exemples:
  dart tool/poi/extract_osm_pois.dart --destination singapore --country SG > singapore_osm.json
  dart tool/poi/extract_osm_pois.dart --destination paris --country FR --bbox 48.81,2.22,48.90,2.47 > paris_osm.json
'''.trim();

void main(List<String> args) async {
  final parser = _parseArgs(args);
  final help = parser['help'] == 'true';
  if (help || parser['destination'] == null || parser['country'] == null) {
    // ignore: avoid_print
    print(_usage);
    exit(help ? 0 : 1);
  }

  final destinationKey = parser['destination']!;
  final countryCode = parser['country']!;
  final bbox = _resolveBbox(parser['bbox'], destinationKey);
  final sourceId = parser['source-id'] ?? _randomUuid();

  stderr.writeln('// Extraction Overpass pour "$destinationKey" ($countryCode)');
  stderr.writeln('// Bbox: $bbox');
  stderr.writeln('// Source ID: $sourceId');
  stderr.writeln('// Appel Overpass...');

  final extractor = OsmOverpassExtractor();

  try {
    final overpassJson = await extractor.fetchOverpass(bbox);
    stderr.writeln('// Éléments reçus: ${(overpassJson['elements'] as List).length}');

    final result = extractor.extractFromResponse(
      overpassJson,
      destinationKey: destinationKey,
      countryCode: countryCode,
      sourcePrimaryId: sourceId,
    );

    stderr.writeln('// POIs extraits: ${result.poiCount}');
    stderr.writeln('// Ignorés: ${result.skippedCount}');
    if (result.warnings.isNotEmpty) {
      stderr.writeln('// Warnings (${result.warnings.length}):');
      for (final w in result.warnings) {
        stderr.writeln('//   - $w');
      }
    }

    // Sortie JSON sur stdout
    const encoder = JsonEncoder.withIndent('  ');
    // ignore: avoid_print
    print(encoder.convert(result.fixtureJson));
  } on OverpassException catch (e) {
    stderr.writeln('ERREUR Overpass: $e');
    exit(2);
  } catch (e) {
    stderr.writeln('ERREUR inattendue: $e');
    exit(3);
  }
}

Map<String, String?> _parseArgs(List<String> args) {
  final result = <String, String?>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--help':
        result['help'] = 'true';
      case '--destination':
      case '--country':
      case '--bbox':
      case '--source-id':
        if (i + 1 < args.length) {
          result[arg.substring(2)] = args[++i];
        }
    }
  }
  return result;
}

BoundingBox _resolveBbox(String? raw, String destinationKey) {
  if (raw != null) {
    final parts = raw.split(',').map(double.parse).toList();
    if (parts.length != 4) {
      throw ArgumentError('bbox doit avoir 4 valeurs: s,w,n,e');
    }
    return BoundingBox(
      minLat: parts[0],
      minLon: parts[1],
      maxLat: parts[2],
      maxLon: parts[3],
    );
  }
  return switch (destinationKey.toLowerCase()) {
    'singapore' => BoundingBox.singapore,
    'paris' => BoundingBox.paris,
    _ => throw ArgumentError(
        'Bbox inconnue pour "$destinationKey". Utilisez --bbox.',
      ),
  };
}

String _randomUuid() {
  // UUID v4 minimal pour la source_id
  final rnd = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
  return '${rnd.substring(0, 8)}-${rnd.substring(8, 12)}-4${rnd.substring(13, 16)}-a${rnd.substring(17, 20)}-${rnd.substring(20, 32)}';
}


