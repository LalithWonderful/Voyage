import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/regions/data/region_tags.dart';
import 'package:voyage/features/regions/models/country_region.dart';
import 'package:voyage/features/regions/services/region_scoring_service.dart';

/// Convertit un code pays ISO 2 en emoji drapeau Unicode.
/// Ex: 'US' → 🇺🇸. Retourne 🌍 si invalide.
String countryFlagEmoji(String iso2) {
  if (iso2.length != 2) return '🌍';
  final upper = iso2.toUpperCase();
  const base = 0x1F1E6 - 65; // 'A' = U+1F1E6 (regional indicator)
  return String.fromCharCodes([
    base + upper.codeUnitAt(0),
    base + upper.codeUnitAt(1),
  ]);
}

/// Card "✨ Recommandé pour toi" affichée en haut de la liste, mise en
/// évidence visuellement. Affiche la région top-1 du scoring déterministe
/// avec son explication ("Choisi pour : Culture · Histoire · Palais") et
/// un bouton "Choisir cette région". Pas de bouton "Voir les autres" :
/// les autres régions sont déjà listées juste en dessous, c'est redondant.
class RecommendedRegionCard extends StatelessWidget {
  final RegionScore score;
  final VoidCallback onChoose;

  const RecommendedRegionCard({
    super.key,
    required this.score,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final region = score.region;
    // Tags FR à expliquer (max 3 pour ne pas surcharger l'UI)
    final whyLabels = tagsToFrLabels(score.matchedTags, maxCount: 3);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('✨', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Text(
                'Recommandé pour toi',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(countryFlagEmoji(region.countryCode), style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      region.regionName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      region.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (whyLabels.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Choisi pour : ${whyLabels.join(' · ')}',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: AppColors.textSecondary,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onChoose,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text(
                'Choisir cette région',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Card standard pour une région (priority 1-5). Tap pour sélectionner.
/// Affiche : drapeau + nom région + label (villes) + radius + tags FR (max 3).
class RegionCard extends StatelessWidget {
  final CountryRegion region;
  final VoidCallback onTap;

  const RegionCard({super.key, required this.region, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tagLabels = tagsToFrLabels(region.tags, maxCount: 3);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(countryFlagEmoji(region.countryCode), style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    region.regionName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    region.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${region.recommendedRadiusKm} km'
                    '${tagLabels.isEmpty ? "" : " · ${tagLabels.join(" · ")}"}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Card "🌍 Tout le pays" affichée en bas de la liste pour les pays
/// `travel_region_country` (TR, TH). Permet à l'utilisateur de bypasser
/// le choix de région et garder un rayon manuel.
class WholeCountryCard extends StatelessWidget {
  final VoidCallback onTap;
  final String countryName;

  const WholeCountryCard({
    super.key,
    required this.onTap,
    required this.countryName,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.border,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          children: [
            const Text('🌍', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tout le pays',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Je préfère garder un rayon manuel',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
