import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';

/// Type d'autocomplete : aéroport ou gare. Mappe directement aux types
/// supportés par Google Places Autocomplete (`types=airport` /
/// `types=train_station`).
enum TransportPlaceType { airport, trainStation }

extension TransportPlaceTypeX on TransportPlaceType {
  String get googleTypes => switch (this) {
        TransportPlaceType.airport => 'airport',
        TransportPlaceType.trainStation => 'train_station',
      };
  String get emoji => switch (this) {
        TransportPlaceType.airport => '✈️',
        TransportPlaceType.trainStation => '🚆',
      };
}

/// Champ d'autocomplete d'aéroport ou de gare. Empêche la saisie d'un nom
/// inexistant (l'user pick depuis la liste Google Places). Au pick, le
/// callback `onSelected` reçoit le nom et le placeId — la résolution
/// coords est laissée au caller (typiquement au save du formulaire, via
/// `PlaceLookupCacheService` pour profiter du cache partagé).
///
/// Implémente le pattern session token Google Places : un UUID est généré
/// au premier keystroke et est passé à toutes les requêtes autocomplete
/// jusqu'au pick. Le caller doit ré-utiliser ce token pour le Place Details
/// qui suit (récupéré via `currentSessionToken`) afin de bénéficier du
/// tarif "session" Google (1 burst + 1 details = 1 prix forfaitaire).
class TransportAutocompleteField extends ConsumerStatefulWidget {
  /// Valeur initiale (ex: nom d'un aéroport déjà choisi qu'on édite).
  final String? initialValue;

  /// Type d'autocomplete : aéroport ou gare.
  final TransportPlaceType type;

  /// Callback appelé quand l'utilisateur sélectionne une suggestion.
  /// `name` = nom canonique Google (ex: "Aéroport de Bangkok-Suvarnabhumi").
  /// `placeId` = identifiant Google stable pour résolution coords.
  /// `sessionToken` = token Places à passer au Place Details suivant.
  final void Function(String name, String placeId, String sessionToken)? onSelected;

  /// Notifié à chaque keystroke. Utile si le caller veut nettoyer son state
  /// (placeId / coords) quand l'user édite après un pick.
  final void Function(String value)? onChanged;

  final String? hintText;
  final String? labelText;
  final bool autofocus;

  const TransportAutocompleteField({
    super.key,
    required this.type,
    this.initialValue,
    this.onSelected,
    this.onChanged,
    this.hintText,
    this.labelText,
    this.autofocus = false,
  });

  @override
  ConsumerState<TransportAutocompleteField> createState() => _TransportAutocompleteFieldState();
}

class _TransportAutocompleteFieldState extends ConsumerState<TransportAutocompleteField> {
  late final TextEditingController _ctrl;
  Timer? _debounce;
  List<({String description, String mainText, String placeId})> _suggestions = const [];
  bool _loading = false;
  bool _justSelected = false;
  String? _sessionToken;

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

  /// Génère un UUID v4-like (suffisant pour Google's session token, qui n'a
  /// pas d'exigence de format strict — juste un identifiant unique côté
  /// client, opaque côté serveur).
  String _newSessionToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _onChanged(String value) {
    widget.onChanged?.call(value);
    if (_justSelected) {
      _justSelected = false;
      return;
    }
    // Premier keystroke d'un nouveau burst → génère un session token.
    _sessionToken ??= _newSessionToken();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _suggestions = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final results = await ref.read(placesServiceProvider).autocompleteTransport(
          query,
          type: widget.type.googleTypes,
          sessionToken: _sessionToken,
        );
    if (!mounted) return;
    setState(() {
      _suggestions = results;
      _loading = false;
    });
  }

  void _select(({String description, String mainText, String placeId}) item) {
    _justSelected = true;
    _ctrl.text = item.mainText;
    _ctrl.selection = TextSelection.collapsed(offset: item.mainText.length);
    setState(() => _suggestions = const []);
    final tokenForCallback = _sessionToken ?? _newSessionToken();
    widget.onSelected?.call(item.mainText, item.placeId, tokenForCallback);
    // Reset le session token : prochain burst = nouvelle session Google.
    _sessionToken = null;
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
            if (_suggestions.isNotEmpty) {
              _select(_suggestions.first);
            }
            // Pas de fallback "saisie libre validée" comme CityAutocompleteField :
            // pour un transport on EXIGE un pick (sinon on ne peut pas géocoder
            // proprement et on retombe sur du fuzzy text). Si l'user veut
            // valider sans pick, le champ gardera son texte mais le caller
            // ne recevra pas d'`onSelected` → save sans coords (fallback
            // Geocoding texte côté form).
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
                          widget.onChanged?.call('');
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
                          Text(widget.type.emoji, style: const TextStyle(fontSize: 16)),
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
