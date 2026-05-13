import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/poi/tools/supabase_live_guard.dart';

void main() {
  group('POI Supabase live guards', () {
    test('verification tools are blocked by default', () {
      expect(
        () => assertLiveSupabaseAllowedForPoiTool(
          operation: poiVerifySchemaOperation,
          guards: LiveApiGuards.defaults(),
        ),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.supabase)
              .having((e) => e.operation, 'operation', poiVerifySchemaOperation)
              .having((e) => e.message, 'message', contains('Supabase'))
              .having(
                (e) => e.message,
                'message',
                contains(poiVerifySchemaOperation),
              )
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_SUPABASE=true'),
              ),
        ),
      );
    });

    test('ALLOW_LIVE_SUPABASE allows verification tools', () {
      final guards = LiveApiGuards.fromEnvironmentMap(const {
        'ALLOW_LIVE_SUPABASE': 'true',
      });

      expect(
        () => assertLiveSupabaseAllowedForPoiTool(
          operation: poiVerifyImportOperation,
          guards: guards,
        ),
        returnsNormally,
      );
    });
  });
}
