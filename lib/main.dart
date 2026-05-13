import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/core/constants/supabase_constants.dart';
import 'package:voyage/core/services/deep_link_service.dart';
import 'package:voyage/core/services/notification_service.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/connectivity_listener.dart';
import 'package:voyage/core/router/app_router.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/poi/data/live_poi_supabase_client.dart';
import 'package:voyage/features/poi/data/supabase_poi_repository.dart';
import 'package:voyage/features/poi/providers/poi_repository_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: SupabaseConstants.supabaseUrl,
    anonKey: SupabaseConstants.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
  );
  await NotificationService.instance.init();

  // POI-2.4 — Branchement du repository POI live pour que les destinations
  // couvertes (lisbon, paris, rome, barcelona) puissent planifier sans
  // appeler Google Places.
  final poiClient = LivePoiSupabaseClient(Supabase.instance.client);
  final poiRepository = SupabasePoiRepository(poiClient);

  runApp(
    ProviderScope(
      overrides: [
        poiRepositoryProvider.overrideWithValue(poiRepository),
      ],
      child: const VoyageApp(),
    ),
  );
}

class VoyageApp extends ConsumerStatefulWidget {
  const VoyageApp({super.key});

  @override
  ConsumerState<VoyageApp> createState() => _VoyageAppState();
}

class _VoyageAppState extends ConsumerState<VoyageApp> {
  @override
  void initState() {
    super.initState();
    // On init le deep link listener au prochain frame, pour s'assurer que le
    // router est bien prêt avant de router vers /reset-password.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.instance.init(
        router: ref.read(routerProvider),
        client: ref.read(supabaseProvider),
      );
    });
  }

  @override
  void dispose() {
    DeepLinkService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Voyage',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      builder: (context, child) {
        AppColors.setBrightness(Theme.of(context).brightness);
        // ConnectivityListener écoute le retour de connectivité réseau et
        // invalide automatiquement les providers Trip → re-fetch transparent
        // → bandeau "hors ligne" disparaît dès que le wifi/data revient.
        return ConnectivityListener(child: child!);
      },
      routerConfig: router,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('fr'),
        Locale('en'),
      ],
    );
  }
}
