import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Affiche les warnings UX pour un document Hébergement quand les conditions
/// nécessaires aux trajets hôtel ↔ activité ne sont pas réunies :
/// - dates check-in/check-out manquantes (sans dates, l'hôtel n'apparaît pas
///   dans la timeline → aucun trajet calculable),
/// - adresse introuvable au géocodage (sans coords, le pipeline trajets ne
///   peut pas calculer la distance/durée).
///
/// Retourne `SizedBox.shrink` si rien à signaler — safe à inclure inconditionnellement.
class HotelDocWarnings extends StatelessWidget {
  final TripDocument doc;
  final double fontSize;
  const HotelDocWarnings({super.key, required this.doc, this.fontSize = 11});

  @override
  Widget build(BuildContext context) {
    if (doc.category != DocumentCategory.hotel) {
      return const SizedBox.shrink();
    }
    final missingDates = doc.metadata['check_in'] == null ||
        doc.metadata['check_out'] == null;
    final geocodingFailed = doc.metadata['geocoding_failed'] == true;
    if (!missingDates && !geocodingFailed) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (missingDates) ...[
          const SizedBox(height: 4),
          _row('Dates manquantes'),
        ],
        if (geocodingFailed) ...[
          const SizedBox(height: 4),
          _row('Adresse introuvable'),
        ],
      ],
    );
  }

  /// Couleur accent (ambre) plutôt qu'error (rouge) : ce sont des "nudges"
  /// pour des infos optionnelles, pas des erreurs bloquantes.
  Widget _row(String message) {
    return Row(
      children: [
        Icon(Icons.warning_amber_rounded, size: fontSize + 1, color: AppColors.accent),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: fontSize, color: AppColors.accent, fontWeight: FontWeight.w500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
