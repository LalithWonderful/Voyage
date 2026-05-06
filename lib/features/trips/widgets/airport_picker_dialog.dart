import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';

/// Dialog de saisie d'aéroport avec autocomplete bidirectionnel : tape soit
/// une ville (Nice → propose NCE), soit un code IATA (NCE → match exact).
/// Si l'utilisateur saisit 3 lettres en majuscules qui ne sont pas dans la
/// table (~366 aéroports majeurs), on accepte quand même — la table couvre
/// 80% des cas mainstream mais pas les aéroports régionaux moins fréquentés.
///
/// Retourne le code IATA (3 lettres maj) sélectionné, ou null si annulé.
class AirportPickerDialog extends StatefulWidget {
  final String? initial;
  final String title;

  const AirportPickerDialog({
    super.key,
    this.initial,
    this.title = 'Aéroport de départ',
  });

  /// Helper pour ouvrir le dialog depuis n'importe où.
  static Future<String?> show(
    BuildContext context, {
    String? initial,
    String title = 'Aéroport de départ',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => AirportPickerDialog(initial: initial, title: title),
    );
  }

  @override
  State<AirportPickerDialog> createState() => _AirportPickerDialogState();
}

class _AirportPickerDialogState extends State<AirportPickerDialog> {
  late final TextEditingController _ctrl;
  List<AirportSuggestion> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial ?? '');
    _refreshSuggestions(_ctrl.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _refreshSuggestions(String q) {
    setState(() {
      _suggestions = searchAirports(q, limit: 8);
    });
  }

  bool _isValidIata(String s) =>
      s.length == 3 && RegExp(r'^[A-Z]{3}$').hasMatch(s);

  /// True quand on a quelque chose de valide à enregistrer : une suggestion
  /// matchée OU une saisie qui ressemble à un code IATA. Sert à activer/
  /// désactiver le bouton "Enregistrer".
  bool get _canSave {
    final raw = _ctrl.text.trim().toUpperCase();
    if (_isValidIata(raw)) return true;
    if (_suggestions.isNotEmpty) return true;
    return false;
  }

  void _confirm() {
    final raw = _ctrl.text.trim().toUpperCase();
    // Cas 1 : l'user a saisi 3 lettres directement → on accepte (même si
    // l'aéroport n'est pas dans la table : on couvre les régionaux non listés).
    if (_isValidIata(raw)) {
      Navigator.of(context).pop(raw);
      return;
    }
    // Cas 2 : il y a au moins une suggestion → on prend la 1ère (cohérent
    // avec l'UX d'un autocomplete classique).
    if (_suggestions.isNotEmpty) {
      Navigator.of(context).pop(_suggestions.first.iata);
      return;
    }
    // Cas 3 : rien d'exploitable → on ferme sans rien.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final query = _ctrl.text.trim();
    final showHelpNoMatch =
        _suggestions.isEmpty && query.isNotEmpty && !_isValidIata(query.toUpperCase());

    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              decoration: InputDecoration(
                labelText: 'Ville ou code IATA',
                hintText: 'Nice, Marseille, NCE...',
                helperText: 'Tape une ville ou un code de 3 lettres.',
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Effacer',
                        onPressed: () {
                          _ctrl.clear();
                          _refreshSuggestions('');
                        },
                      ),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              onChanged: _refreshSuggestions,
              onSubmitted: (_) {
                if (_canSave) _confirm();
              },
            ),
            const SizedBox(height: 8),
            if (_suggestions.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  itemBuilder: (ctx, i) {
                    final s = _suggestions[i];
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(s.iata),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                s.iata,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                  fontSize: 12,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                s.name != null && s.name!.isNotEmpty
                                    ? '${s.city} ${s.name}'
                                    : s.city,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (showHelpNoMatch)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accentLight.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Aucun aéroport trouvé pour "${_ctrl.text.trim()}". '
                        'Efface et tape directement le code IATA (3 lettres en '
                        'majuscules) si tu le connais.',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          onPressed: _canSave ? _confirm : null,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
