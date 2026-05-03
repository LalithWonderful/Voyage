import 'dart:async';
import 'dart:developer' as developer;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Écoute le retour de connectivité réseau et invalide les providers Trip
/// pour déclencher un re-fetch automatique. Sans ça, le bandeau "📵 Mode
/// hors ligne" reste affiché jusqu'à ce que l'user fasse un pull-to-refresh
/// ou navigue vers un écran qui re-déclenche un fetch — pas évident.
///
/// Place dans le tree au-dessus de MaterialApp, sous ProviderScope.
/// `connectivity_plus` émet sur tous les changements (wifi on/off, data,
/// mode avion). On filtre uniquement les transitions offline → online pour
/// éviter les invalidations inutiles.
class ConnectivityListener extends ConsumerStatefulWidget {
  final Widget child;
  const ConnectivityListener({super.key, required this.child});

  @override
  ConsumerState<ConnectivityListener> createState() => _ConnectivityListenerState();
}

class _ConnectivityListenerState extends ConsumerState<ConnectivityListener> {
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _wasOffline = false;

  @override
  void initState() {
    super.initState();
    _sub = Connectivity().onConnectivityChanged.listen(_onChanged);
  }

  void _onChanged(List<ConnectivityResult> results) {
    // `none` seul = vraiment hors ligne. Tout autre résultat (wifi, mobile,
    // ethernet, vpn, bluetooth) = on a une route réseau, on tente le fetch.
    // Si la route échoue (DNS down, captive portal, etc.), les providers
    // tombent quand même en fallback cache — donc safe d'invalider.
    final isOnline = results.any((r) => r != ConnectivityResult.none);
    if (isOnline && _wasOffline) {
      developer.log('[connectivity] retour online → refresh providers', name: 'connectivity');
      // Invalide les providers principaux. Les `family` se rafraîchissent
      // pour TOUS les paramètres actifs — l'écran consommateur recharge.
      // Au succès, `isOfflineProvider` repasse à false dans chaque provider
      // patché → le bandeau disparaît automatiquement.
      ref.invalidate(tripsProvider);
      ref.invalidate(tripActivitiesProvider);
      ref.invalidate(tripTransportsProvider);
      ref.invalidate(tripDocumentsProvider);
      ref.invalidate(documentsProvider);
    }
    _wasOffline = !isOnline;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
