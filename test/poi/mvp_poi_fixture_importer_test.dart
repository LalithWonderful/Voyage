import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/poi/tools/mvp_poi_fixture_importer.dart';

void main() {
  group('MvpPoiFixtureImporter', () {
    const importer = MvpPoiFixtureImporter();

    test('dry-runs all cities by default', () async {
      final run = await importer.run(const MvpPoiFixtureImportOptions());

      expect(run.dryRun, isTrue);
      expect(run.reports.map((r) => r.city), equals(['paris', 'lisbon']));
      expect(run.reports, hasLength(2));

      for (final report in run.reports) {
        expect(report.payload.pois, hasLength(10));
        expect(report.payload.poiDestinationLinks, hasLength(10));
        expect(report.payload.poiQualityScores, hasLength(10));
        expect(report.payload.poiExternalRefs, hasLength(10));
        expect(report.payload.poiImportIssues, isEmpty);
        expect(report.summaryText(), contains('city: ${report.city}'));
        expect(report.summaryText(), contains('poi_count: 10'));
        expect(report.summaryText(), contains('import_issues_count: 0'));
      }
    });

    test('processes Paris only', () async {
      final run = await importer.run(
        const MvpPoiFixtureImportOptions(city: 'paris'),
      );

      expect(run.reports, hasLength(1));
      expect(run.reports.single.city, equals('paris'));
      expect(run.reports.single.payload.pois.first['destination_key'], 'paris');
    });

    test('processes Lisbon only', () async {
      final run = await importer.run(
        const MvpPoiFixtureImportOptions(city: 'lisbon'),
      );

      expect(run.reports, hasLength(1));
      expect(run.reports.single.city, equals('lisbon'));
      expect(
        run.reports.single.payload.pois.first['destination_key'],
        'lisbon',
      );
    });

    test('maps fixture records to MVP Supabase payload shape', () async {
      final run = await importer.run(
        const MvpPoiFixtureImportOptions(city: 'paris'),
      );
      final payload = run.reports.single.payload;

      expect(payload.poiSources.single['source_type'], equals('editorial'));
      expect(
        payload.poiCategories.map((c) => c['category_key']),
        contains('monument'),
      );

      final eiffelTower = payload.pois.firstWhere(
        (poi) => poi['payload']['poi_slug'] == 'paris_eiffel_tower',
      );
      expect(
        eiffelTower['poi_id'],
        equals('7b1a28f4-b143-5fae-b180-96a5bebe418b'),
      );
      expect(eiffelTower['canonical_name'], equals('Eiffel Tower'));
      expect(eiffelTower['primary_category_key'], equals('monument'));
      expect(eiffelTower.containsKey('google_place_id'), isFalse);

      expect(
        payload.poiLocalizedNames.where(
          (name) => name['poi_id'] == eiffelTower['poi_id'],
        ),
        hasLength(2),
      );
      expect(
        payload.poiDestinationLinks.singleWhere(
          (link) => link['poi_id'] == eiffelTower['poi_id'],
        )['destination_key'],
        equals('paris'),
      );
      expect(
        payload.poiQualityScores.singleWhere(
          (score) => score['poi_id'] == eiffelTower['poi_id'],
        )['overall_score'],
        equals(97),
      );
    });

    test('rejects invalid city', () {
      expect(
        () => importer.run(const MvpPoiFixtureImportOptions(city: 'rome')),
        throwsA(
          isA<MvpPoiFixtureImportException>().having(
            (e) => e.message,
            'message',
            contains('Unsupported city "rome"'),
          ),
        ),
      );
    });

    test('parses CLI defaults and city option', () {
      expect(MvpPoiFixtureImportOptions.fromArgs(const []).city, equals('all'));
      expect(
        MvpPoiFixtureImportOptions.fromArgs(const ['--city', 'paris']).city,
        equals('paris'),
      );
      expect(
        MvpPoiFixtureImportOptions.fromArgs(const ['--write']).write,
        isTrue,
      );
    });

    test('blocks write by default before Supabase credentials are needed', () {
      expect(
        () => importer.run(
          const MvpPoiFixtureImportOptions(write: true, dryRun: false),
        ),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.supabase)
              .having(
                (e) => e.operation,
                'operation',
                mvpPoiFixtureImportWriteOperation,
              )
              .having((e) => e.message, 'message', contains('Supabase'))
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_SUPABASE=true'),
              ),
        ),
      );
    });

    test(
      'write remains intentionally deferred even with explicit guard opt-in',
      () {
        const allowedImporter = MvpPoiFixtureImporter(
          guards: LiveApiGuards(allowSupabase: true),
        );

        expect(
          () => allowedImporter.run(
            const MvpPoiFixtureImportOptions(write: true, dryRun: false),
          ),
          throwsA(
            isA<MvpPoiFixtureImportException>().having(
              (e) => e.message,
              'message',
              contains('intentionally deferred'),
            ),
          ),
        );
      },
    );
  });
}
