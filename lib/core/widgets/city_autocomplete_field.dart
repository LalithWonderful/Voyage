import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';

/// Champ texte de saisie de ville avec autocomplete Google Places (filtré sur les
/// villes uniquement par défaut). Évite les fautes d'orthographe et la saisie
/// involontaire de régions/pays.
///
/// Pour le champ "destination principale" du voyage, passer `acceptAnyDestination: true`
/// pour aussi accepter pays/régions (ex: "Maroc", "Bali") — dans ce cas le callback
/// `onSelectedDetailed` reçoit aussi le `kind` (`city` / `country` / `region` / `place`)
/// pour que l'UI puisse exiger un découpage en étapes.
///
/// Utilisable n'importe où dans l'app (saisie destination voyage, étapes multi-villes,
/// adresse hébergement future...). L'utilisateur tape, voit un dropdown de propositions
/// après ~300ms de pause, sélectionne, le champ est rempli avec le nom canonique.
///
/// Si l'API Places échoue ou n'est pas configurée, le widget se comporte comme un
/// `TextField` normal (saisie libre). Le caller peut tout de même soumettre la valeur.
class CityAutocompleteField extends ConsumerStatefulWidget {
  /// Valeur initiale (ex: ville d'une étape qu'on édite).
  final String? initialValue;

  /// Callback appelé quand l'utilisateur sélectionne une suggestion OU quand il valide
  /// une saisie manuelle (sans avoir cliqué de suggestion). Reçoit le nom canonique.
  final void Function(String city)? onSelected;

  /// Variante riche du callback : reçoit aussi le pays (déduit de la description Google,
  /// ex: "Strasbourg, France" → country = "France"), le placeId Google, et le `kind`
  /// (`city` / `country` / `region` / `place`). `kind = 'unknown'` quand la sélection
  /// vient d'une saisie manuelle (sans suggestion cliquée). Le pays est null dans
  /// ce cas aussi.
  final void Function(String city, String? country, String? placeId, String kind)? onSelectedDetailed;

  /// Notifié à chaque keystroke (en temps réel, pas debounce). Utile pour les
  /// formulaires qui veulent valider la saisie même quand l'utilisateur n'a
  /// cliqué aucune suggestion (ex: bouton "Créer mon voyage" en onboarding).
  final void Function(String value)? onChanged;

  /// Si true, n'applique PAS le filtre `(cities)` — ramène aussi pays/régions.
  /// Par défaut (false) : autocomplete villes uniquement, comportement historique.
  final bool acceptAnyDestination;

  /// Code ISO 2 lettres du pays auquel restreindre les suggestions (ex: 'th'
  /// pour Thaïlande). Ignoré si `acceptAnyDestination=true`. Permet de proposer
  /// uniquement les villes du pays choisi en destination du voyage.
  final String? restrictToCountryCode;

  /// Texte d'aide affiché sous le champ quand vide.
  final String? hintText;

  /// Label affiché au-dessus du champ.
  final String? labelText;

  /// `autofocus: true` à l'ouverture du dialog parent.
  final bool autofocus;

  const CityAutocompleteField({
    super.key,
    this.initialValue,
    this.onSelected,
    this.onSelectedDetailed,
    this.onChanged,
    this.acceptAnyDestination = false,
    this.restrictToCountryCode,
    this.hintText,
    this.labelText,
    this.autofocus = false,
  });

  @override
  ConsumerState<CityAutocompleteField> createState() => _CityAutocompleteFieldState();
}

class _CityAutocompleteFieldState extends ConsumerState<CityAutocompleteField> {
  late final TextEditingController _ctrl;
  Timer? _debounce;
  // Suggestions en mémoire — `kind` est 'city' pour le mode classique, et
  // 'city'/'country'/'region'/'place' en mode acceptAnyDestination.
  List<({String description, String mainText, String placeId, String kind})> _suggestions = const [];
  bool _loading = false;
  // Évite de relancer une recherche après une sélection (sinon le dropdown rouvre).
  bool _justSelected = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    widget.onChanged?.call(value);
    if (_justSelected) {
      _justSelected = false;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    if (query.length < 4) {
      setState(() {
        _suggestions = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final placesService = ref.read(placesServiceProvider);
    List<({String description, String mainText, String placeId, String kind})> results = const [];
    try {
      if (widget.acceptAnyDestination) {
        results = await placesService.autocompleteDestinations(query);
      } else {
        // Mode villes seules : on uniformise vers la même struct, kind='city'.
        // `restrictToCountryCode` filtre les suggestions au pays choisi (ex:
        // étapes d'un voyage Thaïlande → uniquement villes thaï).
        final cities = await placesService.autocompleteCities(
          query,
          countryCode: widget.restrictToCountryCode,
        );
        results = cities
            .map((c) => (
                  description: c.description,
                  mainText: c.mainText,
                  placeId: c.placeId,
                  kind: 'city',
                ))
            .toList();
      }
    } catch (e) {
      // Silently ignore autocomplete errors so the widget behaves like a plain
      // TextField when the service is unavailable.
    }
    if (!mounted) return;
    setState(() {
      _suggestions = results;
      _loading = false;
    });
  }

  /// Extrait le pays depuis la description Google ("Strasbourg, France" → "France",
  /// "New York, NY, États-Unis" → "États-Unis"). Le pays est toujours le DERNIER segment.
  String? _extractCountry(String description, String mainText) {
    final rest = description.replaceFirst(mainText, '').trim();
    final cleaned = rest.startsWith(',') ? rest.substring(1).trim() : rest;
    if (cleaned.isEmpty) return null;
    final parts = cleaned.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.last;
  }

  void _select(({String description, String mainText, String placeId, String kind}) item) {
    _justSelected = true;
    _ctrl.text = item.mainText;
    _ctrl.selection = TextSelection.collapsed(offset: item.mainText.length);
    setState(() => _suggestions = const []);
    final country = _extractCountry(item.description, item.mainText);
    widget.onSelected?.call(item.mainText);
    widget.onSelectedDetailed?.call(item.mainText, country, item.placeId.isEmpty ? null : item.placeId, item.kind);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: widget.autofocus,
          textCapitalization: TextCapitalization.words,
          onChanged: _onChanged,
          onSubmitted: (v) {
            // Si l'utilisateur valide sans avoir cliqué de suggestion, on prend
            // la 1ère suggestion comme correction probable, sinon on garde sa saisie.
            if (_suggestions.isNotEmpty) {
              _select(_suggestions.first);
            } else {
              widget.onSelected?.call(v.trim());
              widget.onSelectedDetailed?.call(v.trim(), null, null, 'unknown');
            }
          },
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: widget.hintText,
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : (_ctrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _ctrl.clear();
                          setState(() => _suggestions = const []);
                          // Notifie le parent que la saisie est vidée — sinon le state
                          // parent garde l'ancienne valeur (bug : "destination Lisbonne
                          // → X → save → réouvre → Lisbonne toujours là").
                          widget.onChanged?.call('');
                          widget.onSelectedDetailed?.call('', null, null, 'unknown');
                        },
                      )
                    : null),
          ),
        ),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _suggestions.length && i < 5; i++) ...[
                  if (i > 0) Container(height: 1, color: AppColors.border),
                  InkWell(
                    onTap: () => _select(_suggestions[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          // Icône selon kind : ville/pays/région distincts pour
                          // que l'utilisateur sache ce qu'il sélectionne avant
                          // que le bandeau d'alerte s'affiche.
                          Text(
                            switch (_suggestions[i].kind) {
                              'country' => '🌍',
                              'region' => '🗺️',
                              'place' => '📍',
                              _ => '🏙️',
                            },
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _suggestions[i].mainText,
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (_suggestions[i].description.length > _suggestions[i].mainText.length)
                                  Text(
                                    _suggestions[i].description.replaceFirst(_suggestions[i].mainText, '').replaceFirst(',', '').trim(),
                                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
