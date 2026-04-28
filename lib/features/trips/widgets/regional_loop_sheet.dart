import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Affiche un bottom sheet qui propose une boucle régionale (suggestion Gemini)
/// autour de la destination principale. L'utilisateur coche les étapes qu'il
/// veut garder, le sheet retourne la liste des `TripSegment` sélectionnés.
/// Retourne null si l'utilisateur annule ou si Gemini échoue.
///
/// [existingCities] : villes déjà présentes dans les étapes du voyage. Sont
/// affichées en grisé "déjà ajoutée" pour éviter les doublons sur 2e clic.
/// [existingDaysPlaced] : total des jours déjà placés dans les étapes — Gemini
/// reçoit cette info pour ne proposer que le reliquat (évite que la somme dépasse
/// la durée du voyage sur un 2e clic).
/// [destinationKind] : `city` / `country` / `region` / `place` / `unknown`.
/// Si pays/région, le service Gemini propose des villes DANS la destination
/// (pas la destination elle-même). Sert aussi à adapter le sous-titre.
Future<List<TripSegment>?> openRegionalLoopSheet(
  BuildContext context,
  WidgetRef ref, {
  required String mainDestination,
  required int durationDays,
  String? travelerType,
  List<String> interests = const [],
  List<String> existingCities = const [],
  int existingDaysPlaced = 0,
  String? destinationKind,
}) async {
  return await showModalBottomSheet<List<TripSegment>?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _RegionalLoopSheet(
      mainDestination: mainDestination,
      durationDays: durationDays,
      travelerType: travelerType,
      interests: interests,
      existingCities: existingCities,
      existingDaysPlaced: existingDaysPlaced,
      destinationKind: destinationKind,
    ),
  );
}

class _RegionalLoopSheet extends ConsumerStatefulWidget {
  final String mainDestination;
  final int durationDays;
  final String? travelerType;
  final List<String> interests;
  final List<String> existingCities;
  final int existingDaysPlaced;
  final String? destinationKind;
  const _RegionalLoopSheet({
    required this.mainDestination,
    required this.durationDays,
    required this.travelerType,
    required this.interests,
    required this.existingCities,
    required this.existingDaysPlaced,
    this.destinationKind,
  });

  @override
  ConsumerState<_RegionalLoopSheet> createState() => _RegionalLoopSheetState();
}

class _RegionalLoopSheetState extends ConsumerState<_RegionalLoopSheet> {
  /// Périmètres proposés (km). 150 par défaut = bonne valeur pour une région
  /// française moyenne (Lorraine + Alsace + Luxembourg accessibles).
  static const _radiiKm = [50, 100, 150, 250, 500];
  int _radiusKm = 150;

  /// Si vrai, l'IA ne propose QUE des villes du même pays que la destination.
  /// Utile pour les voyageurs qui ne veulent pas multiplier les changements
  /// de devise / passer la frontière.
  ///
  /// Défaut adaptatif : coché quand l'utilisateur a tapé un pays/une région
  /// comme destination (signal explicite "je veux ce pays"). Décoché pour les
  /// destinations ville où l'extension transfrontalière a souvent du sens
  /// (Strasbourg → Trèves, Lille → Bruges).
  late bool _sameCountryOnly =
      widget.destinationKind == 'country' || widget.destinationKind == 'region';

  bool _loading = false;
  bool _hasFetchedOnce = false;
  String? _error;
  List<({String city, String country, int days, String description})> _suggestions = const [];
  Set<int> _selected = {};

  /// Villes déjà proposées par Gemini dans cette session (cumulé entre re-fetch
  /// successifs). Sert à éviter que "Re-suggérer" retombe sur les mêmes villes :
  /// on les passe en exclusion explicite à Gemini pour forcer des alternatives.
  /// Reset quand le périmètre ou le filtre pays change → "nouvelle recherche".
  final Set<String> _previouslyProposed = {};

  /// Périmètre/filtre utilisés lors du dernier fetch — sert à savoir si
  /// l'utilisateur a changé de paramètres pour adapter le label du bouton.
  int? _lastFetchedRadius;
  bool? _lastFetchedSameCountry;

  /// True si la destination est un pays ou une région (vs une ville précise).
  /// Sert à adapter le wording ("autour de Nancy" vs "· États-Unis").
  bool get _isLargeDestination =>
      widget.destinationKind == 'country' || widget.destinationKind == 'region';

  /// Détecte si une suggestion est une ville déjà ajoutée par l'utilisateur
  /// (comparaison case-insensitive sur le nom de la ville).
  bool _isAlreadyAdded(String city) {
    final normalized = city.trim().toLowerCase();
    return widget.existingCities.any((c) => c.trim().toLowerCase() == normalized);
  }

  /// True si l'utilisateur a changé périmètre ou filtre pays depuis le dernier fetch.
  /// Détermine si on garde l'historique des villes proposées (clic "voir d'autres villes")
  /// ou si on reset (l'utilisateur veut une nouvelle recherche dans un nouveau cadre).
  bool get _paramsChangedSinceLastFetch =>
      _lastFetchedRadius != _radiusKm || _lastFetchedSameCountry != _sameCountryOnly;

  Future<void> _fetch() async {
    // Si l'utilisateur a touché radius ou toggle pays, on reset l'historique :
    // c'est une "nouvelle recherche" et les villes hors radius précédent peuvent
    // redevenir pertinentes. Sinon on cumule pour garantir des suggestions inédites.
    if (_paramsChangedSinceLastFetch) _previouslyProposed.clear();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(aiSuggestionsServiceProvider);
      final excludeAll = <String>{
        ...widget.existingCities,
        ..._previouslyProposed,
      }.toList();
      final result = await service.suggestRegionalItinerary(
        mainDestination: widget.mainDestination,
        durationDays: widget.durationDays,
        travelerType: widget.travelerType,
        interests: widget.interests,
        radiusKm: _radiusKm,
        sameCountryOnly: _sameCountryOnly,
        excludeCities: excludeAll,
        daysAlreadyPlaced: widget.existingDaysPlaced,
        destinationKind: widget.destinationKind,
      );
      if (!mounted) return;
      // Coche tout par défaut SAUF les villes déjà ajoutées au voyage
      final selected = <int>{};
      for (var i = 0; i < result.length; i++) {
        if (!_isAlreadyAdded(result[i].city)) selected.add(i);
      }
      // Mémorise les villes proposées pour le prochain re-fetch
      for (final r in result) {
        _previouslyProposed.add(r.city.trim().toLowerCase());
      }
      setState(() {
        _suggestions = result;
        _selected = selected;
        _loading = false;
        _hasFetchedOnce = true;
        _lastFetchedRadius = _radiusKm;
        _lastFetchedSameCountry = _sameCountryOnly;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _hasFetchedOnce = true;
      });
    }
  }

  int get _totalDaysSelected =>
      _selected.fold(0, (sum, i) => sum + _suggestions[i].days);

  /// Durée totale du voyage en jours calendaires (couverture pleine = `_tripDays`).
  /// Sémantique "jours" : un voyage de 9 jours peut être couvert par "Nancy 9 jours".
  int get _tripDays => widget.durationDays.clamp(1, 60);

  /// Total projeté si l'utilisateur valide la sélection courante (existant + nouveau).
  int get _projectedTotal => widget.existingDaysPlaced + _totalDaysSelected;

  void _confirm() {
    final selectedSegments = _selected
        .toList()
        .map((i) => TripSegment(
              city: _suggestions[i].city,
              days: _suggestions[i].days,
              country: _suggestions[i].country.isEmpty ? null : _suggestions[i].country,
            ))
        .toList();
    Navigator.of(context).pop(selectedSegments);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('✨', style: TextStyle(fontSize: 22)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Propose-moi un itinéraire',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    // "autour de" pour une ville ; "·" neutre pour pays/région
                    // (où "autour des États-Unis" n'a aucun sens).
                    _isLargeDestination
                        ? 'Pour ${widget.durationDays} jours · ${widget.mainDestination}'
                        : 'Pour ${widget.durationDays} jours autour de ${widget.mainDestination}',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'PÉRIMÈTRE DE RECHERCHE',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '150 km couvre généralement la région + pays voisins. 250-500 km = grande boucle.',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _radiiKm.map((km) {
                      final selected = _radiusKm == km;
                      return ChoiceChip(
                        label: Text('$km km'),
                        selected: selected,
                        onSelected: _loading ? null : (v) {
                          if (v) setState(() => _radiusKm = km);
                        },
                        selectedColor: AppColors.primary,
                        labelStyle: TextStyle(
                          color: selected ? Colors.white : AppColors.textPrimary,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                          fontSize: 12,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  // Toggle "rester dans le pays" — utile pour éviter changements
                  // devise/langue/visa lors d'un voyage régional.
                  InkWell(
                    onTap: _loading ? null : () => setState(() => _sameCountryOnly = !_sameCountryOnly),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _sameCountryOnly ? Icons.check_box : Icons.check_box_outline_blank,
                            size: 20,
                            color: _sameCountryOnly ? AppColors.primary : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Je ne change pas de pays',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textPrimary,
                                fontWeight: _sameCountryOnly ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _loading ? null : _fetch,
                      icon: _loading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Icon(_hasFetchedOnce ? Icons.refresh : Icons.auto_awesome),
                      label: Text(_loading
                          ? 'Je prépare ton itinéraire...'
                          : !_hasFetchedOnce
                              ? 'Suggérer'
                              : _paramsChangedSinceLastFetch
                                  ? 'Re-suggérer avec ce périmètre'
                                  : 'Voir d\'autres villes'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                  ),
                  if (_hasFetchedOnce && !_paramsChangedSinceLastFetch) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Les villes déjà proposées seront exclues — je chercherai ailleurs dans le même rayon.',
                      style: TextStyle(fontSize: 10, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
            if (_hasFetchedOnce) ...[
              const SizedBox(height: 8),
              Divider(height: 1, color: AppColors.border),
              Expanded(child: _buildBody()),
              // Footer : bilan + CTA
              if (!_loading && _error == null && _suggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    children: [
                      Text(
                        '${_selected.length} étape${_selected.length > 1 ? 's' : ''} sélectionnée${_selected.length > 1 ? 's' : ''} · $_totalDaysSelected jours',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      if (widget.existingDaysPlaced > 0 || _projectedTotal != _tripDays) ...[
                        const SizedBox(height: 2),
                        Text(
                          _projectedTotal > _tripDays
                              ? '⚠ Total projeté : $_projectedTotal jours (dépasse les $_tripDays jours du voyage)'
                              : _projectedTotal == _tripDays
                                  ? '✓ Total projeté : $_projectedTotal / $_tripDays jours — couvre tout le voyage'
                                  : 'Total projeté : $_projectedTotal / $_tripDays jours',
                          style: TextStyle(
                            fontSize: 11,
                            color: _projectedTotal > _tripDays ? AppColors.error : AppColors.textSecondary,
                            fontWeight: _projectedTotal == _tripDays ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Annuler'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _selected.isEmpty ? null : _confirm,
                              child: Text(_selected.isEmpty
                                  ? 'Coche au moins 1 étape'
                                  : 'Ajouter ${_selected.length} étape${_selected.length > 1 ? 's' : ''}'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ] else
              const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text('Je cherche les meilleures étapes...', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 40, color: AppColors.error),
            const SizedBox(height: 10),
            Text(
              'Erreur : $_error',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.error, fontSize: 13),
            ),
            const SizedBox(height: 16),
            // 2 actions visibles sur l'écran d'erreur : "Réessayer" pour relancer
            // l'appel Gemini, "Fermer" pour quitter le sheet sans avoir à swipe
            // (le swipe est parfois peu découvrable sur Android — bug signalé
            // "je ne peux pas quitter l'écran" en cas d'erreur).
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                  ),
                  child: const Text('Fermer'),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    _fetch();
                  },
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (_suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            'Pas de suggestions trouvées pour cette destination. Essaie d\'ajouter manuellement une étape.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      itemCount: _suggestions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final item = _suggestions[i];
        final alreadyAdded = _isAlreadyAdded(item.city);
        final selected = _selected.contains(i);
        final disabled = alreadyAdded;
        final tileColor = alreadyAdded
            ? AppColors.surface.withValues(alpha: 0.5)
            : selected ? AppColors.primaryLight : AppColors.surface;
        final borderColor = alreadyAdded
            ? AppColors.border
            : selected ? AppColors.primary : AppColors.border;
        return InkWell(
          onTap: disabled ? null : () => setState(() {
            if (selected) {
              _selected.remove(i);
            } else {
              _selected.add(i);
            }
          }),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tileColor,
              border: Border.all(
                color: borderColor,
                width: selected && !disabled ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Opacity(
              opacity: disabled ? 0.55 : 1,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    alreadyAdded
                        ? Icons.check_circle
                        : selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 22,
                    color: alreadyAdded
                        ? AppColors.textSecondary
                        : selected ? AppColors.primary : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.place_outlined, size: 16, color: AppColors.primary),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.city,
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                                  ),
                                  if (item.country.isNotEmpty)
                                    Text(
                                      item.country,
                                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                    ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${item.days} jour${item.days > 1 ? 's' : ''}',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary),
                              ),
                            ),
                          ],
                        ),
                        if (alreadyAdded) ...[
                          const SizedBox(height: 4),
                          Text(
                            '✓ Déjà dans tes étapes',
                            style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: AppColors.textSecondary),
                          ),
                        ],
                        if (item.description.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.description,
                            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.35),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
