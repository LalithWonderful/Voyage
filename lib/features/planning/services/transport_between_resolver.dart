import 'dart:developer' as developer;

import 'package:voyage/core/services/location_service.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';

/// Résolveur déterministe pour les trajets entre deux activités.
///
/// Ne fait aucun appel réseau. Si les deux activités ont des coordonnées,
/// suggère des options de transport basées sur la distance à vol d'oiseau.
/// Sinon, retourne un fallback manuel "Trajet à compléter".
class TransportBetweenResolver {
  final String? _travelerType;

  TransportBetweenResolver({String? travelerType}) : _travelerType = travelerType;

  /// Résout le trajet entre [from] et [to].
  ///
  /// Retourne toujours une [TransportSuggestion] valide (jamais null).
  /// Le champ [TransportSuggestion.defaultMode] permet de distinguer :
  /// - `'manual'` → fallback sans coordonnées ; l'appelant peut décider
  ///   d'essayer Gemini ou d'insérer directement la ligne manuelle.
  /// - tout autre mode → suggestion déterministe basée sur la distance.
  TransportSuggestion resolve({
    required TripActivity from,
    required TripActivity to,
  }) {
    if (from.hasCoordinates && to.hasCoordinates) {
      final distanceKm = haversineKm(
        from.latitude!,
        from.longitude!,
        to.latitude!,
        to.longitude!,
      );
      final suggestion = _buildDeterministic(
        from: from,
        to: to,
        distanceKm: distanceKm,
      );
      developer.log(
        '[transport_between] source=deterministic '
        'distanceKm=${distanceKm.toStringAsFixed(2)} '
        'from="${from.title}" to="${to.title}"',
        name: 'planning',
      );
      return suggestion;
    }

    final suggestion = _buildManualFallback(from: from, to: to);
    developer.log(
      '[transport_between] source=manual_fallback '
      'reason=no_coordinates from="${from.title}" to="${to.title}"',
      name: 'planning',
    );
    return suggestion;
  }

  TransportSuggestion _buildDeterministic({
    required TripActivity from,
    required TripActivity to,
    required double distanceKm,
  }) {
    // Vitesses de référence (km/h)
    const walkSpeed = 5.0;
    const transitSpeed = 25.0;
    const taxiSpeed = 35.0;

    final walkMinutes = (distanceKm / walkSpeed * 60).round();
    final transitMinutes = (distanceKm / transitSpeed * 60).round();
    final taxiMinutes = (distanceKm / taxiSpeed * 60).round();

    final options = <TransportOption>[];

    // Marche pour les très courtes distances (<= 1 km)
    if (distanceKm <= 1.0) {
      options.add(
        TransportOption(
          mode: 'walk',
          durationMinutes: walkMinutes.clamp(1, 120),
          priceEstimate: 'Gratuit',
          detail: '${distanceKm.toStringAsFixed(1)} km',
        ),
      );
    }

    // Transports en commun pour les distances > 1 km
    if (distanceKm > 1.0) {
      options.add(
        TransportOption(
          mode: 'transit',
          durationMinutes: transitMinutes.clamp(5, 180),
          priceEstimate: '~2 €',
          detail: '${distanceKm.toStringAsFixed(1)} km',
        ),
      );

      // Taxi également pour les distances > 1 km
      options.add(
        TransportOption(
          mode: 'taxi',
          durationMinutes: taxiMinutes.clamp(5, 180),
          priceEstimate: '~8 €',
          detail: '${distanceKm.toStringAsFixed(1)} km',
        ),
      );
    }

    final defaultMode = _pickDefaultMode(distanceKm);

    return TransportSuggestion(
      fromTitle: from.title,
      toTitle: to.title,
      defaultMode: defaultMode,
      options: options,
    );
  }

  TransportSuggestion _buildManualFallback({
    required TripActivity from,
    required TripActivity to,
  }) {
    return TransportSuggestion(
      fromTitle: from.title,
      toTitle: to.title,
      defaultMode: 'manual',
      options: [
        const TransportOption(
          mode: 'manual',
          durationMinutes: 0,
          priceEstimate: '—',
          detail: 'Trajet à compléter',
        ),
      ],
    );
  }

  String _pickDefaultMode(double distanceKm) {
    if (distanceKm <= 1.0) {
      return 'walk';
    }
    switch (_travelerType) {
      case 'Grand luxe':
      case 'Voyage pro':
        return 'taxi';
      case 'Backpack':
      case 'Meilleur prix':
        return 'transit';
      case 'En famille':
        return 'transit';
      default:
        return 'transit';
    }
  }
}
