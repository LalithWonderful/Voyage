import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/providers/offline_provider.dart';
import 'package:voyage/core/theme/app_theme.dart';

/// Bandeau ambre "Mode hors ligne" affiché en haut d'un écran quand un
/// provider Trip a fallback sur le cache local. Disparaît automatiquement
/// au prochain fetch réussi (l'`isOfflineProvider` repasse à false).
///
/// Wording doux + icône cloud_off, couleur accent (ambre) cohérente avec
/// les autres warnings UX (TransportDocWarnings, etc.). À insérer en haut
/// de tout écran qui consomme des données voyages — l'user comprend
/// immédiatement pourquoi certaines actions sont désactivées.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isOfflineProvider);
    if (!offline) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.accent.withValues(alpha: 0.15),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Mode hors ligne — affichage depuis le cache local',
              style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Variante Sliver de `OfflineBanner` — à utiliser dans les écrans avec
/// `CustomScrollView` (trips_screen, trip_detail_screen).
class OfflineSliverBanner extends ConsumerWidget {
  const OfflineSliverBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isOfflineProvider);
    if (!offline) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return const SliverToBoxAdapter(child: OfflineBanner());
  }
}
