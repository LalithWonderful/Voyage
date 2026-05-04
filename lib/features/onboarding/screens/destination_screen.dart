import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/city_autocomplete_field.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

/// Écran de création de voyage (destination + dates + voyageurs). Réutilisé
/// dans 2 contextes :
///
/// - **Onboarding initial** (`isFromOnboarding: true`) : 3e étape du flow
///   post-signup (traveler-type → interests → destination). Affiche la
///   progression "Étape 3 / 3", flèche retour vers `/onboarding/interests`,
///   bouton "Passer" pour annuler le tunnel onboarding.
///
/// - **Création standalone** (`isFromOnboarding: false`, default) : user
///   déjà inscrit qui clique sur "+" depuis l'écran "Mes voyages". Pas de
///   step indicator, header "Nouveau voyage", flèche retour directe vers
///   `/trips`, bouton "Annuler" (pas "Passer" qui est trompeur).
class DestinationScreen extends ConsumerStatefulWidget {
  /// True quand on arrive depuis l'écran "Centres d'intérêt" du onboarding
  /// initial (`?from=onboarding` dans l'URL). False par défaut = création
  /// standalone depuis la liste de voyages.
  final bool isFromOnboarding;
  const DestinationScreen({super.key, this.isFromOnboarding = false});

  @override
  ConsumerState<DestinationScreen> createState() => _DestinationScreenState();
}

class _DestinationScreenState extends ConsumerState<DestinationScreen> {
  /// Saisie courante du champ destination. Mise à jour à chaque keystroke via
  /// l'autocomplete pour que `_canSave` fonctionne même si l'utilisateur ne
  /// clique aucune suggestion.
  String _typedDestination = '';
  /// Type de la destination saisie (`city`/`country`/`region`/`place`/`unknown`).
  /// Si pays/région → on affiche un bandeau d'info doux en dessous du champ.
  /// Le découpage en étapes sera proposé après création (cf. trip_edit_sheet).
  String _destinationKind = 'unknown';
  /// PlaceId Google de la suggestion sélectionnée. Sert à résoudre le code
  /// pays ISO 2 à la création pour activer d'emblée le flow régions des grands
  /// pays (sinon il fallait passer par trip_edit_sheet pour qu'il soit détecté).
  /// Reset à null si l'user édite après sélection.
  String? _selectedPlaceId;
  /// Version du widget autocomplete : incrémenté pour forcer la reconstruction
  /// quand on veut reset programmatiquement le champ (ex: clic sur "Inspire-moi"
  /// ou sur une destination pré-remplie). Le widget gère son propre controller
  /// donc le seul moyen propre de le vider est via Key.
  int _destFieldVersion = 0;
  DateTime? _startDate;
  DateTime? _endDate;
  /// Mode de période choisi par l'utilisateur :
  /// - `'exact'` : il sélectionne 2 dates précises (UI date pickers).
  /// - `'month'` : il indique un mois cible — on synthétisera des dates
  ///   (1er du mois → +6 jours) à la création pour rester compatible
  ///   avec le pipeline planning/IA, mais l'affichage utilisera le mois.
  String _periodMode = 'exact';
  /// Mois cible quand `_periodMode == 'month'`. Format YYYY-MM.
  String? _targetPeriod;
  bool _loading = false;
  int? _selectedIndex;
  final List<Traveler> _travelers = [];

  final _destinations = const [
    ('🇵🇹', 'Lisbonne, Portugal', 'Road-trip côtier · Nightlife · Esthétique', 98, [Color(0xFFF59E0B), Color(0xFFEF4444)]),
    ('🇲🇦', 'Maroc, route des Atlas', 'Road-trip · Spots populaires', 94, [Color(0xFFF97316), Color(0xFFDC2626)]),
    ('🇮🇸', 'Islande, ring road', 'Road-trip · Esthétique · Randonnée', 91, [Color(0xFF6366F1), Color(0xFF06B6D4)]),
    ('🇮🇩', 'Bali, Indonésie', 'Nightlife · Bons plans', 86, [Color(0xFF10B981), Color(0xFF14B8A6)]),
  ];

  /// Conversion du score (toujours hardcodé en V1, alimenté par la reco IA en V2)
  /// vers un libellé humain. Évite la fausse précision algorithmique d'un %
  /// alors que la donnée n'est pas encore réelle. Seuils choisis pour donner
  /// trois paliers lisibles : >=95 = très adapté, >=85 = bon match, sinon
  /// "à découvrir" reste positif (pas "peu adapté").
  String _matchLabel(int score) {
    if (score >= 95) return 'Très adapté';
    if (score >= 85) return 'Bon match';
    return 'À découvrir';
  }

  /// Reset programmatique du champ destination (vide la saisie + reset le kind).
  /// À appeler quand on bascule sur une destination pré-remplie.
  void _resetDestinationField() {
    _typedDestination = '';
    _destinationKind = 'unknown';
    _selectedPlaceId = null;
    _destFieldVersion++;
  }

  Future<void> _addTraveler() async {
    final result = await showDialog<Traveler>(
      context: context,
      builder: (_) => const _AddTravelerDialog(),
    );
    if (result != null) setState(() => _travelers.add(result));
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = isStart ? (_startDate ?? now) : (_endDate ?? (_startDate ?? now));
    final first = isStart ? now : (_startDate ?? now);

    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(first) ? first : initial,
      firstDate: first,
      lastDate: DateTime(now.year + 3),
      locale: const Locale('fr'),
    );
    if (picked == null) return;

    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = null;
      } else {
        _endDate = picked;
      }
    });
  }

  String? get _chosenDestination {
    final typed = _typedDestination.trim();
    if (typed.isNotEmpty) return typed;
    if (_selectedIndex != null) return _destinations[_selectedIndex!].$2;
    return null;
  }

  String? get _chosenEmoji {
    if (_typedDestination.trim().isNotEmpty) return '✈️';
    if (_selectedIndex != null) return _destinations[_selectedIndex!].$1;
    return '✈️';
  }

  /// True quand la destination saisie est un pays ou une région — on affiche
  /// alors un bandeau d'info doux pour préparer l'utilisateur au fait qu'on lui
  /// demandera ses villes après création (le bandeau orange du sheet d'édition
  /// prendra le relais). Pas bloquant : il peut continuer la création.
  bool get _showCountryHint =>
      _destinationKind == 'country' || _destinationKind == 'region';

  /// Création débloquée dès que la destination est renseignée. Les dates et
  /// les voyageurs sont optionnels :
  /// - mode 'exact' : si l'user a saisi 2 dates, on les utilise ; sinon on
  ///   bascule sur un mois cible synthétique (mois courant) à la création.
  /// - mode 'month' : besoin uniquement de `_targetPeriod`.
  bool get _canSave {
    if (_loading || _chosenDestination == null) return false;
    if (_periodMode == 'month') return _targetPeriod != null;
    // En mode 'exact', on autorise la création même sans dates : elles seront
    // traitées comme un mois cible (mois courant) lors du save.
    return true;
  }

  /// Libellé humain du mois cible courant ("Septembre 2026"), ou null si pas
  /// défini. Dérivé localement (mêmes règles que `Trip.targetPeriodLabel`).
  String? _formatTargetPeriod(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('-');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null || month < 1 || month > 12) return null;
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    final name = months[month - 1];
    return '${name[0].toUpperCase()}${name.substring(1)} $year';
  }

  /// Mini-picker mois (12 mois glissants à partir du mois courant) en bottom
  /// sheet. Choix volontairement simple — pour V1 on couvre 12 mois, ce qui
  /// suffit à la quasi-totalité des cas (planification > 12 mois = rare en
  /// app voyage grand public).
  Future<void> _pickTargetMonth() async {
    final now = DateTime.now();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Quel mois te tente ?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(12, (i) {
                    final m = DateTime(now.year, now.month + i, 1);
                    final raw = '${m.year}-${m.month.toString().padLeft(2, '0')}';
                    final label = _formatTargetPeriod(raw)!;
                    return OutlinedButton(
                      onPressed: () => Navigator.of(sheetCtx).pop(raw),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.border),
                      ),
                      child: Text(label, style: const TextStyle(fontSize: 12)),
                    );
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) {
      setState(() => _targetPeriod = picked);
    }
  }

  /// Résout les dates effectives à enregistrer en BDD selon le mode courant.
  /// Retourne (start, end, periodMode, targetPeriod) :
  /// - mode 'exact' avec dates renseignées → dates réelles, periodMode='exact'
  /// - mode 'exact' sans dates → bascule en 'month' avec mois courant comme
  ///   cible (l'user a cliqué "Créer" sans rien renseigner sur les dates).
  /// - mode 'month' → 1er du mois cible → +6 jours, periodMode='month'
  ({DateTime start, DateTime end, String mode, String? target}) _resolvePeriod() {
    if (_periodMode == 'exact' && _startDate != null && _endDate != null) {
      return (start: _startDate!, end: _endDate!, mode: 'exact', target: null);
    }
    final raw = _targetPeriod ?? () {
      final now = DateTime.now();
      return '${now.year}-${now.month.toString().padLeft(2, '0')}';
    }();
    final parts = raw.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final start = DateTime(year, month, 1);
    final end = start.add(const Duration(days: 6));
    return (start: start, end: end, mode: 'month', target: raw);
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;
      // Pré-remplit traveler_type + interests depuis le profil voyageur global
      // pour éviter qu'un voyage neuf ait des chips vides → 0 suggestions.
      // L'utilisateur peut surcharger ces valeurs ensuite via la sheet d'édition.
      // planning_mode n'est volontairement pas pré-rempli : la question est
      // posée au 1er "Suggérer" pour que l'utilisateur choisisse contextuellement.
      final profile = await ref.read(userProfileProvider.future);
      final globalInterests = await ref.read(userInterestsProvider.future);
      final globalTravelerType = profile?['traveler_type'] as String?;
      // Résout le code pays ISO 2 si l'user a sélectionné une suggestion
      // Places. Permet d'activer le flow régions des grands pays dès la 1ère
      // ouverture du voyage, sans passer par trip_edit_sheet.
      String? countryCode;
      if (_selectedPlaceId != null && _selectedPlaceId!.isNotEmpty) {
        try {
          countryCode = await ref.read(placesServiceProvider).getCountryCodeFromPlaceId(_selectedPlaceId!);
        } catch (_) {}
      }
      // Logging défensif pour diagnostiquer le bug "Chine → gb" signalé par
      // Lalith : si l'user retrouve un voyage avec un mauvais country_code,
      // ces logs permettent de comprendre quel placeId Google a été
      // sélectionné (souvent une erreur user qui a cliqué sur "Chichester"
      // au lieu de "Chine" dans la liste autocomplete).
      // Résout les dates et le mode de période. Quand l'user n'a renseigné
      // ni dates ni mois cible, on tombe sur "mois courant" en mode 'month' :
      // ça donne au pipeline IA/planning une fenêtre exploratoire utilisable
      // sans demander davantage à l'utilisateur.
      final period = _resolvePeriod();
      debugPrint(
        '[destination-create] destination="$_chosenDestination" kind=$_destinationKind '
        'placeId=$_selectedPlaceId country=$countryCode '
        'periodMode=${period.mode} target=${period.target}',
      );
      final inserted = await client.from('trips').insert({
        'user_id': userId,
        'title': _chosenDestination!,
        'destination': _chosenDestination!,
        'start_date': period.start.toIso8601String().split('T').first,
        'end_date': period.end.toIso8601String().split('T').first,
        'period_mode': period.mode,
        if (period.target != null) 'target_period': period.target,
        'cover_emoji': _chosenEmoji,
        'status': 'upcoming',
        'travelers': _travelers.map((t) => t.toJson()).toList(),
        'traveler_type': ?globalTravelerType,
        if (globalInterests.isNotEmpty) 'interests': globalInterests,
        'destination_country_code': ?countryCode,
        'destination_country_name': countryCode != null ? _chosenDestination : null,
        'destination_kind': _destinationKind == 'unknown' ? null : _destinationKind,
      }).select();

      if ((inserted as List).isEmpty) {
        throw Exception('Voyage non créé (vérifie les policies RLS INSERT sur trips).');
      }

      await client.from('user_profiles').update({
        'onboarding_completed_at': DateTime.now().toIso8601String(),
      }).eq('id', userId);

      ref.invalidate(tripsProvider);
      ref.invalidate(hasTripsProvider);
      ref.invalidate(userProfileProvider);
      if (mounted) context.go('/trips');
    } catch (e) {
      if (mounted) {
        // Wording humanisé : un user qui voit
        // "Erreur : ClientException with SocketException: Failed host lookup..."
        // ne comprend rien. On classifie selon le type d'erreur pour
        // afficher quelque chose d'actionnable.
        final raw = e.toString();
        final isNetwork = raw.contains('SocketException') ||
            raw.contains('Failed host lookup') ||
            raw.contains('TimeoutException') ||
            raw.contains('ClientException') ||
            raw.contains('Connection reset') ||
            raw.contains('Connection refused') ||
            raw.contains('Network is unreachable') ||
            raw.contains('No address associated');
        final msg = isNetwork
            ? 'Pas de connexion internet. Vérifie ta connexion et réessaie.'
            : 'Quelque chose a coincé lors de la création. Réessaie dans un instant.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _inspireMe() {
    final random = Random();
    final i = random.nextInt(_destinations.length);
    setState(() {
      _selectedIndex = i;
      _resetDestinationField();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✨ On te propose : ${_destinations[i].$2}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Où veux-tu voyager ?',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    Text('Indique une destination. Tu peux préciser les dates et les voyageurs plus tard.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    const SizedBox(height: 14),
                    Text('Destination *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    // Autocomplete élargi : accepte villes, pays, régions, lieux.
                    // Le `kind` détecté nourrit le bandeau d'info pays/région
                    // ci-dessous. La Key change quand on reset programmatiquement
                    // le champ (clic sur une card pré-remplie ou "Inspire-moi"),
                    // ce qui force la reconstruction du widget pour vider sa
                    // saisie interne.
                    CityAutocompleteField(
                      key: ValueKey('onboarding-dest-$_destFieldVersion'),
                      initialValue: _typedDestination,
                      acceptAnyDestination: true,
                      hintText: 'Ville, pays ou région… Ex. Nice, Maroc, Bali',
                      onChanged: (v) {
                        // Suit la saisie en temps réel pour que `_canSave`
                        // fonctionne sans clic de suggestion. Reset le `kind`
                        // et le placeId si l'utilisateur édite après une sélection.
                        setState(() {
                          _typedDestination = v;
                          if (v.trim().isEmpty) {
                            _destinationKind = 'unknown';
                            _selectedPlaceId = null;
                          } else if (_destinationKind != 'unknown') {
                            // L'utilisateur a tapé après avoir sélectionné →
                            // on annule le kind capturé pour ne pas afficher
                            // un bandeau périmé. Idem placeId : il ne pointe
                            // plus la saisie courante.
                            _destinationKind = 'unknown';
                            _selectedPlaceId = null;
                          }
                          if (v.trim().isNotEmpty && _selectedIndex != null) {
                            _selectedIndex = null;
                          }
                        });
                      },
                      onSelectedDetailed: (city, _, placeId, kind) {
                        setState(() {
                          _typedDestination = city;
                          _destinationKind = kind;
                          _selectedPlaceId = placeId;
                          _selectedIndex = null;
                        });
                      },
                    ),
                    if (_showCountryHint) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.1),
                          border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('💡', style: TextStyle(fontSize: 14)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _destinationKind == 'country'
                                    ? 'Tu pars dans tout un pays — on te demandera tes premières villes après création.'
                                    : 'Tu pars dans une région — on te demandera tes premières villes après création.',
                                style: TextStyle(fontSize: 11, color: AppColors.textPrimary, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),

                    // Inspire-moi remonté juste sous la destination : c'est une
                    // alternative au remplissage du champ, pas une feature de fin
                    // d'écran. La proximité visuelle clarifie la logique
                    // "saisis OU laisse-toi guider".
                    Row(
                      children: [
                        Text('Tu ne sais pas où partir ?', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _loading ? null : _inspireMe,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('✨ Inspire-moi', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Text('QUAND VEUX-TU PARTIR ? — OPTIONNEL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    // Toggle 2 modes — "exact" : 2 date pickers ; "month" :
                    // un mini-picker mois (12 mois glissants). En mode 'month'
                    // les dates sont synthétisées à la création (1er du mois →
                    // +6 jours), invisibles à l'user mais exploitables par les
                    // pipelines downstream (planning, IA, wallet).
                    Row(
                      children: [
                        Expanded(child: _ModeToggle(
                          label: 'Dates exactes',
                          selected: _periodMode == 'exact',
                          onTap: () => setState(() => _periodMode = 'exact'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: _ModeToggle(
                          label: 'Plutôt en…',
                          selected: _periodMode == 'month',
                          onTap: () => setState(() => _periodMode = 'month'),
                        )),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_periodMode == 'exact') ...[
                      Row(
                        children: [
                          Expanded(child: _DateField(
                            label: 'Départ',
                            value: _startDate != null ? _formatDate(_startDate!) : null,
                            onTap: () => _pickDate(isStart: true),
                          )),
                          const SizedBox(width: 10),
                          Expanded(child: _DateField(
                            label: 'Retour',
                            value: _endDate != null ? _formatDate(_endDate!) : null,
                            onTap: () => _pickDate(isStart: false),
                          )),
                        ],
                      ),
                      if (_startDate != null && _endDate != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${_endDate!.difference(_startDate!).inDays + 1} jours',
                            style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600),
                          ),
                        ),
                    ] else ...[
                      GestureDetector(
                        onTap: _pickTargetMonth,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            border: Border.all(
                              color: _targetPeriod != null ? AppColors.primary : AppColors.border,
                              width: _targetPeriod != null ? 1.5 : 1,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.calendar_month_outlined, size: 18, color: AppColors.textSecondary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _formatTargetPeriod(_targetPeriod) ?? 'Choisir un mois',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: _targetPeriod != null ? AppColors.textPrimary : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('VOYAGEURS — OPTIONNEL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        if (_travelers.isNotEmpty)
                          Text('${_travelers.length} ${_travelers.length > 1 ? 'personnes' : 'personne'}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Si la liste est vide, on montre le défaut implicite "1 adulte"
                    // sans créer de Traveler stocké. Le voyage se créera avec une
                    // liste de voyageurs vide — interprétée comme "1 adulte par
                    // défaut" partout dans l'app. Le user peut modifier via le
                    // bouton ci-dessous.
                    if (_travelers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('1 adulte par défaut', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                      )
                    else
                      ..._travelers.asMap().entries.map((e) => _TravelerTile(
                        traveler: e.value,
                        onRemove: () => setState(() => _travelers.removeAt(e.key)),
                      )),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: _addTraveler,
                      icon: const Icon(Icons.person_add_alt_1, size: 18),
                      label: const Text('Modifier les voyageurs'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 44),
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 20),

                    Text('IDÉES ADAPTÉES À TON PROFIL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 10),
                    ...List.generate(_destinations.length, (i) {
                      final d = _destinations[i];
                      return _DestCard(
                        flag: d.$1, name: d.$2, meta: d.$3,
                        matchLabel: _matchLabel(d.$4),
                        colors: d.$5,
                        selected: _selectedIndex == i,
                        onTap: () => setState(() {
                          _selectedIndex = i;
                          _resetDestinationField();
                        }),
                      );
                    }),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _canSave ? _save : null,
                      child: _loading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Créer mon voyage →'),
                    ),
                    if (!_canSave && !_loading)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _chosenDestination == null
                              ? 'Choisis une destination pour continuer'
                              : 'Sélectionne les dates de départ et de retour',
                          style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Header haut d'écran. Adapté selon le contexte d'arrivée :
  ///
  /// - **Onboarding** (`isFromOnboarding: true`) : barre de progression 3
  ///   étapes + label "Étape 3 / 3" + bouton "Passer" (annule le tunnel
  ///   onboarding entier). Flèche retour ← vers l'étape précédente.
  /// - **Standalone** (default) : pas de progression, juste flèche retour
  ///   directe vers `/trips` + bouton "Annuler" (wording clair vs "Passer"
  ///   qui suggère "skip cette étape" alors qu'il abandonne tout).
  Widget _buildHeader() {
    if (widget.isFromOnboarding) {
      const step = 2; // 3e étape sur 3 (0-indexed)
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: List.generate(3, (i) => Expanded(
              child: Container(
                height: 3,
                margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                decoration: BoxDecoration(
                  color: i < step ? AppColors.success : (i == step ? AppColors.primary : AppColors.border),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ))),
            const SizedBox(height: 8),
            Row(children: [
              GestureDetector(onTap: () => context.go('/onboarding/interests'), child: const Text('←', style: TextStyle(fontSize: 20))),
              const SizedBox(width: 10),
              Text('Étape ${step + 1} / 3', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const Spacer(),
              TextButton(
                onPressed: () => context.go('/trips'),
                child: Text('Passer', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ),
            ]),
          ],
        ),
      );
    }
    // Mode standalone (création depuis "+" sur la liste de voyages).
    // Pas de titre dans la barre — le titre principal "Où veux-tu aller ?"
    // sous le header est suffisant pour le contexte. Sinon "Nouveau voyage"
    // collé à la flèche fait breadcrumb / indication de tab, confus.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.go('/trips'),
            child: const Text('←', style: TextStyle(fontSize: 20)),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => context.go('/trips'),
            child: Text('Annuler', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Bouton de bascule entre les 2 modes de période (Dates exactes / Plutôt en…).
/// Style segment-control compact, l'état actif a fond primary léger + bord
/// primary 1.5px.
class _ModeToggle extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeToggle({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;

  const _DateField({required this.label, this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: value != null ? AppColors.primary : AppColors.border, width: value != null ? 1.5 : 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.3)),
            const SizedBox(height: 4),
            Text(
              value ?? 'JJ/MM/AAAA',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: value != null ? AppColors.textPrimary : AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DestCard extends StatelessWidget {
  final String flag, name, meta, matchLabel;
  final List<Color> colors;
  final bool selected;
  final VoidCallback onTap;

  const _DestCard({required this.flag, required this.name, required this.meta, required this.matchLabel, required this.colors, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 50, height: 50,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), gradient: LinearGradient(colors: colors)),
                  child: Center(child: Text(flag, style: const TextStyle(fontSize: 24))),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(meta, style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                )),
                // Badge humain remplace le score % (cf. _matchLabel) :
                // évite la fausse précision algorithmique d'un % alors que la
                // donnée est hardcodée. Trois paliers lisibles pour un signal
                // ressenti, pas calculé.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.success, borderRadius: BorderRadius.circular(10)),
                  child: Text(matchLabel, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // CTA explicite "Choisir / Choisie" : la card reste tappable mais
            // le bouton matérialise l'action attendue. Devient "Choisie ✓"
            // quand sélectionnée pour éviter de retaper et perdre la sélection.
            SizedBox(
              height: 32,
              child: OutlinedButton(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(
                  foregroundColor: selected ? AppColors.primary : AppColors.textPrimary,
                  side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(selected ? 'Choisie ✓' : 'Choisir', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TravelerTile extends StatelessWidget {
  final Traveler traveler;
  final VoidCallback onRemove;

  const _TravelerTile({required this.traveler, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryLight),
            child: Center(
              child: Text(
                traveler.name.isNotEmpty ? traveler.name[0].toUpperCase() : '?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.primary),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${traveler.name} · ${traveler.age} ans',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: Icon(Icons.close, size: 18, color: AppColors.textSecondary),
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

class _AddTravelerDialog extends StatefulWidget {
  const _AddTravelerDialog();

  @override
  State<_AddTravelerDialog> createState() => _AddTravelerDialogState();
}

class _AddTravelerDialogState extends State<_AddTravelerDialog> {
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final age = int.tryParse(_ageCtrl.text.trim());
    if (name.isEmpty) {
      setState(() => _error = 'Le prénom est requis.');
      return;
    }
    if (age == null || age < 0 || age > 120) {
      setState(() => _error = 'Âge invalide.');
      return;
    }
    Navigator.of(context).pop(Traveler(name: name, age: age));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ajouter un voyageur'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Prénom'),
            textCapitalization: TextCapitalization.words,
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ageCtrl,
            decoration: InputDecoration(labelText: 'Âge', suffixText: 'ans', errorText: _error),
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        ElevatedButton(onPressed: _submit, child: const Text('Ajouter')),
      ],
    );
  }
}
