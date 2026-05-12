/// POI-1.0 — Écran debug interne pour inspecter la qualité des données POI.
///
/// Accessible uniquement en mode debug (`kDebugMode`) via un bouton
/// dans `ProfileScreen`. Ne fait aucun appel réseau direct : utilise
/// les providers Riverpod POI-0.9 (`poiSearchProvider`, `poiRepositoryProvider`).
///
/// Fonctionnalités :
/// - liste des POI par `destination_key` ;
/// - recherche textuelle (`query`) ;
/// - filtre par catégorie ;
/// - filtre "must-see only" ;
/// - limite de résultats ;
/// - affichage détaillé : nom, catégorie, score, must-see, source.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/providers/poi_providers.dart';

/// Mapping catégorie → emoji pour une lecture rapide.
const _categoryEmojis = <PoiCategory, String>{
  PoiCategory.mustSee: '⭐',
  PoiCategory.museum: '🏛️',
  PoiCategory.monument: '🗿',
  PoiCategory.viewpoint: '📸',
  PoiCategory.park: '🌳',
  PoiCategory.nature: '🏞️',
  PoiCategory.beach: '🏖️',
  PoiCategory.neighborhood: '🏘️',
  PoiCategory.market: '🛒',
  PoiCategory.food: '🍽️',
  PoiCategory.shopping: '🛍️',
  PoiCategory.nightlife: '🌃',
  PoiCategory.family: '👨‍👩‍👧‍👦',
  PoiCategory.wellness: '💆',
  PoiCategory.transportHub: '🚇',
  PoiCategory.photoSpot: '📷',
  PoiCategory.rainyDay: '🌧️',
  PoiCategory.localExperience: '🎭',
};

/// Écran debug POI. Gated par `kDebugMode` à l'appel site
/// (`ProfileScreen`) — le widget lui-même ne vérifie pas le mode.
class PoiDebugScreen extends ConsumerStatefulWidget {
  const PoiDebugScreen({super.key});

  @override
  ConsumerState<PoiDebugScreen> createState() => _PoiDebugScreenState();
}

class _PoiDebugScreenState extends ConsumerState<PoiDebugScreen> {
  final _destinationCtrl = TextEditingController(text: 'lisbon');
  final _queryCtrl = TextEditingController();
  final _limitCtrl = TextEditingController();

  PoiCategory? _selectedCategory;
  bool _mustSeeOnly = false;
  bool _topMode = false;

  /// Paramètres de recherche actuels. Rebuild déclenche un re-watch du
  /// provider `poiSearchProvider` grâce à Riverpod `family` caching.
  PoiSearchParams get _currentParams => PoiSearchParams(
        destinationKey: _destinationCtrl.text.trim(),
        query: _queryCtrl.text.trim().isEmpty ? null : _queryCtrl.text.trim(),
        category: _selectedCategory,
        mustSeeOnly: _mustSeeOnly,
        limit: int.tryParse(_limitCtrl.text.trim()),
      );

  @override
  void dispose() {
    _destinationCtrl.dispose();
    _queryCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  Widget _buildSearchResults() {
    final poisAsync = ref.watch(poiSearchProvider(_currentParams));
    return poisAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => _ErrorView(error: err.toString(), onRetry: () => setState(() {})),
      data: (pois) => _PoiListView(pois: pois),
    );
  }

  Widget _buildTopResults() {
    final destination = _destinationCtrl.text.trim();
    final poisAsync = ref.watch(
      topPoisProvider((destinationKey: destination, limit: 10)),
    );
    return poisAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => _ErrorView(error: err.toString(), onRetry: () => setState(() {})),
      data: (pois) => _PoiListView(pois: pois, label: 'Top 10'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final poisAsync = ref.watch(poiSearchProvider(_currentParams));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('🔍 Debug POI', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: AppColors.border, height: 1),
        ),
      ),
      body: Column(
        children: [
          // ─── Panneau de filtres ───
          _FilterPanel(
            destinationCtrl: _destinationCtrl,
            queryCtrl: _queryCtrl,
            limitCtrl: _limitCtrl,
            selectedCategory: _selectedCategory,
            mustSeeOnly: _mustSeeOnly,
            onCategoryChanged: (cat) => setState(() => _selectedCategory = cat),
            onMustSeeChanged: (v) => setState(() => _mustSeeOnly = v),
            onSearch: () => setState(() {}),
          ),
          // ─── Quick actions ───
          _QuickActions(
            topMode: _topMode,
            onTopModeChanged: (v) => setState(() => _topMode = v),
          ),
          // ─── Résultats ───
          Expanded(
            child: _topMode
                ? _buildTopResults()
                : _buildSearchResults(),
          ),
        ],
      ),
    );
  }
}

// ─── Sous-widgets ───

class _FilterPanel extends StatelessWidget {
  final TextEditingController destinationCtrl;
  final TextEditingController queryCtrl;
  final TextEditingController limitCtrl;
  final PoiCategory? selectedCategory;
  final bool mustSeeOnly;
  final ValueChanged<PoiCategory?> onCategoryChanged;
  final ValueChanged<bool> onMustSeeChanged;
  final VoidCallback onSearch;

  const _FilterPanel({
    required this.destinationCtrl,
    required this.queryCtrl,
    required this.limitCtrl,
    required this.selectedCategory,
    required this.mustSeeOnly,
    required this.onCategoryChanged,
    required this.onMustSeeChanged,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Destination + Recherche
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _FilterTextField(
                  controller: destinationCtrl,
                  label: 'Destination key',
                  hint: 'ex: singapore',
                  onSubmitted: (_) => onSearch(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: _FilterTextField(
                  controller: queryCtrl,
                  label: 'Recherche',
                  hint: 'Nom, alias…',
                  onSubmitted: (_) => onSearch(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Catégorie + Limit + Must-see
          Row(
            children: [
              Expanded(
                child: _CategoryDropdown(
                  value: selectedCategory,
                  onChanged: onCategoryChanged,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: _FilterTextField(
                  controller: limitCtrl,
                  label: 'Limite',
                  hint: '∞',
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => onSearch(),
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: mustSeeOnly,
                    onChanged: (v) => onMustSeeChanged(v ?? false),
                    activeColor: AppColors.primary,
                  ),
                  const Text('Must-see', style: TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onSearch,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Rechercher'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(40),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;

  const _FilterTextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(fontSize: 11, color: AppColors.textSecondary),
        hintStyle: TextStyle(fontSize: 12, color: AppColors.textSecondary.withValues(alpha: 0.5)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
      ),
    );
  }
}

class _CategoryDropdown extends StatelessWidget {
  final PoiCategory? value;
  final ValueChanged<PoiCategory?> onChanged;

  const _CategoryDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<PoiCategory?>(
          value: value,
          isExpanded: true,
          isDense: true,
          hint: Text('Catégorie', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          items: [
            const DropdownMenuItem<PoiCategory?>(
              value: null,
              child: Text('Toutes', style: TextStyle(fontSize: 13)),
            ),
            ...PoiCategory.values.map((cat) {
              return DropdownMenuItem<PoiCategory?>(
                value: cat,
                child: Text(
                  '${_categoryEmojis[cat] ?? ''} ${cat.toJsonString()}',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final bool topMode;
  final ValueChanged<bool> onTopModeChanged;

  const _QuickActions({required this.topMode, required this.onTopModeChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('Recherche'),
            selected: !topMode,
            onSelected: (_) => onTopModeChanged(false),
            selectedColor: AppColors.primaryLight,
            labelStyle: TextStyle(
              fontSize: 12,
              color: !topMode ? AppColors.primary : AppColors.textSecondary,
              fontWeight: !topMode ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Top 10'),
            selected: topMode,
            onSelected: (_) => onTopModeChanged(true),
            selectedColor: AppColors.primaryLight,
            labelStyle: TextStyle(
              fontSize: 12,
              color: topMode ? AppColors.primary : AppColors.textSecondary,
              fontWeight: topMode ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('⚠️', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              'Erreur de chargement',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.error),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PoiListView extends StatelessWidget {
  final List<Poi> pois;
  final String? label;
  const _PoiListView({required this.pois, this.label});

  @override
  Widget build(BuildContext context) {
    if (pois.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('📭', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 16),
              Text(
                'Aucun POI trouvé',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Essaye une autre destination ou modifie les filtres.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              label!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: pois.length,
            itemBuilder: (_, index) {
              final poi = pois[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PoiDebugCard(poi: poi, index: index + 1),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PoiDebugCard extends StatelessWidget {
  final Poi poi;
  final int index;
  const _PoiDebugCard({required this.poi, required this.index});

  @override
  Widget build(BuildContext context) {
    final emoji = _categoryEmojis[poi.category] ?? '📍';
    final score = poi.editorialScore;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(emoji, style: const TextStyle(fontSize: 18)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      poi.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '#$index · ${poi.category.toJsonString()} · ${poi.poiId.substring(0, poi.poiId.length > 8 ? 8 : poi.poiId.length)}…',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (poi.isMustSee)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'MUST-SEE',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFB45309)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Ligne de métriques
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              if (score != null) _MetricChip(icon: '📊', label: 'Score $score/100'),
              if (poi.touristicImportance != null)
                _MetricChip(icon: '⭐', label: 'Imp. ${poi.touristicImportance}/5'),
              if (poi.typicalDurationMinutes != null)
                _MetricChip(icon: '⏱️', label: '${poi.typicalDurationMinutes} min'),
              if (poi.priceLevel != null)
                _MetricChip(icon: '💰', label: 'Prix ${poi.priceLevel}/4'),
              if (poi.isFree == true) _MetricChip(icon: '🆓', label: 'Gratuit'),
              if (poi.isFamilyFriendly == true) _MetricChip(icon: '👨‍👩‍👧‍👦', label: 'Famille'),
              if (poi.isRainFriendly == true) _MetricChip(icon: '🌧️', label: 'Pluie'),
            ],
          ),
          const SizedBox(height: 8),
          // Source
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'source: ${poi.sourcePrimaryId}',
              style: TextStyle(fontSize: 10, color: AppColors.textSecondary, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String icon;
  final String label;
  const _MetricChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
