import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';

/// Card unifiée représentant une étape de voyage. Utilisée dans 2 contextes :
///
/// - **Preview / readOnly** (ex: `DetectedSegmentsSheet`) : avec `sourceLabel`
///   pour afficher la provenance du séjour (ex: "Depuis : Turkish Airlines").
///   Le caller wrappe la card dans une timeline avec dot + connecteur.
///
/// - **Editable** (ex: section "Étapes du voyage" de la sheet d'édition) :
///   avec `leading` (drag handle) et `onDelete`. Pas de `sourceLabel`.
///
/// L'objectif design (cf. brief Lalith 2026-05-08) est que les 2 contextes
/// partagent visuellement la même identité d'objet : même radius, padding,
/// hiérarchie typographique, badge durée pill, ombre micro-soft. Le caller
/// gère l'environnement (timeline ou liste reordonnable), la card gère le
/// contenu.
class TripStepCard extends StatelessWidget {
  final String city;
  final String? country;
  final int days;

  /// Date d'arrivée dans la ville. Formatée avec [endDate] sous la forme
  /// "Du DD/MM/YYYY au DD/MM/YYYY" pour cohérence entre les 2 contextes.
  final DateTime startDate;

  /// Date de départ de la ville (= début de l'étape suivante).
  final DateTime endDate;

  /// Source détectée (ex: "Turkish Airlines"). Si non null, affichée en
  /// 3e ligne avec une icône avion. Typiquement utilisée en mode preview.
  final String? sourceLabel;

  /// Widget affiché à gauche du contenu (drag handle ou icône). Le caller
  /// décide de son apparence et de son comportement (ex: gesture detector
  /// ou ReorderableDragStartListener).
  final Widget? leading;

  /// Callback de tap sur la card (ouvre l'éditeur en mode editable).
  final VoidCallback? onTap;

  /// Si défini, affiche un bouton suppression discret à droite. Mode editable.
  final VoidCallback? onDelete;

  const TripStepCard({
    super.key,
    required this.city,
    required this.country,
    required this.days,
    required this.startDate,
    required this.endDate,
    this.sourceLabel,
    this.leading,
    this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: AppColors.border.withValues(alpha: 0.7),
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        // Drag handle (à gauche) et delete (à droite) sont centrés
        // verticalement sur la card pour qu'ils s'alignent l'un avec l'autre.
        // Le contenu central garde son propre alignement haut/gauche via
        // son Column interne — visuellement le centrage du Row n'a pas
        // d'effet sur lui (il occupe toute la hauteur disponible).
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ligne 1 : ville + pays + badge durée
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: city,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            if (country != null && country!.isNotEmpty)
                              TextSpan(
                                text: '  ·  $country',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _DurationPill(days: days),
                  ],
                ),
                const SizedBox(height: 4),
                // Ligne 2 : dates "Du DD/MM/YYYY au DD/MM/YYYY"
                Row(
                  children: [
                    Icon(Icons.calendar_today,
                        size: 11, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Du ${_fmt(startDate)} au ${_fmt(endDate)}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                // Ligne 3 (optionnelle) : source détectée
                if (sourceLabel != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.flight,
                          size: 11, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Depuis : $sourceLabel',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 4),
            // Bouton supprimer discret (n'attire pas l'attention principale).
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              color: AppColors.textSecondary.withValues(alpha: 0.7),
              tooltip: 'Supprimer cette étape',
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 28, minHeight: 28),
              splashRadius: 18,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: card,
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Pill arrondi mettant en avant la durée du séjour. Léger contraste avec
/// border subtile pour un rendu premium sans aplat brut.
class _DurationPill extends StatelessWidget {
  final int days;
  const _DurationPill({required this.days});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      child: Text(
        '$days jour${days > 1 ? 's' : ''}',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryDark,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
