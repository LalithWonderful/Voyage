import 'package:voyage/config/live_api_guards.dart';

const poiVerifySchemaOperation = 'PoiSupabaseVerifySchema.verifyTables';
const poiVerifyImportOperation = 'PoiSupabaseVerifyImport.checkDestination';
const poiPilotImportWriteOperation = 'PoiSupabasePilotImport.write';

void assertLiveSupabaseAllowedForPoiTool({
  required String operation,
  LiveApiGuards? guards,
}) {
  (guards ?? LiveApiGuards.fromEnvironment()).assertAllowed(
    LiveApiFamily.supabase,
    operation: operation,
  );
}
