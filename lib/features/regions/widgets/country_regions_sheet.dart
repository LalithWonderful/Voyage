import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/regions/data/country_regions.dart';
import 'package:voyage/features/regions/models/country_region.dart';
import 'package:voyage/features/regions/services/country_regions_repository.dart';
import 'package:voyage/features/regions/services/region_scoring_service.dart';
import 'package:voyage/features/regions/widgets/country_regions_cards.dart';

/// Résultat du choix utilisateur dans la sheet :
/// - `region` : une région a été sélectionnée
/// - `wholeCountry` : "Tout le pays / rayon manuel" pour un travel_region_country
/// La sheet retourne `null` si l'utilisateur annule.
class CountryRegionChoice {
  final CountryRegion? region;
  final bool wholeCountry;

  const CountryRegionChoice._(this.region, this.wholeCountry);

  const CountryRegionChoice.region(CountryRegion r) : this._(r, false);
  const CountryRegionChoice.wholeCountry() : this._(null, true);

  bool get hasRegion => region != null;
}

/// Ouvre la sheet de choix de région pour un grand pays. Retourne null si
/// l'utilisateur annule, sinon une [CountryRegionChoice] indiquant soit la
/// région choisie, soit "Tout le pays" (travel_region uniquement).
///
/// [countryCode] : ISO 2 du pays détecté (ex: 'US', 'TH').
/// [userInterests] / [travelerType] : préférences pour le scoring "Recommandé".
Future<CountryRegionChoice?> openCountryRegionsSheet(
  BuildContext context,
  WidgetRef ref, {
  required String countryCode,
  required List<String> userInterests,
  String? travelerType,
}) async {
  return await showModalBottomSheet<CountryRegionChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CountryRegionsSheet(
      countryCode: countryCode,
      userInterests: userInterests,
      travelerType: travelerType,
    ),
  );
}

class _CountryRegionsSheet extends ConsumerStatefulWidget {
  final String countryCode;
  final List<String> userInterests;
  final String? travelerType;

  const _CountryRegionsSheet({
    required this.countryCode,
    required this.userInterests,
    required this.travelerType,
  });

  @override
  ConsumerState<_CountryRegionsSheet> createState() => _CountryRegionsSheetState();
}

class _CountryRegionsSheetState extends ConsumerState<_CountryRegionsSheet> {
  /// Clé du ScrollController pour scroller vers la liste quand l'user clique
  /// "Voir les autres régions" sur la card recommandée.
  final _scrollController = ScrollController();

  /// Clé du widget "première carte standard" (pour cibler le scroll).
  final _otherRegionsKey = GlobalKey();

  /// Une seule fois par session de la sheet, pour éviter de rescore à
  /// chaque rebuild (économie cycles, surtout important si 5+ régions).
  List<RegionScore>? _scoredCache;

  void _onChooseRegion(CountryRegion region) {
    Navigator.of(context).pop(CountryRegionChoice.region(region));
  }

  void _onChooseWholeCountry() {
    Navigator.of(context).pop(const CountryRegionChoice.wholeCountry());
  }

  void _onSeeOthers() {
    final ctx = _otherRegionsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      alignment: 0.0,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTravelRegion = isTravelRegionCountry(widget.countryCode);
    final regionsAsync = ref.watch(regionsByCountryProvider(widget.countryCode));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: regionsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      'Erreur de chargement des régions : $e',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                ),
                data: (regions) {
                  if (regions.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: Text(
                          'Aucune région préconfigurée pour ce pays.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    );
                  }
                  return _buildContent(regions, isTravelRegion);
                },
              ),
            ),
            // Bouton Annuler toujours visible
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                  ),
                  child: const Text('Annuler'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(List<CountryRegion> regions, bool isTravelRegion) {
    // Lazy scoring : on fait le calcul 1 fois par session de la sheet.
    _scoredCache ??= const RegionScoringService().scoreRegions(
      regions: regions,
      userInterests: widget.userInterests,
      travelerType: widget.travelerType,
    );

    final topRecommended = _scoredCache!.first;
    final countryName = regions.first.countryName;

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        // Header
        Text(
          'Choisir une région',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'pour ton voyage en $countryName',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),

        // Card "✨ Recommandé pour toi"
        RecommendedRegionCard(
          score: topRecommended,
          onChoose: () => _onChooseRegion(topRecommended.region),
          onSeeOthers: _onSeeOthers,
        ),

        const SizedBox(height: 8),
        Text(
          'OU CHOISIS UNE AUTRE RÉGION',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),

        // Liste des régions standard (5 cards)
        for (var i = 0; i < regions.length; i++)
          KeyedSubtree(
            // 1ère card avec key pour le scroll smooth depuis "Voir les autres"
            key: i == 0 ? _otherRegionsKey : null,
            child: RegionCard(
              region: regions[i],
              onTap: () => _onChooseRegion(regions[i]),
            ),
          ),

        // Card "Tout le pays" pour travel_region (TR, TH)
        if (isTravelRegion) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Container(height: 1, color: AppColors.border)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'OU',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: AppColors.border)),
            ],
          ),
          const SizedBox(height: 8),
          WholeCountryCard(
            onTap: _onChooseWholeCountry,
            countryName: countryName,
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}
