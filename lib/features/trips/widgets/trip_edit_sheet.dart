import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/city_autocomplete_field.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/planning/services/document_consistency.dart';
import 'package:voyage/features/planning/services/pinned_dates.dart';
import 'package:voyage/features/regions/services/country_regions_repository.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/services/itinerary_mutation.dart';
import 'package:voyage/features/trips/widgets/airport_picker_dialog.dart';
import 'package:voyage/features/trips/widgets/improve_itinerary_sheet.dart';
import 'package:voyage/features/trips/widgets/regional_loop_sheet.dart';
import 'package:voyage/features/trips/widgets/trip_step_card.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';

const _coverEmojis = ['✈️', '🏝️', '🏔️', '🏙️', '🏞️', '🌴', '🛶', '🚐', '🎡', '🎿', '🗺️', '🌍'];

/// 2 rangées séparées dans la card "Style de voyage" pour ne pas surcharger
/// visuellement avec 10 chips d'affilée. Ordre validé Lalith 2026-04-25
/// (cf. project_traveler_types_places_mapping en mémoire).
const _travelerTypesRow1 = [
  ('💰', 'Meilleur prix'),
  ('👨‍👩‍👧', 'En famille'),
  ('🚗', 'Road-trip'),
  ('🎒', 'Backpack'),
  ('❤️', 'Couple'),
  ('🧘', 'Chill'),
];

const _travelerTypesRow2 = [
  ('🎉', 'Fun'),
  ('💼', 'Voyage pro'),
  ('✨', 'Grand luxe'),
  ('👴', 'Senior'),
];


const _availableInterests = [
  ('🥾', 'Randonnée'), ('🛍️', 'Shopping'), ('🌙', 'Nightlife'),
  ('📸', 'Spots populaires'), ('🗺️', 'Hors circuit'), ('💡', 'Bons plans'),
  ('🧘', 'Wellness'), ('🎨', 'Esthétique'), ('🍽️', 'Gastronomie'),
  ('🏛️', 'Culture'), ('🏖️', 'Plage'), ('⛷️', 'Sports'),
  ('🐾', 'Nature'), ('🎭', 'Événements'),
];

Future<void> openTripEditSheet(BuildContext context, WidgetRef ref, {required Trip trip}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _TripEditSheet(trip: trip),
  );
}

class _TripEditSheet extends ConsumerStatefulWidget {
  final Trip trip;
  const _TripEditSheet({required this.trip});

  @override
  ConsumerState<_TripEditSheet> createState() => _TripEditSheetState();
}

class _TripEditSheetState extends ConsumerState<_TripEditSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _destCtrl;
  late DateTime _start;
  late DateTime _end;
  late String _emoji;
  late List<Traveler> _travelers;
  String? _travelerType;
  late Set<String> _interests;
  late List<TripSegment> _segments;
  /// Mode de planification choisi pour ce voyage (null = pas encore choisi,
  /// la question sera posée au 1er "Suggérer"). Modifiable ici à tout moment.
  PlanningMode? _planningMode;
  bool _saving = false;
  /// La card "ÉTAPES DU VOYAGE" est en mode CTA collapsed quand le voyage est
  /// mono-ville (segments vide), pour ne pas overwhelm le voyageur. Devient
  /// visible automatiquement dès qu'une étape est ajoutée OU quand l'utilisateur
  /// clique sur le CTA pour révéler les boutons Ajouter/Suggérer.
  bool _segmentsCardExpanded = false;
  /// Type de destination détecté via l'autocomplete Places ('city' / 'country'
  /// / 'region' / 'place' / 'unknown'). Sert à imposer le découpage en étapes
  /// quand la destination n'est pas une ville (Niveau 2). 'unknown' au boot
  /// pour les voyages existants : on ne re-déclenche pas la contrainte tant
  /// que l'utilisateur ne re-sélectionne pas la destination.
  String _destinationKind = 'unknown';
  /// Code ISO 2 lettres du pays de la destination (ex: 'th' pour Thaïlande).
  /// Récupéré via Place Details au boot et au changement. Passé au dialog
  /// d'ajout d'étape pour filtrer les villes proposées au pays du voyage.
  String? _destinationCountryCode;
  /// Clé du card "ÉTAPES DU VOYAGE" pour auto-scroll quand le bandeau apparaît.
  final GlobalKey _segmentsCardKey = GlobalKey();
  /// Budget par personne (en euros). Null = pas renseigné. Non bloquant
  /// pour la sauvegarde — Lunao s'en passe si absent.
  int? _budgetPerPersonEur;
  /// True (default) : le budget couvre vol + séjour. False : vol séparé.
  bool _budgetIncludesFlight = true;
  /// Controller du champ budget (pour pouvoir reset programmatiquement).
  final TextEditingController _budgetCtrl = TextEditingController();
  /// Override aéroport de départ pour CE voyage (code IATA 3 lettres).
  /// Null = on utilise celui du profil (fallback côté Lunao). Non bloquant.
  String? _homeAirportIata;
  /// Override mode arrival (best/flight/train/car/bus). Null = profil.
  String? _arrivalTransportMode;
  /// Override mode local (best/public_transport/walk/taxi/...). Null = profil.
  String? _localTransportMode;

  /// État d'expansion de chaque section accordéon. Default : Info + Étapes
  /// ouverts ; Préférences + Transport fermés. Reset à chaque ouverture
  /// de la sheet (pas de persistance — V1 simple).
  final Map<String, bool> _sectionExpanded = {
    'info': true,
    'segments': true,
    'preferences': false,
    'transport': false,
  };

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.trip.title);
    _destCtrl = TextEditingController(text: widget.trip.destination);
    _start = widget.trip.startDate;
    _end = widget.trip.endDate;
    _emoji = widget.trip.coverEmoji;
    _travelers = [...widget.trip.travelers];
    _travelerType = widget.trip.travelerType;
    _interests = Set<String>.from(widget.trip.interests ?? const []);
    _segments = [...widget.trip.itinerarySegments];
    _enforceSingleSegmentRule();
    _planningMode = widget.trip.planningMode;
    _budgetPerPersonEur = widget.trip.budgetPerPersonEur?.toInt();
    _budgetIncludesFlight = widget.trip.budgetIncludesFlight ?? true;
    _budgetCtrl.text = _budgetPerPersonEur?.toString() ?? '';
    _homeAirportIata = widget.trip.homeAirportIata;
    _arrivalTransportMode = widget.trip.arrivalTransportMode;
    _localTransportMode = widget.trip.localTransportMode;
    // Re-détecte le kind de la destination au boot pour les voyages existants
    // créés avant Niveau 2 (où kind='unknown' n'a jamais été stocké). 1 appel
    // autocomplete par ouverture du sheet, acceptable. Si le réseau échoue,
    // kind reste 'unknown' et le bandeau ne s'affiche pas.
    _detectInitialKind();
  }

  Future<void> _detectInitialKind() async {
    final dest = widget.trip.destination.trim();
    if (dest.isEmpty) return;
    final places = ref.read(placesServiceProvider);
    final results = await places.autocompleteDestinations(dest);
    if (!mounted || results.isEmpty) return;
    // Prend la 1ère suggestion dont le mainText correspond à la destination
    // (évite de prendre une homonymie au cas où la destination est ambiguë).
    final exact = results.where((r) => r.mainText.toLowerCase() == dest.toLowerCase());
    final pick = exact.isNotEmpty ? exact.first : results.first;
    setState(() {
      _destinationKind = pick.kind;
      // Auto-seed la 1ère étape si destination=ville claire ET aucune étape :
      // évite la card collapsed "Voyage multi-villes ?" pour un voyage qui a
      // pourtant une ville bien définie. L'utilisateur peut toujours supprimer
      // l'étape s'il ne veut pas l'avoir. On ne le fait PAS pour kind=country
      // /region (le bandeau orange + ses CTAs prennent le relais) ni pour
      // kind=place (adresse précise type "Tour Eiffel" — pas une ville).
      if (pick.kind == 'city' && _segments.isEmpty) {
        _autoSeedFirstSegmentFromDestination();
        _enforceSingleSegmentRule();
        _segmentsCardExpanded = true;
      }
    });
    // Récupère le code ISO du pays pour filtrer les étapes par la suite.
    // Marche pour kind=country/region (remonte au pays parent) ET kind=city
    // (le pays de la ville est utile aussi pour proposer d'autres villes du
    // même pays comme étapes additionnelles).
    if (pick.placeId.isNotEmpty) {
      final code = await places.getCountryCodeFromPlaceId(pick.placeId);
      if (mounted && code != null) {
        setState(() => _destinationCountryCode = code);
        // Persiste les champs `destination_*` sur le trip pour que le flow
        // régions des grands pays se déclenche aussi depuis trip_detail
        // (sans avoir à re-passer par la sheet d'édition + Place Details).
        unawaited(ref.read(countryRegionsRepositoryProvider).persistDestinationCountry(
          tripId: widget.trip.id,
          countryCode: code,
          countryName: pick.mainText,
          kind: pick.kind,
        ));
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _destCtrl.dispose();
    _budgetCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _start : _end;
    final first = isStart ? DateTime(initial.year - 2) : _start;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(initial.year + 3),
      locale: const Locale('fr'),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
        if (_end.isBefore(picked)) _end = picked;
      } else {
        _end = picked;
      }
      _enforceSingleSegmentRule();
    });
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final dest = _destCtrl.text.trim();
    if (title.isEmpty || dest.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Titre et destination sont requis.')),
      );
      return;
    }
    if (_totalSegmentDays > _tripDays) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Tes étapes totalisent $_totalSegmentDays jours mais le voyage ne dure que $_tripDays jours. '
            'Réduis ou supprime des étapes pour pouvoir enregistrer.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    if (_needsSegments && _segments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _destinationKind == 'country'
                ? 'Tu as choisi un pays comme destination. Ajoute au moins une étape pour préciser les villes.'
                : 'Tu as choisi une région. Ajoute au moins une étape pour préciser les villes.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(supabaseProvider).from('trips').update({
        'title': title,
        'destination': dest,
        'start_date': _start.toIso8601String().split('T').first,
        'end_date': _end.toIso8601String().split('T').first,
        // Toute édition explicite dans cette sheet matérialise un choix de
        // dates précises. Force `period_mode='exact'` et nettoie
        // `target_period` pour garder la BDD cohérente — sinon un voyage créé
        // en mode "mois cible" garderait ce mode malgré des dates custom.
        'period_mode': 'exact',
        'target_period': null,
        'cover_emoji': _emoji,
        'travelers': _travelers.map((t) => t.toJson()).toList(),
        'traveler_type': _travelerType,
        'interests': _interests.toList(),
        'itinerary_segments': _segments.isEmpty ? null : _segments.map((s) => s.toJson()).toList(),
        'planning_mode': _planningMode?.dbValue,
        // Budget : non bloquant. null = utilisateur ne souhaite pas en
        // renseigner. Le toggle "vol inclus" n'a de sens qu'avec un budget.
        'budget_per_person_eur': _budgetPerPersonEur,
        'budget_includes_flight': _budgetPerPersonEur != null ? _budgetIncludesFlight : null,
        // Override aéroport ce voyage. Null = utiliser celui du profil.
        'home_airport_iata': _homeAirportIata,
        // Préférences transport. Null = utiliser celles du profil.
        'arrival_transport_mode': _arrivalTransportMode,
        'local_transport_mode': _localTransportMode,
      }).eq('id', widget.trip.id);
      ref.invalidate(tripsProvider);
      ref.invalidate(tripByIdProvider(widget.trip.id));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Bornes (start, end) calculées d'un segment selon son index dans la liste.
  /// `end` est en convention "départ exclusif" : c'est le jour où le voyageur
  /// repart de cette étape (= début de l'étape suivante).
  /// Cohérent avec le résumé du dialog d'ajout d'étape qui dit "Ko Samui sera
  /// ajouté du jeu. 2 juillet au sam. 4 juillet" pour 2 jours sur place. Le
  /// voyageur pense en termes "j'arrive le X et je repars le Y" (convention
  /// hôtelière).
  ({DateTime start, DateTime end}) _segmentDates(int index) {
    var offsetBefore = 0;
    for (var i = 0; i < index; i++) {
      offsetBefore += _segments[i].days;
    }
    final seg = _segments[index];
    final start = _start.add(Duration(days: offsetBefore));
    final end = start.add(Duration(days: seg.days));
    return (start: start, end: end);
  }

  /// Total des jours déjà placés dans les étapes — pour comparer avec la durée du voyage.
  int get _totalSegmentDays => _segments.fold(0, (s, seg) => s + seg.days);

  // ─── Résumés affichés quand les sections accordéon sont fermées ──────

  /// "Thaïlande · 21/06 → 06/08" (ou "Thaïlande · Mai 2026" si dates synthétiques).
  String _summaryInfo() {
    final dest = _destCtrl.text.trim().isEmpty
        ? 'Destination à choisir'
        : _destCtrl.text.trim();
    final dates = '${_fmtDate(_start)} → ${_fmtDate(_end)}';
    return '$dest · $dates';
  }

  /// "5 étapes · Bangkok · Phú Quốc · Hanoï +2" (ou "Aucune étape" si vide).
  String _summarySegments() {
    if (_segments.isEmpty) return 'Aucune étape pour l\'instant';
    final cities = _segments.map((s) => s.city).toList();
    final shown = cities.take(3).join(' · ');
    final extra = cities.length - 3;
    final count = '${_segments.length} étape${_segments.length > 1 ? 's' : ''}';
    return extra > 0 ? '$count · $shown +$extra' : '$count · $shown';
  }

  /// "Grand luxe · Culture · Gastronomie · Bons plans +8 · 600 €/pers. · Pilote auto"
  /// (ou "Configuration globale du profil" si rien défini sur ce voyage).
  String _summaryPreferences() {
    final parts = <String>[];
    if (_travelerType != null && _travelerType!.isNotEmpty) {
      parts.add(_travelerType!);
    }
    if (_interests.isNotEmpty) {
      final list = _interests.toList();
      final shown = list.take(3).join(' · ');
      final extra = list.length - 3;
      parts.add(extra > 0 ? '$shown +$extra' : shown);
    }
    if (_budgetPerPersonEur != null) {
      parts.add('$_budgetPerPersonEur €/pers.');
    }
    if (_planningMode != null) {
      parts.add(_planningMode!.dbValue == 'auto'
          ? 'Pilote auto'
          : 'Co-pilote');
    }
    if (parts.isEmpty) return 'Configuration globale du profil';
    return parts.join(' · ');
  }

  /// Résumé fermé pour la section "Déplacements & transport".
  /// Format : "Avion · Départ Luxembourg · Transports en commun"
  /// Affiche le NOM DE VILLE de l'aéroport (pas le code IATA brut), via
  /// lookupAirport. Fallback "Préférences globales du profil" si aucun
  /// override voyage.
  String _summaryTransport() {
    const arrivalLabels = {
      'flight': 'Avion',
      'train': 'Train',
      'car': 'Voiture',
      'bus': 'Bus',
      'best': 'Meilleur compromis',
    };
    const localLabels = {
      'public_transport': 'Transports en commun',
      'walk': 'Marche',
      'taxi': 'Taxi/VTC',
      'car': 'Voiture',
      'scooter': 'Scooter',
      'comfort': 'Confort',
      'budget': 'Économique',
    };

    final parts = <String>[];
    if (_arrivalTransportMode != null) {
      parts.add(arrivalLabels[_arrivalTransportMode!] ??
          _arrivalTransportMode!);
    }
    if (_homeAirportIata != null && _homeAirportIata!.isNotEmpty) {
      final lookup = lookupAirport(_homeAirportIata!);
      // Préfère "Départ Luxembourg" plutôt que le code IATA brut "LUX".
      final cityLabel = lookup?.city ?? _homeAirportIata!;
      parts.add('Départ $cityLabel');
    }
    if (_localTransportMode != null) {
      parts.add(localLabels[_localTransportMode!] ?? _localTransportMode!);
    }
    if (parts.isEmpty) return 'Préférences globales du profil';
    return parts.join(' · ');
  }

  /// Construit le texte de bilan affiché sous la liste des étapes. Logique :
  /// - couvre exactement → message "✓ X jours placés"
  /// - dépasse → warning "⚠ ..."
  /// - manque ≤ 2 jours ET le voyage a des étapes auto-déduites des vols
  ///   (≥ 2 segments) → message neutre "X jours en transit (vols aller/retour)"
  ///   pour ne pas culpabiliser l'utilisateur sur un écart naturel.
  /// - manque davantage → message classique "X / Y jours placés · N restant".
  String _bilanText() {
    final placed = _totalSegmentDays;
    final total = _tripDays;
    if (placed == total) {
      return '✓ $placed jour${placed > 1 ? 's' : ''} placé${placed > 1 ? 's' : ''} · couvre tout le voyage';
    }
    if (placed > total) {
      return '⚠ $placed jours placés dépasse les $total jours du voyage';
    }
    final missing = total - placed;
    final isTransitGap = missing <= 2 && _segments.length >= 2;
    if (isTransitGap) {
      return '$placed / $total jours placés · $missing jour${missing > 1 ? 's' : ''} en transit (vols aller/retour)';
    }
    final dest = _destCtrl.text.trim().isEmpty
        ? 'destination'
        : _destCtrl.text.trim();
    return '$placed / $total jours placés · $missing restant${missing > 1 ? 's' : ''} (utilisera "$dest")';
  }

  /// Quand le voyage a exactement une étape, sa durée est forcée à couvrir tout
  /// le voyage. Sémantique : "1 ville unique = elle dure tout le voyage", sinon
  /// on tomberait sur l'incohérence "13/21 jours placés (utilisera destination)".
  /// À appeler après chaque mutation de `_segments` ou changement de dates.
  void _enforceSingleSegmentRule() {
    if (_segments.length == 1 && _segments[0].days != _tripDays) {
      _segments[0] = _segments[0].copyWith(days: _tripDays);
    }
  }

  /// Extrait la 1ère partie avant la 1ère virgule d'une string. Utilisé pour
  /// récupérer juste la ville quand la destination contient un suffixe pays
  /// ("Lisbonne, Portugal" → "Lisbonne"). Si pas de virgule, retourne la string
  /// telle quelle.
  String _firstWordBeforeComma(String s) {
    final t = s.trim();
    final c = t.indexOf(',');
    return c > 0 ? t.substring(0, c).trim() : t;
  }

  /// Auto-crée une 1ère étape = destination quand l'utilisateur déplie le CTA
  /// "Voyage multi-villes ?". Évite le cas confus "destination=Nancy,
  /// étapes=[Épinal]" où Nancy disparaît du circuit. Skip si pays/région (le
  /// bandeau orange et ses CTAs prennent le relais), si déjà des étapes, ou si
  /// destination vide.
  ///
  /// Si la destination contient une virgule ("Lisbonne, Portugal" via card
  /// pré-remplie), on extrait la 1ère partie comme ville et la dernière comme
  /// pays — sinon le segment afficherait "Lisbonne, Portugal" comme nom de
  /// ville, ce qui est moche et casse la cohérence avec d'autres étapes.
  void _autoSeedFirstSegmentFromDestination() {
    if (_segments.isNotEmpty) return;
    final dest = _destCtrl.text.trim();
    if (dest.isEmpty) return;
    if (_destinationKind == 'country' || _destinationKind == 'region') return;
    final firstComma = dest.indexOf(',');
    final city = firstComma > 0 ? dest.substring(0, firstComma).trim() : dest;
    final countryFromText = firstComma > 0 ? dest.substring(firstComma + 1).trim() : '';
    _segments.add(TripSegment(
      city: city,
      days: _tripDays,
      country: countryFromText.isEmpty ? null : countryFromText,
    ));
  }

  /// True quand la destination détectée est un pays ou une région : impose
  /// un découpage en étapes pour préciser où chercher les activités.
  bool get _needsSegments =>
      _destinationKind == 'country' || _destinationKind == 'region';

  /// Durée totale du voyage en jours calendaires (J1 inclus → Jfin inclus).
  /// On vise une couverture pleine : somme des jours des étapes = `_tripDays`.
  /// Sémantique "jours" : "Nancy 9 jours" couvre tout un voyage de 9 jours, pas
  /// besoin d'enlever 1 pour le retour.
  int get _tripDays => _end.difference(_start).inDays + 1;

  /// Vrai si le voyage a un itinéraire détaillé (typiquement issu des vols)
  /// ET qu'au moins une ville a des suggestions dans le catalogue
  /// `sub_trip_suggestions.dart`. Sert au routing du bouton "Suggérer" :
  /// flow itinerary-aware vs flow régions classique.
  bool get _isItineraryAware {
    final cities = _segments.map((s) => s.city).toList();
    return isImproveItineraryEligible(cities);
  }

  /// Ouvre soit la sheet "Améliorer ton itinéraire" (Lot 1, lecture seule)
  /// si le voyage a déjà des étapes flight-derived couvertes par le
  /// catalogue, soit la sheet "Suggérer une boucle régionale" classique
  /// (Gemini + sélecteur de région) sinon.
  ///
  /// Sheet régionale : Gemini propose 3-5 villes autour de la destination
  /// principale. Les étapes sélectionnées sont AJOUTÉES (pas remplacées).
  Future<void> _openRegionalLoop() async {
    // ─── Routing itinerary-aware (Lot 2.2, 2026-05-08) ────────────────
    // Si le voyage a déjà ≥2 étapes ET qu'on a des suggestions catalogue,
    // on ouvre la sheet "Améliorer ton itinéraire". La sheet retourne
    // une `ItineraryMutation?` ; si non-null, on applique via
    // `applyMutation` et on persiste via le mécanisme habituel
    // (setState + sauvegarde au "Enregistrer" du parent sheet).
    if (_isItineraryAware) {
      // Lot 2.3 : la sheet retourne une LISTE de mutations (multi-select).
      // On valide le batch puis on applique.
      final mutations = await openImproveItinerarySheet(
        context,
        tripId: widget.trip.id,
        currentSegments: _segments.toList(growable: false),
        tripStartDate: _start,
        tripDurationDays: _end.difference(_start).inDays + 1,
      );
      if (mutations == null || mutations.isEmpty || !mounted) return;

      final tripDuration = _end.difference(_start).inDays + 1;
      final validation = validateMutationBatch(
        mutations: mutations,
        currentSegments: _segments,
        tripDurationDays: tripDuration,
      );
      if (validation is BatchFailed) {
        // Garde-fou : la sheet désactive déjà les sélections conflit
        // mais on protège contre toute incohérence (race condition,
        // double-tap, etc.). Snackbar humaine.
        final msg = switch (validation.reason) {
          BatchFailureReason.conflictingStructuralOnSameAnchor =>
              'Une seule modification possible pour ${validation.anchorCity}.',
          BatchFailureReason.appendOnRemovedAnchor =>
              'Conflit sur ${validation.anchorCity} : impossible d\'ajouter '
                  'une excursion à une étape qui sera remplacée.',
          BatchFailureReason.notEnoughFreeDaysForAllAppends =>
              'Pas assez de jours libres dans le voyage pour toutes ces '
                  'excursions.',
          // V2.2 garde-fou : ce chemin ne devrait pas arriver tant que V2.3
          // (date picker UI) n'est pas livré — la sheet n'expose pas encore
          // de suggestion `requiresInsertionDate`. Message neutre.
          BatchFailureReason.missingInsertionDate =>
              'Cette modification nécessite une date d\'insertion. '
                  'Réessaie depuis la card.',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
        );
        return;
      }

      setState(() {
        final newSegments = applyMutationBatch(_segments, mutations);
        _segments
          ..clear()
          ..addAll(newSegments);
        _enforceSingleSegmentRule();
      });
      final n = mutations.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            n == 1
                ? 'Étapes mises à jour (1 modification).'
                : 'Étapes mises à jour ($n modifications).',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    // ─── Flow classique (régions / boucle Gemini) ─────────────────────
    final dest = _destCtrl.text.trim();
    if (dest.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saisis d\'abord une destination principale.')),
      );
      return;
    }
    final durationDays = _end.difference(_start).inDays + 1;
    if (durationDays < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Voyage trop court pour une boucle régionale.')),
      );
      return;
    }
    final result = await openRegionalLoopSheet(
      context, ref,
      mainDestination: dest,
      durationDays: durationDays,
      travelerType: _travelerType,
      interests: _interests.toList(),
      existingCities: _segments.map((s) => s.city).toList(),
      existingDaysPlaced: _totalSegmentDays,
      destinationKind: _destinationKind,
      tripId: widget.trip.id,
      // Code pays détecté à la volée par _detectInitialKind via
      // getCountryCodeFromPlaceId. Active le flow régions si le pays est
      // dans largeCountries / travelRegionCountries.
      countryCode: _destinationCountryCode,
    );
    if (result == null || result.isEmpty || !mounted) return;
    setState(() {
      _segments.addAll(result);
      _enforceSingleSegmentRule();
    });
  }

  /// Distance Haversine en km entre 2 points GPS. Approximation Terre sphérique
  /// suffisante pour comparer des distances inter-villes (<5% d'erreur).
  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLng = (lng2 - lng1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  /// Optimise l'ordre des étapes pour minimiser les zigzags (problème du voyageur
  /// de commerce — heuristique nearest-neighbor, suffisant à <10 étapes).
  ///
  /// Étapes :
  /// 1. Géocode chaque étape (lat/lng) si pas déjà mis en cache dans le segment
  /// 2. Géocode la destination principale comme point d'ancrage
  /// 3. Nearest-neighbor depuis l'ancre : à chaque tour, on sélectionne l'étape
  ///    non visitée la plus proche du point courant
  /// 4. Affiche un dialog de prévisualisation avec ancien vs nouvel ordre
  /// 5. Si l'utilisateur confirme → applique le nouvel ordre + persiste les coords
  Future<void> _optimizeOrder() async {
    if (_segments.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Il faut au moins 3 étapes pour optimiser l\'ordre.')),
      );
      return;
    }
    final dest = _destCtrl.text.trim();
    if (dest.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saisis d\'abord la destination principale.')),
      );
      return;
    }
    // Loader bloquant pendant le géocodage (max ~2s pour 5 villes)
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final places = ref.read(placesServiceProvider);
    final geocoded = <TripSegment>[];
    for (final seg in _segments) {
      if (seg.latitude != null && seg.longitude != null) {
        geocoded.add(seg);
        developer.log('Optimize: ${seg.city} (caché) → ${seg.latitude},${seg.longitude}', name: 'optimize');
        continue;
      }
      final coords = await places.findCityCoords(seg.city, country: seg.country);
      if (coords == null) {
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Impossible de géolocaliser "${seg.city}". Vérifie l\'orthographe ou ajoute le pays.'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }
      developer.log('Optimize: ${seg.city}${seg.country != null ? " (${seg.country})" : ""} → ${coords.lat},${coords.lng} (${coords.formattedAddress})', name: 'optimize');
      geocoded.add(seg.copyWith(latitude: coords.lat, longitude: coords.lng));
    }
    final anchor = await places.findCityCoords(dest);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (anchor == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossible de géolocaliser la destination "$dest".'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    developer.log('Optimize: ANCRE $dest → ${anchor.lat},${anchor.lng} (${anchor.formattedAddress})', name: 'optimize');

    // Algo : pour ≤8 étapes on calcule l'ordre EXACTEMENT optimal par énumération
    // (8! = 40 320 permutations, < 100 ms en Dart). Au-delà → fallback nearest-neighbor.
    // L'énumération évite les pièges classiques de NN (ex: anchor entre 2 clusters,
    // NN choisit le plus proche puis fait un grand zigzag pour atteindre le 2nd).
    final ordered = geocoded.length <= 8
        ? _bruteForceTsp(geocoded, anchor.lat, anchor.lng)
        : _nearestNeighbor(geocoded, anchor.lat, anchor.lng);

    // Log de la distance totale du nouveau parcours pour debug
    var totalKm = 0.0;
    var prevLat = anchor.lat, prevLng = anchor.lng;
    for (final s in ordered) {
      final d = _haversineKm(prevLat, prevLng, s.latitude!, s.longitude!);
      totalKm += d;
      developer.log('Optimize: ${s.city} à ${d.toStringAsFixed(0)} km du précédent', name: 'optimize');
      prevLat = s.latitude!; prevLng = s.longitude!;
    }
    developer.log('Optimize: total parcours = ${totalKm.toStringAsFixed(0)} km', name: 'optimize');

    final unchanged = _orderSignature(_segments) == _orderSignature(ordered);
    if (unchanged) {
      // On persiste quand même les coords (cache) pour les prochains optimize.
      setState(() => _segments
        ..clear()
        ..addAll(ordered));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ L\'ordre actuel est déjà optimal.')),
      );
      return;
    }
    // Aperçu avant/après pour validation utilisateur
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _OrderPreviewDialog(
        oldOrder: _segments,
        newOrder: ordered,
        anchorName: dest,
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _segments
        ..clear()
        ..addAll(ordered));
    }
  }

  /// Brute-force TSP : énumère toutes les permutations possibles, garde celle
  /// dont la distance totale (anchor → s1 → s2 → ... → sN) est minimale. Exact
  /// pour les petites tailles (≤8 villes = 40k permutations, OK en Dart natif).
  List<TripSegment> _bruteForceTsp(List<TripSegment> segs, double anchorLat, double anchorLng) {
    if (segs.length <= 1) return [...segs];
    var bestPerm = <TripSegment>[...segs];
    var bestDist = _pathDistance(bestPerm, anchorLat, anchorLng);
    final indices = List<int>.generate(segs.length, (i) => i);
    void permute(int k) {
      if (k == indices.length) {
        final perm = indices.map((i) => segs[i]).toList();
        final d = _pathDistance(perm, anchorLat, anchorLng);
        if (d < bestDist) {
          bestDist = d;
          bestPerm = perm;
        }
        return;
      }
      for (var i = k; i < indices.length; i++) {
        final tmp = indices[k]; indices[k] = indices[i]; indices[i] = tmp;
        permute(k + 1);
        final tmp2 = indices[k]; indices[k] = indices[i]; indices[i] = tmp2;
      }
    }
    permute(0);
    return bestPerm;
  }

  /// Nearest-neighbor heuristique pour les listes >8. Pas optimal mais raisonnable.
  List<TripSegment> _nearestNeighbor(List<TripSegment> segs, double anchorLat, double anchorLng) {
    final remaining = [...segs];
    final ordered = <TripSegment>[];
    var curLat = anchorLat, curLng = anchorLng;
    while (remaining.isNotEmpty) {
      var bestIdx = 0;
      var bestDist = double.infinity;
      for (var i = 0; i < remaining.length; i++) {
        final s = remaining[i];
        final d = _haversineKm(curLat, curLng, s.latitude!, s.longitude!);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      final pick = remaining.removeAt(bestIdx);
      ordered.add(pick);
      curLat = pick.latitude!;
      curLng = pick.longitude!;
    }
    return ordered;
  }

  /// Distance totale d'un parcours anchor → s1 → s2 → ... → sN.
  double _pathDistance(List<TripSegment> path, double anchorLat, double anchorLng) {
    var d = 0.0;
    var prevLat = anchorLat, prevLng = anchorLng;
    for (final s in path) {
      d += _haversineKm(prevLat, prevLng, s.latitude!, s.longitude!);
      prevLat = s.latitude!; prevLng = s.longitude!;
    }
    return d;
  }

  /// Signature stable d'une liste d'étapes pour comparer 2 ordres.
  String _orderSignature(List<TripSegment> list) =>
      list.map((s) => s.city.toLowerCase()).join('|');

  /// Ouvre un dialog d'édition pour une étape (ajout ou modif).
  /// L'ordre des étapes est défini par leur position dans la liste — pas de tri auto
  /// (l'utilisateur peut réordonner via drag-and-drop).
  Future<void> _openSegmentEditor({TripSegment? existing, int? index}) async {
    // Si on édite l'unique étape OU si on ajoute la 1ère étape (liste vide),
    // alors après save la liste comptera 1 étape → la règle "1 étape =
    // tripDays" s'appliquera. On le signale au dialog pour cacher le sélecteur
    // de jours et afficher un message clair, plutôt que de laisser l'utilisateur
    // saisir un nombre qui sera silencieusement écrasé.
    final willBeOnlySegment =
        (existing != null && _segments.length == 1) ||
        (existing == null && _segments.isEmpty);
    // V2 (Lalith 2026-05-10) — recherche mondiale par défaut, peu
    // importe que le voyage soit mono-pays ou multi-pays. Le spec
    // produit (Lalith 2026-05-09 §2) dit que l'utilisateur doit pouvoir
    // ajouter une étape hors-pays même sur un voyage mono-pays. La
    // priorisation des villes du pays principal pourra être un futur
    // raffinement (= biais d'autocomplete sans filtre dur).
    final result = await showDialog<_SegmentEditResult?>(
      context: context,
      builder: (ctx) => _SegmentEditorDialog(
        existing: existing,
        restrictToCountryCode: null,
        lockedToTripDays: willBeOnlySegment,
        tripDays: _tripDays,
        tripStartDate: widget.trip.startDate,
        existingSegments: _segments,
      ),
    );
    if (result == null) return;
    setState(() {
      if (index != null) {
        _segments[index] = result.segment;
      } else if (result.insertAtDay == null) {
        // Append simple à la fin (cas par défaut, 80% des usages).
        _segments.add(result.segment);
      } else {
        // Insertion au milieu d'un séjour : split de l'étape coupée en
        // morceaux "avant" + nouveau + "après" (même ville pour le retour).
        // Cas typique : voyage Bangkok 44j, l'user ajoute Ko Samet 2j à
        // partir du jour 6 → Bangkok 5j / Ko Samet 2j / Bangkok 37j.
        _insertSegmentAtDay(result.segment, result.insertAtDay!);
      }
      _enforceSingleSegmentRule();
    });
  }

  /// Insère un segment à une position chronologique précise (1-based) en
  /// splittant l'étape qui couvre ce jour. Préserve la durée totale du
  /// voyage : la ville coupée garde l'équivalent de ses jours, juste répartis
  /// en avant + retour.
  ///
  /// Cas couverts :
  /// - `day` tombe au début d'une étape → pas de "avant", on insère + on
  ///   réduit l'étape coupée du nombre de jours du nouveau.
  /// - `day` tombe au milieu d'une étape → split en 3 (avant + nouveau + après).
  /// - `day` tombe au-delà de toutes les étapes existantes → append simple.
  /// - Si le nouveau segment dépasse la durée disponible dans l'étape coupée,
  ///   on tronque le "après" à 0 (= étape coupée disparaît, le nouveau prend
  ///   sa place complète). Le warning UX existant ("X jours placés dépasse Y")
  ///   alerte si la somme totale dépasse `tripDays`.
  void _insertSegmentAtDay(TripSegment newSegment, int day) {
    var cumulative = 0;
    for (var i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      final segStart = cumulative + 1;
      final segEnd = cumulative + s.days;
      if (day >= segStart && day <= segEnd) {
        final daysBeforeInSeg = day - segStart;
        final remainingAfter = s.days - daysBeforeInSeg - newSegment.days;
        if (daysBeforeInSeg == 0) {
          // Pas de morceau "avant" : on insère le nouveau, et l'étape
          // existante perd ses 1ers jours.
          if (remainingAfter > 0) {
            _segments[i] = s.copyWith(days: remainingAfter);
            _segments.insert(i, newSegment);
          } else {
            _segments[i] = newSegment;
          }
        } else {
          // Split en 2 ou 3 morceaux.
          _segments[i] = s.copyWith(days: daysBeforeInSeg);
          _segments.insert(i + 1, newSegment);
          if (remainingAfter > 0) {
            _segments.insert(i + 2, s.copyWith(days: remainingAfter));
          }
        }
        return;
      }
      cumulative += s.days;
    }
    // Aucun segment ne couvre ce jour → append à la fin.
    _segments.add(newSegment);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Modifier le voyage', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: AppColors.textSecondary,
                    tooltip: 'Fermer',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ─── Section 1 : Informations générales (ouverte par défaut) ─
                    _TripEditSection(
                      title: 'Informations générales',
                      summary: _summaryInfo(),
                      expanded: _sectionExpanded['info']!,
                      onToggle: () => setState(() =>
                          _sectionExpanded['info'] = !_sectionExpanded['info']!),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('EMOJI', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _coverEmojis.map((e) {
                              final sel = _emoji == e;
                              return GestureDetector(
                                onTap: () => setState(() => _emoji = e),
                                child: Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: sel
                                        ? AppColors.primaryLight
                                        : AppColors.surface,
                                    border: Border.all(
                                      color: sel
                                          ? AppColors.primary
                                          : AppColors.border,
                                      width: sel ? 2 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Center(
                                    child: Text(e,
                                        style: const TextStyle(fontSize: 22)),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 16),
                          Text('TITRE *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                          const SizedBox(height: 6),
                          TextField(controller: _titleCtrl),
                          const SizedBox(height: 14),
                          Text('DESTINATION *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                          const SizedBox(height: 6),
                          // Autocomplete élargi : accepte aussi pays/région pour
                          // imposer ensuite le découpage en étapes (cf. _destinationKind).
                          CityAutocompleteField(
                      key: ValueKey('dest-${widget.trip.id}'),
                      initialValue: _destCtrl.text,
                      acceptAnyDestination: true,
                      hintText: 'Ville, pays ou région (ex: Nancy, Maroc, Bali)',
                      onSelectedDetailed: (dest, _, placeId, kind) {
                        setState(() {
                          // Auto-sync de la 1ère étape avec la nouvelle destination
                          // si elle correspondait à l'ancienne (cas auto-créée).
                          // Ex: destination Lisbonne + étape Lisbonne → modifier
                          // destination en Bangkok devrait mettre à jour l'étape,
                          // pas la conserver à Lisbonne.
                          final oldCity = _firstWordBeforeComma(_destCtrl.text);
                          final newCity = _firstWordBeforeComma(dest);
                          final firstSegMatchesOld = _segments.isNotEmpty &&
                              _segments[0].city.toLowerCase() == oldCity.toLowerCase();
                          if (firstSegMatchesOld) {
                            if (kind == 'country' || kind == 'region') {
                              // Nouvelle dest = pays/région → l'ancienne ville n'a
                              // plus de sens comme étape (l'IA proposera des villes
                              // via le bandeau orange + CTAs). On la supprime.
                              _segments.removeAt(0);
                            } else {
                              // Nouvelle dest = ville/place/unknown → on remplace
                              // la 1ère étape par la nouvelle ville (préserve days
                              // et country qui seront re-normalisés).
                              _segments[0] = _segments[0].copyWith(city: newCity, country: null);
                            }
                            _enforceSingleSegmentRule();
                          }
                          _destCtrl.text = dest;
                          _destinationKind = kind;
                          // On reset le code pays — il sera rafraîchi par le
                          // fetch async ci-dessous. Évite de garder un code
                          // périmé entre 2 sélections.
                          _destinationCountryCode = null;
                          // Si pays/région sans étapes, déplie automatiquement
                          // la card étapes pour que les CTAs soient visibles
                          // immédiatement.
                          if (_needsSegments && _segments.isEmpty) {
                            _segmentsCardExpanded = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              final ctx = _segmentsCardKey.currentContext;
                              if (ctx != null) {
                                Scrollable.ensureVisible(
                                  ctx,
                                  duration: const Duration(milliseconds: 350),
                                  alignment: 0.1,
                                );
                              }
                            });
                          }
                        });
                        // Fetch async du code pays ISO pour filtrer les étapes.
                        if (placeId != null && placeId.isNotEmpty) {
                          ref.read(placesServiceProvider).getCountryCodeFromPlaceId(placeId).then((code) {
                            if (!mounted || code == null) return;
                            setState(() => _destinationCountryCode = code);
                          });
                        }
                      },
                    ),
                          const SizedBox(height: 14),
                          // Dates départ / retour incluses dans Informations générales
                          Row(
                            children: [
                              Expanded(child: _dateField(label: 'Départ', value: _fmtDate(_start), onTap: () => _pickDate(isStart: true))),
                              const SizedBox(width: 10),
                              Expanded(child: _dateField(label: 'Retour', value: _fmtDate(_end), onTap: () => _pickDate(isStart: false))),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // ─── Phase C — Bannière "Points à vérifier" ───────────
                    // Affichée uniquement quand `detectDocumentConflicts`
                    // retourne ≥1 conflit (sinon SizedBox.shrink). Placée
                    // au-dessus des étapes pour visibilité immédiate.
                    _buildConflictsBanner(),

                    // ─── Section 2 : Étapes du voyage (ouverte par défaut) ────
                    // Le bandeau ⚠️ pays/région vit À L'INTÉRIEUR de la card étapes,
                    // pour ne pas dupliquer l'alerte (cf. _buildSegmentsCard).
                    _TripEditSection(
                      title: 'Étapes du voyage',
                      summary: _summarySegments(),
                      expanded: _sectionExpanded['segments']!,
                      onToggle: () => setState(() => _sectionExpanded['segments'] =
                          !_sectionExpanded['segments']!),
                      child: _buildSegmentsCard(),
                    ),

                    // ─── Section 3 : Préférences du voyage (fermée par défaut) ─
                    _TripEditSection(
                      title: 'Préférences du voyage',
                      summary: _summaryPreferences(),
                      expanded: _sectionExpanded['preferences']!,
                      onToggle: () => setState(() => _sectionExpanded['preferences'] =
                          !_sectionExpanded['preferences']!),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStyleCard(),
                          _buildInterestsCard(),
                          _buildBudgetCard(),
                          // Mode de planification glissé ici (validé par Lalith) —
                          // c'est une préférence d'usage Lunao, pas du transport.
                          _buildPlanningModeCard(),
                        ],
                      ),
                    ),

                    // ─── Section 4 : Déplacements & transport (fermée par défaut) ─
                    _TripEditSection(
                      title: 'Déplacements & transport',
                      summary: _summaryTransport(),
                      expanded: _sectionExpanded['transport']!,
                      onToggle: () => setState(() => _sectionExpanded['transport'] =
                          !_sectionExpanded['transport']!),
                      child: _buildTransportCard(),
                    ),

                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
              child: SafeArea(
                top: false,
                child: ElevatedButton(
                  // Désactive si pays/région sans étapes — feedback visuel pour
                  // que l'utilisateur sache qu'il manque quelque chose. Le
                  // snackbar dans _save() gère le cas où il forcerait quand même.
                  onPressed: _saving || (_needsSegments && _segments.isEmpty) ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text(_needsSegments && _segments.isEmpty
                          ? 'Ajoute une étape pour enregistrer'
                          : 'Enregistrer'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateField({required String label, required String value, required VoidCallback onTap}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Conteneur uniforme pour chaque section configurable du voyage. Header avec
  /// titre (small caps) + slot trailing optionnel (compteur, action), hint en
  /// italique sous le titre, puis le contenu.
  Widget _formCard({
    required String title,
    Widget? trailing,
    String? hint,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.5)),
              ),
              ?trailing,
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint, style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic, height: 1.35)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  /// Card "Mode de planification" — toggle Auto vs Co-pilote pour ce voyage.
  /// Le mode pilote le comportement de "Suggérer" : auto = mass suggestion tout
  /// coché, coPilot = 3 options/créneau décochées. Si null (jamais choisi),
  /// la question est posée au 1er Suggérer.
  Widget _buildPlanningModeCard() {
    return _formCard(
      title: 'MODE DE PLANIFICATION',
      hint: _planningMode == null
          ? 'Pas encore choisi — la question sera posée au prochain "Suggérer".'
          : _planningMode == PlanningMode.auto
              ? 'On te propose un planning complet, tu ajustes après.'
              : 'Tu participes à la planification : 3 options par créneau, tu choisis.',
      child: Row(
        children: [
          Expanded(
            child: _planningModeOption(
              emoji: '✨',
              title: 'Pilote auto',
              isSelected: _planningMode == PlanningMode.auto,
              accent: AppColors.primary,
              onTap: () => setState(() => _planningMode = PlanningMode.auto),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _planningModeOption(
              emoji: '🎯',
              title: 'Co-pilote',
              isSelected: _planningMode == PlanningMode.coPilot,
              accent: AppColors.accent,
              onTap: () => setState(() => _planningMode = PlanningMode.coPilot),
            ),
          ),
        ],
      ),
    );
  }

  Widget _planningModeOption({
    required String emoji,
    required String title,
    required bool isSelected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? accent.withValues(alpha: 0.12) : AppColors.background,
          border: Border.all(
            color: isSelected ? accent : AppColors.border,
            width: isSelected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isSelected ? accent : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Card "Style de ce voyage" — chips de type voyageur en 2 rangées (cf.
  /// project_traveler_types_places_mapping en mémoire). 6 chips "primaires"
  /// en row 1 (les plus communs) + 4 chips "secondaires" en row 2.
  Widget _buildStyleCard() {
    return _formCard(
      title: 'STYLE DE CE VOYAGE',
      trailing: _travelerType != null
          ? TextButton(
              onPressed: () => setState(() => _travelerType = null),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text('Réinitialiser', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600)),
            )
          : null,
      hint: _travelerType == null
          ? 'Optionnel — vide = on utilise ton profil voyageur global.'
          : 'Préférences spécifiques à ce voyage, appliquées à tes suggestions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _travelerTypesRow1.map(_travelerChip).toList(),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _travelerTypesRow2.map(_travelerChip).toList(),
          ),
        ],
      ),
    );
  }

  /// Construit une chip de type voyageur (helper partagé entre les 2 rows).
  Widget _travelerChip((String, String) t) {
    final sel = _travelerType == t.$2;
    return GestureDetector(
      onTap: () => setState(() => _travelerType = sel ? null : t.$2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppColors.primary : AppColors.primaryLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '${t.$1} ${t.$2}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: sel ? Colors.white : AppColors.primary,
          ),
        ),
      ),
    );
  }

  /// Card "Centres d'intérêt" — multi-select de tags.
  Widget _buildInterestsCard() {
    return _formCard(
      title: 'CENTRES D\'INTÉRÊT',
      trailing: _interests.isNotEmpty
          ? TextButton(
              onPressed: () => setState(() => _interests.clear()),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text('Réinitialiser', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600)),
            )
          : null,
      hint: _interests.isEmpty
          ? 'Optionnel — vide = on utilise les intérêts de ton profil global.'
          : '${_interests.length} sélectionné${_interests.length > 1 ? 's' : ''} pour ce voyage.',
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: _availableInterests.map((t) {
          final sel = _interests.contains(t.$2);
          return GestureDetector(
            onTap: () => setState(() => sel ? _interests.remove(t.$2) : _interests.add(t.$2)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: sel ? AppColors.primary : AppColors.primaryLight,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${t.$1} ${t.$2}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : AppColors.primary)),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Récupère l'aéroport effectif pour CE voyage : override du voyage si
  /// défini, sinon celui du profil, sinon CDG par défaut.
  String _effectiveHomeAirport() {
    if (_homeAirportIata != null && _homeAirportIata!.isNotEmpty) {
      return _homeAirportIata!;
    }
    final profile = ref.watch(userProfileProvider).valueOrNull;
    return (profile?['home_airport_iata'] as String?) ?? 'CDG';
  }

  /// Ouvre le picker d'aéroport (autocomplete ville+IATA).
  /// Retourne le code IATA sélectionné, ou null si annulé.
  Future<String?> _pickAirportIata({required String initial}) {
    return AirportPickerDialog.show(
      context,
      initial: initial,
      title: 'Aéroport pour ce voyage',
    );
  }

  /// Card "Budget par personne" — optionnelle, non bloquante. Si renseignée,
  /// Lunao s'en sert pour ses estimations dans l'écran Assistant + le hint
  /// de faisabilité du destination_screen à la création.
  Widget _buildBudgetCard() {
    return _formCard(
      title: 'BUDGET PAR PERSONNE',
      trailing: _budgetPerPersonEur != null
          ? TextButton(
              onPressed: () {
                setState(() {
                  _budgetPerPersonEur = null;
                  _budgetCtrl.clear();
                });
              },
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Réinitialiser',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600)),
            )
          : null,
      hint: _budgetPerPersonEur == null
          ? "Optionnel — Lunao s'en servira pour personnaliser ses conseils budget."
          : "Estimation indicative, hors dépenses personnelles.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _budgetCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: 'Ex. 600',
              suffixText: '€ / pers.',
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: (v) {
              setState(() {
                final parsed = int.tryParse(v.trim());
                _budgetPerPersonEur = (parsed != null && parsed > 0) ? parsed : null;
              });
            },
          ),
          if (_budgetPerPersonEur != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Checkbox(
                  value: _budgetIncludesFlight,
                  onChanged: (v) =>
                      setState(() => _budgetIncludesFlight = v ?? true),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Vol aller-retour inclus dans ce budget',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Ligne "Aéroport de départ" dans la card budget. Distingue clairement le
  /// fallback profil (NULL côté DB) de l'override par voyage. Affiche la
  /// ville (et nom propre quand dispo) à côté du code IATA pour que
  /// l'utilisateur reconnaisse l'aéroport sans connaître les codes par cœur.
  Widget _buildHomeAirportRow() {
    final isOverride = _homeAirportIata != null && _homeAirportIata!.isNotEmpty;
    final code = _effectiveHomeAirport();
    final lookup = lookupAirport(code);
    final airportLabel = lookup == null
        ? null
        : (lookup.name != null && lookup.name!.isNotEmpty
            ? '${lookup.city} ${lookup.name}'
            : lookup.city);
    final originLabel = isOverride
        ? 'Spécifique à ce voyage'
        : 'Depuis ton profil';
    final subtitle = airportLabel != null
        ? '$airportLabel · $originLabel'
        : originLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('✈️ Aéroport de départ',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const Spacer(),
            Text(code,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: () async {
                final picked = await _pickAirportIata(initial: code);
                if (picked == null) return;
                if (picked.length != 3 ||
                    !RegExp(r'^[A-Z]{3}$').hasMatch(picked)) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Code IATA invalide (3 lettres maj).')),
                    );
                  }
                  return;
                }
                setState(() => _homeAirportIata = picked);
              },
              icon: const Icon(Icons.edit, size: 14),
              label: Text(
                isOverride ? 'Modifier' : 'Modifier pour ce voyage',
                style: const TextStyle(fontSize: 12),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: AppColors.primary,
              ),
            ),
            if (isOverride) ...[
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => setState(() => _homeAirportIata = null),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppColors.textSecondary,
                ),
                child: const Text("Utiliser l'aéroport du profil",
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Card "Préférences transport" — 2 niveaux distincts :
  /// 1. "Aller à la destination" (best/flight/train/car/bus) — pour le grand
  ///    trajet domicile → destination
  /// 2. "Sur place" (best/public_transport/walk/taxi/car/scooter/comfort/budget)
  ///    — pour les déplacements de proximité
  /// Important : la préférence locale ne s'applique pas aux longues distances
  /// inter-étapes (Bangkok → Krabi reste un vol même si l'utilisateur préfère
  /// les transports en commun à Bangkok).
  Widget _buildTransportCard() {
    final hasOverride =
        _arrivalTransportMode != null || _localTransportMode != null;
    return _formCard(
      title: 'PRÉFÉRENCES TRANSPORT',
      trailing: hasOverride
          ? TextButton(
              onPressed: () => setState(() {
                _arrivalTransportMode = null;
                _localTransportMode = null;
              }),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Réinitialiser',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600)),
            )
          : null,
      hint: hasOverride
          ? "Lunao s'en servira pour proposer les trajets les plus adaptés."
          : "Optionnel — Lunao utilisera tes préférences globales du profil.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Rejoindre la destination',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: const [
              ('🤖', 'Meilleur compromis', null),
              ('✈️', 'Avion', 'flight'),
              ('🚆', 'Train', 'train'),
              ('🚗', 'Voiture', 'car'),
              ('🚌', 'Bus', 'bus'),
            ].map(_arrivalChip).toList(),
          ),
          if (_arrivalTransportMode == null) ...[
            const SizedBox(height: 6),
            Text(
              'Lunao comparera temps, budget et confort.',
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic),
            ),
          ],
          // Aéroport : pertinent uniquement si l'utilisateur ne s'est pas
          // verrouillé sur train/voiture/bus.
          if (_arrivalShowsAirport()) ...[
            const SizedBox(height: 12),
            _buildHomeAirportRow(),
          ],
          const SizedBox(height: 14),
          Text('Déplacements sur place',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: const [
              ('🤖', 'Meilleur compromis', null),
              ('🚇', 'Transports en commun', 'public_transport'),
              ('🚶', 'Marche', 'walk'),
              ('🚕', 'Taxi / VTC', 'taxi'),
              ('🚗', 'Voiture', 'car'),
              ('💎', 'Le plus confortable', 'comfort'),
              ('💰', 'Le moins cher', 'budget'),
            ].map(_localChip).toList(),
          ),
          if (_localTransportMode == null) ...[
            const SizedBox(height: 6),
            Text(
              'Lunao choisira selon le contexte.',
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic),
            ),
          ] else if (_localTransportMode == 'public_transport') ...[
            const SizedBox(height: 6),
            Text(
              'Lunao les privilégiera quand c\'est pratique. Pour les '
              'longs trajets entre étapes, il pourra proposer un autre mode.',
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic,
                  height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  /// L'aéroport est affiché dans la card transport seulement quand le mode
  /// "Rejoindre" peut impliquer l'avion (best ou flight). Pour train/voiture/
  /// bus, on cache pour ne pas pousser une info non pertinente.
  bool _arrivalShowsAirport() {
    final mode = _arrivalTransportMode;
    return mode == null || mode == 'best' || mode == 'flight';
  }

  Widget _arrivalChip((String, String, String?) opt) {
    final sel = _arrivalTransportMode == opt.$3;
    return GestureDetector(
      onTap: () => setState(() => _arrivalTransportMode = opt.$3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppColors.primary : AppColors.primaryLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '${opt.$1} ${opt.$2}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: sel ? Colors.white : AppColors.primary,
          ),
        ),
      ),
    );
  }

  Widget _localChip((String, String, String?) opt) {
    final sel = _localTransportMode == opt.$3;
    return GestureDetector(
      onTap: () => setState(() => _localTransportMode = opt.$3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppColors.primary : AppColors.primaryLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '${opt.$1} ${opt.$2}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: sel ? Colors.white : AppColors.primary,
          ),
        ),
      ),
    );
  }

  // Card "Voyageurs" retirée 2026-04-26 (Lalith) : pas exploitée par l'IA hors
  // travelerType (qui couvre 90% de l'usage). À réintroduire si on intègre
  // réservations hôtel/location/activités. Le champ reste persisté en DB
  // (_travelers est encore initialisé depuis widget.trip.travelers et écrit
  // par _save), ne pas faire de migration.

  /// Phase C (Lalith 2026-05-09) — bannière "Points à vérifier" qui
  /// affiche les conflits inter-documents détectés par
  /// `detectDocumentConflicts` (Phase B service `document_consistency`).
  /// Visible uniquement quand au moins un conflit existe. Pas de
  /// correction automatique — l'utilisateur édite le doc concerné.
  Widget _buildConflictsBanner() {
    final docsAsync = ref.watch(tripDocumentsProvider(widget.trip.id));
    final docs = docsAsync.maybeWhen(
      data: (d) => d,
      orElse: () => const <TripDocument>[],
    );
    final conflicts = detectDocumentConflicts(
      docs: docs,
      segments: _segments.toList(growable: false),
      tripStartDate: _start,
    );
    if (conflicts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: _ConflictsBanner(
        conflicts: conflicts,
        onTap: (c) => _handleConflictTap(c, docs),
      ),
    );
  }

  /// V2 (Lalith 2026-05-09) — tap sur une ligne de conflit dans la
  /// bannière "Points à vérifier". Résout le ou les documents source
  /// du conflit et ouvre la sheet d'édition (1 doc) ou un picker
  /// (≥2 docs).
  ///
  /// Stratégie selon le type :
  /// - `overlappingTransports` : 2 docs dans `docIds` → picker.
  /// - `hotelDuringAbsence` : 1 doc dans `docIds` → ouvre direct.
  /// - `segmentArrivalMismatch` : pas de `docIds`, mais `segmentIndex`
  ///   → résoud les docs liés au segment via `findDocsLinkedToSegment`
  ///   et dispatch (1 → direct, ≥2 → picker).
  Future<void> _handleConflictTap(
    DocumentConflict conflict,
    List<TripDocument> docs,
  ) async {
    // Résoud la liste des docs à proposer.
    var targets = <TripDocument>[];
    if (conflict.docIds.isNotEmpty) {
      // Match par ID.
      final byId = {for (final d in docs) d.id: d};
      for (final id in conflict.docIds) {
        final doc = byId[id];
        if (doc != null) targets.add(doc);
      }
    } else if (conflict.segmentIndex != null &&
        conflict.segmentIndex! >= 0 &&
        conflict.segmentIndex! < _segments.length) {
      // segmentArrivalMismatch — on remonte les docs liés au segment.
      final analysis = analyzePinnedDates(
        segments: _segments.toList(growable: false),
        tripStartDate: _start,
        docs: docs,
      );
      if (conflict.segmentIndex! < analysis.segments.length) {
        targets = findDocsLinkedToSegment(
          segment: analysis.segments[conflict.segmentIndex!],
          docs: docs,
        );
      }
    }
    if (targets.isEmpty) return;
    if (targets.length == 1) {
      await openDocumentFormSheet(
        context,
        ref,
        existing: targets.first,
      );
      return;
    }
    if (!mounted) return;
    await _showConflictDocsPickerSheet(targets, conflict);
  }

  /// Mini bottom sheet pour choisir entre 2+ documents d'un conflit
  /// (typiquement `overlappingTransports`). Tap = ouverture du doc.
  Future<void> _showConflictDocsPickerSheet(
    List<TripDocument> docs,
    DocumentConflict conflict,
  ) async {
    final title = switch (conflict.type) {
      ConflictType.overlappingTransports => 'Transports qui se chevauchent',
      ConflictType.hotelDuringAbsence => 'Documents liés au conflit',
      ConflictType.segmentArrivalMismatch =>
          'Documents liés à cette étape',
    };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.7),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tape un document pour le modifier.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < docs.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            _ConflictDocRow(
                              document: docs[i],
                              onTap: () async {
                                Navigator.of(ctx).pop();
                                await openDocumentFormSheet(
                                  context,
                                  ref,
                                  existing: docs[i],
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(
                      'Fermer',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
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

  /// Card "Étapes du voyage" — 3 modes :
  /// 1. **Warning** : pays/région détecté + 0 étape → bandeau orange dans la
  ///    card avec 2 CTAs proactifs (Suggérer une boucle, Ajouter ma 1ère ville).
  /// 2. **CTA collapsed** : ville simple + 0 étape + non révélé → invite douce.
  /// 3. **Full** : segments existants ou révélé → liste réordonnable + actions.
  Widget _buildSegmentsCard() {
    final warning = _needsSegments && _segments.isEmpty;
    final showFull = _segments.isNotEmpty || _segmentsCardExpanded;
    return KeyedSubtree(
      key: _segmentsCardKey,
      child: _formCard(
        title: 'ÉTAPES DU VOYAGE',
        trailing: _segments.isNotEmpty
            ? Text('${_segments.length} étape${_segments.length > 1 ? 's' : ''}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary))
            : null,
        // En mode warning on ne montre PAS le hint historique (la zone warning
        // l'inclut déjà). En mode full on garde l'aide pédagogique.
        hint: warning
            ? null
            : showFull
                ? 'Découpe ton voyage par ville où tu es basé. Une étape = "où je dors". Tu peux quand même planifier des activités dans une ville voisine sur une journée.'
                : null,
        child: warning
            ? _buildSegmentsWarning()
            : showFull
                ? _buildSegmentsContent()
                : _buildSegmentsCta(),
      ),
    );
  }

  /// Mode "warning" de la card étapes : pays/région détecté + 0 étape.
  /// Bandeau orange explicite + 2 CTAs proactifs pour ne pas laisser le
  /// voyageur dans le noir. La boucle régionale est mise en avant car c'est
  /// la voie la plus simple ("je sais que je vais au Maroc, je ne sais pas
  /// où exactement → suggère-moi").
  Widget _buildSegmentsWarning() {
    final dest = _destCtrl.text.trim();
    final isCountry = _destinationKind == 'country';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            border: Border.all(color: AppColors.accent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('⚠️', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isCountry
                          ? 'Tu pars ${dest.isEmpty ? "dans un pays" : "en $dest"} — précise au moins une ville'
                          : 'Tu pars ${dest.isEmpty ? "dans une région" : "en $dest"} — précise au moins une ville',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Sans ville, je ne sais pas où chercher des activités. Choisis une option ci-dessous.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // CTA primaire : laisser l'IA proposer un itinéraire (le plus probable
        // pour quelqu'un qui tape juste un pays). 2 lignes pour expliquer la
        // valeur sans jargon SEO/IT.
        Material(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: _openRegionalLoop,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  const Text('✨', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Propose-moi un itinéraire',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Découvre un parcours avec plusieurs villes.',
                          style: TextStyle(fontSize: 11, color: Colors.white, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white, size: 20),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // CTA secondaire : ajout manuel d'une 1ère ville.
        OutlinedButton.icon(
          onPressed: () => _openSegmentEditor(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Ajouter ma première ville'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 44),
            foregroundColor: AppColors.primary,
            side: BorderSide(color: AppColors.primary),
          ),
        ),
      ],
    );
  }

  /// État collapsed : un simple CTA cliquable qui révèle la card complète.
  /// Pour les voyages mono-ville, ça évite l'overwhelm visuel par défaut.
  Widget _buildSegmentsCta() {
    return InkWell(
      onTap: () => setState(() {
        _autoSeedFirstSegmentFromDestination();
        _enforceSingleSegmentRule();
        _segmentsCardExpanded = true;
      }),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.add_location_alt_outlined, size: 20, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voyage multi-villes ?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    'Ajoute des étapes pour que je colle au bon endroit chaque jour.',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  /// V2 Phase A (Lalith 2026-05-09) — tap sur le badge "Document lié"
  /// ou l'icône cadenas du segment `idx`. Ouvre directement le doc
  /// si un seul est lié, sinon affiche une bottom sheet listant tous
  /// les docs avec leur sous-titre humain — chaque ligne est tappable
  /// pour éditer le doc. Évite le snackbar passif "Modifie ton doc"
  /// au profit d'une navigation directe.
  Future<void> _openLinkedDocsForSegment(int segmentIndex) async {
    if (segmentIndex < 0 || segmentIndex >= _segments.length) return;
    final docsAsync = ref.read(tripDocumentsProvider(widget.trip.id));
    final docs = docsAsync.maybeWhen(
      data: (d) => d,
      orElse: () => const <TripDocument>[],
    );
    final analysis = analyzePinnedDates(
      segments: _segments.toList(growable: false),
      tripStartDate: _start,
      docs: docs,
    );
    if (segmentIndex >= analysis.segments.length) return;
    final segPin = analysis.segments[segmentIndex];
    final linked = findDocsLinkedToSegment(segment: segPin, docs: docs);
    if (linked.isEmpty) {
      // Inattendu (le badge n'apparaît que pour docLinked) — fallback
      // au snackbar legacy pour ne rien casser.
      _showLockedSegmentSnackbar();
      return;
    }
    if (linked.length == 1) {
      await openDocumentFormSheet(
        context,
        ref,
        existing: linked.first,
      );
      return;
    }
    if (!mounted) return;
    await _showLinkedDocsSheet(linked, _segments[segmentIndex].city);
  }

  Future<void> _showLinkedDocsSheet(
    List<TripDocument> linked,
    String city,
  ) async {
    // Fix layout (Lalith 2026-05-09) — `isScrollControlled: true` permet
    // au sheet de prendre plus que 9/16 de la hauteur écran. La liste
    // des docs est mise en `Flexible + SingleChildScrollView` pour que
    // le contenu scroll si plusieurs docs ne tiennent pas. SafeArea
    // bottom préservé via `viewInsets` + `padding.bottom` du MediaQuery.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        return ConstrainedBox(
          constraints: BoxConstraints(
            // 80 % de l'écran max — laisse l'utilisateur voir un peu du
            // contexte derrière (la trip edit sheet) et garde la sheet
            // dismissable au tap-outside.
            maxHeight: mq.size.height * 0.8,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Documents liés à $city',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Ces documents fixent les dates de cette étape. Tape '
                    'pour modifier.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Zone scrollable : si la liste dépasse l'espace dispo,
                  // l'utilisateur scroll dans la sheet. Sinon le contenu
                  // reste compact (mainAxisSize=min sur le Column parent).
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < linked.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            _LinkedDocRow(
                              document: linked[i],
                              segmentCity: city,
                              onTap: () async {
                                Navigator.of(ctx).pop();
                                await openDocumentFormSheet(
                                  context,
                                  ref,
                                  existing: linked[i],
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(
                      'Fermer',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
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

  /// V2 Phase A — snackbar affichée quand l'utilisateur tape l'icône
  /// cadenas d'une étape liée à un document, ou tente un reorder qui
  /// shifterait une étape locked. Wording validé Lalith 2026-05-08.
  void _showLockedSegmentSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Cette étape est liée à un document de voyage. '
          'Modifie le document associé pour changer ses dates.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  /// V2 Phase A window-locked — snackbar affichée quand un reorder
  /// sortirait du bloc d'origine d'un segment dérivé d'une suggestion
  /// (ex: Ninh Bình ne peut bouger qu'à l'intérieur du bloc Hanoï).
  /// Wording validé Lalith 2026-05-08.
  void _showWindowLockedSnackbar({
    required String anchorCity,
    required DateTime windowStart,
    required DateTime windowEndExclusive,
  }) {
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Cette étape doit rester dans la période $anchorCity '
          'du ${fmt(windowStart)} au ${fmt(windowEndExclusive)}.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// V2 Phase A window-locked — détecte le bloc contigu autour de
  /// `idx` partageant la même ville d'ancrage. Un bloc est composé :
  /// - du segment d'ancrage (city == X)
  /// - + des segments dérivés (sourceAnchorCity == X)
  ///
  /// Si `idx` n'est ni dérivé ni l'anchor d'un dérivé adjacent, retourne
  /// null (segment libre, pas de window-lock).
  ({int firstIdx, int lastIdx, String anchorCity})? _findBlockRange(
    List<TripSegment> segments,
    int idx,
  ) {
    final s = segments[idx];
    String? blockCity = s.sourceAnchorCity;
    if (blockCity == null) {
      // Le segment courant n'est pas dérivé. Vérifier s'il est l'anchor
      // d'un bloc avec dérivés adjacents.
      final hasDerivedAfter = idx + 1 < segments.length &&
          segments[idx + 1].sourceAnchorCity == s.city;
      final hasDerivedBefore =
          idx - 1 >= 0 && segments[idx - 1].sourceAnchorCity == s.city;
      if (!hasDerivedAfter && !hasDerivedBefore) return null;
      blockCity = s.city;
    }
    var first = idx;
    while (first > 0) {
      final prev = segments[first - 1];
      if (prev.city == blockCity || prev.sourceAnchorCity == blockCity) {
        first--;
      } else {
        break;
      }
    }
    var last = idx;
    while (last < segments.length - 1) {
      final next = segments[last + 1];
      if (next.city == blockCity || next.sourceAnchorCity == blockCity) {
        last++;
      } else {
        break;
      }
    }
    return (firstIdx: first, lastIdx: last, anchorCity: blockCity);
  }

  /// État développé : liste réordonnable + bilan jours + boutons + optimiser.
  Widget _buildSegmentsContent() {
    // V2 Phase A (Lalith 2026-05-08) — détection des segments liés à un
    // document daté : un segment lié ne peut pas être réordonné par
    // drag & drop. Les docs sont la source de vérité, l'utilisateur
    // doit éditer le doc pour changer l'ordre/les dates.
    final docsAsync = ref.watch(tripDocumentsProvider(widget.trip.id));
    final docs = docsAsync.maybeWhen(
      data: (d) => d,
      orElse: () => const <TripDocument>[],
    );
    final pinnedAnalysis = analyzePinnedDates(
      segments: _segments.toList(growable: false),
      tripStartDate: _start,
      docs: docs,
    );
    final lockedIndices = <int>{};
    for (var i = 0; i < pinnedAnalysis.segments.length; i++) {
      if (pinnedAnalysis.segments[i].isDocLinked) lockedIndices.add(i);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_segments.isNotEmpty) ...[
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _segments.length,
            onReorder: (oldIdx, newIdx) {
              if (newIdx > oldIdx) newIdx--;
              // Garde-fou défensif : le drag handle est déjà absent pour
              // les fully-locked, mais double-check au cas où.
              if (lockedIndices.contains(oldIdx)) {
                _showLockedSegmentSnackbar();
                return;
              }
              // V2 Phase A window-lock : si le segment dragged appartient
              // à un bloc dérivé d'une suggestion, le reorder doit rester
              // à l'intérieur du bloc.
              final draggedBlock = _findBlockRange(_segments, oldIdx);
              if (draggedBlock != null) {
                if (newIdx < draggedBlock.firstIdx ||
                    newIdx > draggedBlock.lastIdx) {
                  final winStart = _segmentDates(draggedBlock.firstIdx).start;
                  final winEnd = _segmentDates(draggedBlock.lastIdx).end;
                  _showWindowLockedSnackbar(
                    anchorCity: draggedBlock.anchorCity,
                    windowStart: winStart,
                    windowEndExclusive: winEnd,
                  );
                  return;
                }
              }
              // Empêcher un reorder qui shifterait un segment fully-locked
              // (drag d'un segment libre par-dessus un locked → le locked
              // change d'index).
              final lo = oldIdx < newIdx ? oldIdx : newIdx;
              final hi = oldIdx < newIdx ? newIdx : oldIdx;
              for (var i = lo; i <= hi; i++) {
                if (i != oldIdx && lockedIndices.contains(i)) {
                  _showLockedSegmentSnackbar();
                  return;
                }
              }
              setState(() {
                final item = _segments.removeAt(oldIdx);
                _segments.insert(newIdx, item);
              });
            },
            itemBuilder: (ctx, i) {
              final seg = _segments[i];
              final dates = _segmentDates(i);
              final isLocked = lockedIndices.contains(i);
              // V2 Phase A — calcul du lockState pour le badge visuel.
              final block = isLocked
                  ? null
                  : _findBlockRange(_segments, i);
              final TripStepLockState lockState;
              String? windowAnchor;
              DateTime? winStart;
              DateTime? winEnd;
              if (isLocked) {
                lockState = TripStepLockState.docLinked;
              } else if (block != null) {
                lockState = TripStepLockState.windowLinked;
                windowAnchor = block.anchorCity;
                winStart = _segmentDates(block.firstIdx).start;
                winEnd = _segmentDates(block.lastIdx).end;
              } else {
                lockState = TripStepLockState.free;
              }
              return Padding(
                key: ValueKey('seg-$i-${seg.city}-${seg.days}'),
                padding: const EdgeInsets.only(bottom: 8),
                child: TripStepCard(
                  city: seg.city,
                  country: seg.country,
                  days: seg.days,
                  startDate: dates.start,
                  endDate: dates.end,
                  lockState: lockState,
                  windowAnchorCity: windowAnchor,
                  windowStart: winStart,
                  windowEndExclusive: winEnd,
                  // V2 (Lalith 2026-05-09) — tap sur cadenas/badge =
                  // ouverture du ou des documents liés (pas de snackbar
                  // passif). Permet d'éditer rapidement le doc qui
                  // verrouille l'étape.
                  onLockTap: isLocked
                      ? () => _openLinkedDocsForSegment(i)
                      : null,
                  // docLinked = icône cadenas tappable (pas de drag).
                  // windowLinked / free = drag handle classique (la
                  // contrainte de fenêtre est validée à `onReorder`).
                  leading: isLocked
                      ? GestureDetector(
                          onTap: () => _openLinkedDocsForSegment(i),
                          child: Tooltip(
                            message:
                                'Voir les documents liés à cette étape',
                            child: Icon(
                              Icons.lock_outline,
                              size: 16,
                              color: AppColors.accent.withValues(alpha: 0.85),
                            ),
                          ),
                        )
                      : ReorderableDragStartListener(
                          index: i,
                          child: Icon(
                            Icons.drag_indicator,
                            size: 16,
                            color: AppColors.textSecondary
                                .withValues(alpha: 0.6),
                          ),
                        ),
                  onTap: () => _openSegmentEditor(existing: seg, index: i),
                  onDelete: () => setState(() {
                    _segments.removeAt(i);
                    _enforceSingleSegmentRule();
                  }),
                ),
              );
            },
          ),
          // Bilan : total des jours placés vs durée du voyage. Le delta
          // ≤ 2 jours correspond généralement aux jours de transit (vol
          // aller/retour) et ne doit pas être présenté comme "manquant".
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 2),
            child: Text(
              _bilanText(),
              style: TextStyle(
                fontSize: 11,
                color: _totalSegmentDays > _tripDays
                    ? AppColors.error
                    : AppColors.textSecondary,
                fontWeight: _totalSegmentDays == _tripDays
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openSegmentEditor(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _openRegionalLoop,
                icon: const Text('💡', style: TextStyle(fontSize: 16)),
                // Label conditionnel : si le voyage a un itinéraire
                // détaillé (typiquement détecté depuis les vols) couvert
                // par le catalogue, on parle d'affinage. Sinon, "Suggérer"
                // générique (boucle régionale Gemini).
                label: Text(
                  _isItineraryAware ? 'Affiner les étapes' : 'Suggérer',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  foregroundColor: AppColors.accent,
                  side: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ],
        ),
        if (_segments.length >= 3) ...[
          const SizedBox(height: 6),
          // Optimisation de l'ordre : utile quand le voyageur ne connaît pas
          // la géographie locale (ex: Nancy → Metz → Épinal → Luxembourg
          // zigzague, alors que Nancy → Épinal → Metz → Luxembourg est plus
          // direct).
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _optimizeOrder,
              icon: const Text('🧭', style: TextStyle(fontSize: 14)),
              label: const Text('Optimiser l\'ordre des étapes'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                minimumSize: const Size(0, 38),
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Dialog d'édition d'une étape (ville + nombre de jours).
/// Les dates exactes sont calculées au runtime depuis l'ordre dans la liste.
/// Utilise CityAutocompleteField pour empêcher les fautes d'orthographe et
/// la saisie de régions (ex: "Alsace") au lieu de villes.
/// Résultat retourné par `_SegmentEditorDialog`. `insertAtDay` est non-null
/// quand l'user, en mode ajout, a explicitement choisi un jour de début (= il
/// veut placer l'étape AU MILIEU du voyage). Dans ce cas le caller doit faire
/// un split de l'étape qui couvre ce jour. Si null → append simple à la fin.
typedef _SegmentEditResult = ({TripSegment segment, int? insertAtDay});

class _SegmentEditorDialog extends ConsumerStatefulWidget {
  final TripSegment? existing;
  /// Code ISO 2 lettres du pays de la destination du voyage. Quand fourni,
  /// l'autocomplete des villes est restreint à ce pays (ex: voyage Thaïlande
  /// → suggestions Bangkok/Chiang Mai/Phuket, pas Paris).
  final String? restrictToCountryCode;
  /// Quand true, cette étape sera la seule du voyage : on cache le sélecteur
  /// de jours et on affiche que l'étape couvre tout le voyage. Le parent force
  /// de toute façon `days = tripDays` au retour via `_enforceSingleSegmentRule`.
  final bool lockedToTripDays;
  /// Durée totale du voyage — utilisée comme valeur quand `lockedToTripDays`.
  final int tripDays;
  /// Date de début du voyage — sert à afficher la date concrète sous le
  /// picker "Démarrer le jour X" (ex: "Jour 6 · ven. 27 juin"). Aide le
  /// voyageur à se repérer plutôt que de raisonner uniquement en jours.
  final DateTime? tripStartDate;
  /// Liste actuelle des étapes — sert à calculer le default du picker
  /// "Démarrer le jour X" (= sum des `days` + 1, soit le 1er jour libre
  /// après la dernière étape). Utilisé seulement en mode ajout.
  final List<TripSegment> existingSegments;
  const _SegmentEditorDialog({
    this.existing,
    this.restrictToCountryCode,
    this.lockedToTripDays = false,
    required this.tripDays,
    this.tripStartDate,
    this.existingSegments = const [],
  });

  @override
  ConsumerState<_SegmentEditorDialog> createState() => _SegmentEditorDialogState();
}

class _SegmentEditorDialogState extends ConsumerState<_SegmentEditorDialog> {
  String _city = '';
  String? _country;
  late int _days;
  /// Date de début choisie par l'user via le date picker. Visible uniquement
  /// en mode ajout (pas édition) et si voyage > 1 jour ET tripStartDate
  /// connue. Default = 1er jour libre après les étapes existantes (= append
  /// par défaut, l'user peut ramener la date au milieu pour insérer une
  /// excursion).
  DateTime? _startDate;
  String? _error;

  /// Le date picker ne sert que pour l'ajout d'une nouvelle étape (déplacer
  /// une étape existante = drag-drop dans la liste, géré ailleurs). Pas
  /// affiché non plus quand l'étape couvre tout le voyage ou si on n'a pas
  /// la `tripStartDate` (cas edge).
  bool get _showStartDatePicker =>
      widget.existing == null &&
      !widget.lockedToTripDays &&
      widget.tripDays > 1 &&
      widget.tripStartDate != null;

  @override
  void initState() {
    super.initState();
    _city = widget.existing?.city ?? '';
    _country = widget.existing?.country;
    _days = widget.lockedToTripDays
        ? widget.tripDays
        : widget.existing?.days ?? 2;
    if (widget.tripStartDate != null) {
      final placedDays = widget.existingSegments.fold<int>(0, (a, s) => a + s.days);
      // Si voyage déjà saturé (placedDays >= tripDays), default au jour 1
      // pour favoriser l'insertion au milieu plutôt que finir au dernier
      // jour. Sinon, default = 1er jour libre après les étapes existantes
      // (= append à la fin par défaut, comportement attendu).
      final offset = placedDays >= widget.tripDays ? 0 : placedDays;
      _startDate = widget.tripStartDate!.add(Duration(days: offset));
    }
  }

  /// Convertit la `_startDate` en jour 1-based depuis `tripStartDate`.
  /// Utilisé au submit pour passer un `insertAtDay` au caller. Si pas de
  /// startDate sélectionnée, retombe sur 1.
  int _startDayFromDate() {
    if (widget.tripStartDate == null || _startDate == null) return 1;
    final s = DateTime(widget.tripStartDate!.year, widget.tripStartDate!.month, widget.tripStartDate!.day);
    final d = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
    return d.difference(s).inDays + 1;
  }

  Future<void> _pickStartDate() async {
    final start = widget.tripStartDate;
    if (start == null) return;
    final tripStart = DateTime(start.year, start.month, start.day);
    final tripEnd = tripStart.add(Duration(days: widget.tripDays - 1));
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? tripStart,
      firstDate: tripStart,
      lastDate: tripEnd,
      helpText: 'Démarrer cette étape le',
      locale: const Locale('fr', 'FR'),
    );
    if (picked != null && mounted) {
      setState(() => _startDate = picked);
    }
  }

  void _submit() {
    final city = _city.trim();
    if (city.isEmpty) {
      setState(() => _error = 'Le nom de la ville est requis.');
      return;
    }
    if (_days < 1) {
      setState(() => _error = 'Au moins 1 jour.');
      return;
    }
    final segment = TripSegment(city: city, days: _days, country: _country);
    // En mode édition OU si l'user n'a pas changé la date (= valeur par
    // défaut "à la suite des étapes existantes"), on retombe sur le
    // comportement simple (insertAtDay null → append).
    final placedDays = widget.existingSegments.fold<int>(0, (a, s) => a + s.days);
    final defaultStartDay = (placedDays + 1).clamp(1, widget.tripDays);
    final startDay = _showStartDatePicker ? _startDayFromDate() : defaultStartDay;
    final isAppend = !_showStartDatePicker || startDay >= defaultStartDay;
    Navigator.of(context).pop<_SegmentEditResult>((
      segment: segment,
      insertAtDay: isAppend ? null : startDay,
    ));
  }

  /// Affichage humain d'une date : "ven. 27 juin 2026".
  String _formatDate(DateTime d) {
    const weekdays = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Ajouter une étape' : 'Modifier l\'étape'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CityAutocompleteField(
              initialValue: widget.existing?.city,
              autofocus: widget.existing == null,
              labelText: 'Destination',
              // V2 (Lalith 2026-05-09) — placeholder large quand le
              // voyage est multi-pays (recherche mondiale activée). Sinon
              // on garde le placeholder restreint qui guide vers les
              // villes du pays principal.
              hintText: widget.restrictToCountryCode != null
                  ? 'Tape une ville du pays choisi'
                  : 'Tape une ville, un pays ou un aéroport',
              restrictToCountryCode: widget.restrictToCountryCode,
              onSelectedDetailed: (city, country, _, _) => setState(() {
                _city = city;
                _country = country;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            if (widget.lockedToTripDays) ...[
              // Étape unique : pas de choix de durée, elle couvre tout le voyage.
              // Évite le cas "13/21 jours placés (utilisera destination)".
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 16, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Cette étape couvrira les ${widget.tripDays} jours du voyage. '
                        'Ajoute d\'autres étapes pour répartir la durée.',
                        style: TextStyle(fontSize: 12, color: AppColors.textPrimary, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Text('Durée sur place', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Row(
                children: [
                  IconButton(
                    onPressed: _days > 1 ? () => setState(() => _days--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                    color: AppColors.primary,
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '$_days jour${_days > 1 ? 's' : ''}',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _days < 60 ? () => setState(() => _days++) : null,
                    icon: const Icon(Icons.add_circle_outline),
                    color: AppColors.primary,
                  ),
                ],
              ),
              if (_showStartDatePicker) ...[
                const SizedBox(height: 12),
                // Le label rappelle la plage du voyage pour aider le voyageur
                // à se repérer (utile sur les longs voyages où il oublie les
                // bornes exactes saisies à la création).
                Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                    children: [
                      const TextSpan(text: 'Date d\'arrivée', style: TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(
                        text: '  (entre le ${_formatDateShort(widget.tripStartDate!)}'
                            ' et le ${_formatDateShort(widget.tripStartDate!.add(Duration(days: widget.tripDays - 1)))})',
                        style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w400),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: _pickStartDate,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.primary, width: 1.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _startDate != null ? _formatDate(_startDate!) : 'Choisir une date',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                          ),
                        ),
                        Icon(Icons.expand_more, color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ],
              // Bloc résumé : affiché dès que l'user a une ville et une
              // date. L'user voit l'effet exact de son choix avant de
              // valider (dates concrètes + comportement après-coup).
              if (_city.trim().isNotEmpty && _startDate != null) ...[
                const SizedBox(height: 16),
                _buildSummaryBlock(),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: AppColors.error, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        ElevatedButton(
          onPressed: _submit,
          child: Text(_buttonLabel()),
        ),
      ],
    );
  }

  /// Bloc résumé en bas du dialog. Montre les dates exactes (arrivée +
  /// départ) et le comportement après validation (append vs split). Le
  /// voyageur voit immédiatement l'effet de son choix.
  ///
  /// Sémantique des dates : `_days` = nombre de jours sur place, donc la
  /// date de **départ** affichée = arrivée + days (exclusive). Ex: arrivée
  /// 6 août, 2 jours sur place → départ 8 août (l'user passe les 6 et 7
  /// sur place, repart le 8 au matin). Plus intuitif que "du 6 au 7" qui
  /// suggère qu'on dort au moins 1 nuit le 7.
  Widget _buildSummaryBlock() {
    final start = _startDate!;
    final end = start.add(Duration(days: _days));
    final tripStart = widget.tripStartDate!;
    final tripEnd = tripStart.add(Duration(days: widget.tripDays - 1));
    final placedDays = widget.existingSegments.fold<int>(0, (a, s) => a + s.days);
    final defaultStartDay = (placedDays + 1).clamp(1, widget.tripDays);
    final currentStartDay = _startDayFromDate();
    final isAppend = currentStartDay >= defaultStartDay;
    // Détecte si l'étape déborde de la fin du voyage. La date de départ
    // peut être tripEnd + 1 (l'user repart le lendemain de la fin), donc
    // on tolère ce cas. Au-delà, on warne.
    final overflowDays = end.difference(tripEnd.add(const Duration(days: 1))).inDays;
    final overflows = overflowDays > 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: overflows ? const Color(0xFFFEF3C7) : AppColors.primaryLight,
        borderRadius: BorderRadius.circular(10),
        border: overflows ? Border.all(color: AppColors.accent.withValues(alpha: 0.5)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.4),
              children: [
                TextSpan(text: _city, style: const TextStyle(fontWeight: FontWeight.w700)),
                const TextSpan(text: ' sera ajouté du '),
                TextSpan(text: _formatDateShort(start), style: const TextStyle(fontWeight: FontWeight.w700)),
                const TextSpan(text: ' au '),
                TextSpan(text: _formatDateShort(end), style: const TextStyle(fontWeight: FontWeight.w700)),
                const TextSpan(text: '.'),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (overflows)
            Text(
              '⚠️ Cette étape dépasse la fin du voyage de $overflowDays jour${overflowDays > 1 ? 's' : ''}. '
              'Réduis la durée ou avance la date d\'arrivée.',
              style: TextStyle(fontSize: 12, color: AppColors.textPrimary, height: 1.4, fontWeight: FontWeight.w500),
            )
          else
            Text(
              isAppend
                  ? 'Cette étape s\'ajoute à la suite des autres.'
                  : 'J\'ajusterai automatiquement les étapes suivantes.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
            ),
        ],
      ),
    );
  }

  /// Label dynamique du bouton de validation.
  /// - Mode édition : "Enregistrer".
  /// - Mode ajout avec ville : "Ajouter `<ville>`" (action explicite).
  /// - Mode ajout sans ville : "Ajouter une étape" (placeholder).
  String _buttonLabel() {
    if (widget.existing != null) return 'Enregistrer';
    final city = _city.trim();
    if (city.isEmpty) return 'Ajouter une étape';
    return 'Ajouter $city';
  }

  /// Format court "jeu. 2 juillet" sans année. Utilisé dans le résumé où
  /// l'user voit déjà l'année dans le contexte voyage (au-dessus).
  String _formatDateShort(DateTime d) {
    const weekdays = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}

/// Aperçu avant/après pour l'optimisation de l'ordre des étapes. Affiche les
/// 2 listes côte à côte (ancien ordre figé en gris, nouveau ordre en couleur)
/// pour que l'utilisateur valide explicitement le changement avant qu'on bouge
/// ses données. Pas d'auto-apply : l'ordre manuel peut avoir une raison qui
/// échappe à l'algo (ex: rdv pro à Strasbourg jour 3).
class _OrderPreviewDialog extends StatelessWidget {
  final List<TripSegment> oldOrder;
  final List<TripSegment> newOrder;
  final String anchorName;
  const _OrderPreviewDialog({
    required this.oldOrder,
    required this.newOrder,
    required this.anchorName,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Optimiser l\'ordre des étapes'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'En partant de $anchorName, je propose ce nouvel ordre pour limiter les zigzags. Le nombre de jours par étape reste le même.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 16),
            Text('AVANT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.5)),
            const SizedBox(height: 6),
            ..._buildList(oldOrder, highlight: false),
            const SizedBox(height: 14),
            Text('APRÈS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary, letterSpacing: 0.5)),
            const SizedBox(height: 6),
            ..._buildList(newOrder, highlight: true),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Garder mon ordre')),
        ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Appliquer')),
      ],
    );
  }

  List<Widget> _buildList(List<TripSegment> list, {required bool highlight}) {
    final color = highlight ? AppColors.primary : AppColors.textSecondary;
    return [
      for (var i = 0; i < list.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Container(
                width: 22, height: 22,
                decoration: BoxDecoration(
                  color: highlight ? AppColors.primaryLight : AppColors.surface,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: color),
                ),
                child: Center(
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  list[i].country != null && list[i].country!.isNotEmpty
                      ? '${list[i].city} · ${list[i].country}'
                      : list[i].city,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: highlight ? FontWeight.w600 : FontWeight.normal,
                    color: highlight ? AppColors.textPrimary : AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${list[i].days}j',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
    ];
  }
}

/// Section accordéon pour l'écran "Modifier le voyage". Affiche un header
/// cliquable (titre + résumé dynamique + chevron) qui ouvre/ferme le contenu
/// en animation douce. Les résumés évitent à l'utilisateur d'avoir à ouvrir
/// chaque section pour voir l'état courant.
class _TripEditSection extends StatelessWidget {
  final String title;
  final String summary;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  const _TripEditSection({
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: AppColors.border.withValues(alpha: 0.7),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header cliquable
          InkWell(
            onTap: onToggle,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          summary,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textPrimary,
                            height: 1.35,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.expand_more,
                      size: 22,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Contenu animé
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 1,
                          color: AppColors.border.withValues(alpha: 0.5),
                          margin: const EdgeInsets.only(bottom: 12),
                        ),
                        child,
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─── Phase C — bannière "Points à vérifier" ─────────────────────────

/// Bannière collapsible affichant la liste des conflits détectés par
/// `detectDocumentConflicts` (Phase B). Amber/accent doux pour signaler
/// "à vérifier" sans bloquer. Expanded par défaut quand affichée (un
/// conflit doit attirer l'œil) ; l'utilisateur peut replier pour réduire
/// le bruit. Pas de fix automatique — chaque ligne est une note pour
/// que l'utilisateur édite manuellement le document concerné.
class _ConflictsBanner extends StatefulWidget {
  final List<DocumentConflict> conflicts;

  /// V2 (Lalith 2026-05-09) — callback invoqué quand l'utilisateur tape
  /// une ligne de conflit. Le caller résoud les docs concernés et
  /// ouvre la sheet d'édition (1 doc) ou un picker (≥2 docs).
  final void Function(DocumentConflict) onTap;

  const _ConflictsBanner({
    required this.conflicts,
    required this.onTap,
  });

  @override
  State<_ConflictsBanner> createState() => _ConflictsBannerState();
}

class _ConflictsBannerState extends State<_ConflictsBanner> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final count = widget.conflicts.length;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accentLight.withValues(alpha: 0.45),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header tappable (toggle expand).
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      count == 1
                          ? '1 point à vérifier'
                          : '$count points à vérifier',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          // Liste des conflits (visible si expanded).
          if (_expanded) ...[
            Container(
              height: 1,
              color: AppColors.accent.withValues(alpha: 0.25),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < widget.conflicts.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _ConflictRow(
                      conflict: widget.conflicts[i],
                      onTap: () => widget.onTap(widget.conflicts[i]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// V2 Phase A (Lalith 2026-05-09) — ligne d'un doc dans la sheet
/// "Documents liés à {city}". Affiche le RÔLE du doc relatif au segment
/// (Arrivée / Départ / Hébergement) + icône adaptée + carrier/résa +
/// route ville→ville + dates formatées. Tappable pour ouvrir le doc.
class _LinkedDocRow extends StatelessWidget {
  final TripDocument document;
  final String segmentCity;
  final VoidCallback onTap;

  const _LinkedDocRow({
    required this.document,
    required this.segmentCity,
    required this.onTap,
  });

  _LinkedDocRole get _role {
    if (document.category == DocumentCategory.hotel) {
      return _LinkedDocRole.hotel;
    }
    final segNorm = _normalizeCityName(segmentCity);
    final toCity = (document.metadata['to_city'] as String?)?.trim() ?? '';
    final fromCity = (document.metadata['from_city'] as String?)?.trim() ?? '';
    if (toCity.isNotEmpty && _normalizeCityName(toCity) == segNorm) {
      return _LinkedDocRole.arrival;
    }
    if (fromCity.isNotEmpty && _normalizeCityName(fromCity) == segNorm) {
      return _LinkedDocRole.departure;
    }
    return _LinkedDocRole.unknown;
  }

  IconData get _icon {
    final cat = document.category;
    switch (_role) {
      case _LinkedDocRole.hotel:
        return Icons.hotel;
      case _LinkedDocRole.arrival:
        if (cat == DocumentCategory.train) return Icons.train;
        return Icons.flight_land;
      case _LinkedDocRole.departure:
        if (cat == DocumentCategory.train) return Icons.train;
        return Icons.flight_takeoff;
      case _LinkedDocRole.unknown:
        return Icons.description_outlined;
    }
  }

  String _title() {
    switch (_role) {
      case _LinkedDocRole.arrival:
        return 'Arrivée à $segmentCity';
      case _LinkedDocRole.departure:
        return 'Départ de $segmentCity';
      case _LinkedDocRole.hotel:
        return 'Hébergement à $segmentCity';
      case _LinkedDocRole.unknown:
        return document.name;
    }
  }

  /// Sous-titre = "Compagnie · Numéro de vol/train" ou nom de l'hôtel.
  /// Reste compact, pas de redondance avec la route.
  String? _subtitle() {
    final m = document.metadata;
    if (_role == _LinkedDocRole.hotel) {
      // Pour l'hôtel, le nom du doc est déjà l'identité — on pourrait
      // ajouter l'adresse mais le row est déjà chargé. On reprend `name`.
      return document.name;
    }
    final carrier = (m['airline'] as String?)?.trim() ??
        (m['company'] as String?)?.trim();
    final number = (m['flight_number'] as String?)?.trim() ??
        (m['train_number'] as String?)?.trim();
    final parts = <String>[];
    if (carrier != null && carrier.isNotEmpty) parts.add(carrier);
    if (number != null && number.isNotEmpty) parts.add(number);
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  /// Route compacte ville→ville. Préfère `from_city`/`to_city` (set par
  /// le form / Gemini extraction) au lieu des noms d'aéroports
  /// verbeux. Null pour les hôtels (pas de route).
  String? _route() {
    if (_role == _LinkedDocRole.hotel) return null;
    final m = document.metadata;
    final from = (m['from_city'] as String?)?.trim() ??
        (m['from'] as String?)?.trim();
    final to = (m['to_city'] as String?)?.trim() ??
        (m['to'] as String?)?.trim();
    if (from == null || from.isEmpty || to == null || to.isEmpty) {
      return null;
    }
    return '$from → $to';
  }

  /// Ligne de date contextuelle au rôle :
  /// - arrivée → "{date d'arrivée} · arrivée HH:MM"
  /// - départ → "{date de départ} · départ HH:MM"
  /// - hôtel  → "{check-in} → {check-out}"
  String? _dateLine() {
    final m = document.metadata;
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
    DateTime? parse(dynamic v) =>
        v is String ? DateTime.tryParse(v) : null;
    switch (_role) {
      case _LinkedDocRole.arrival:
        // arrivalDateFromMetadata gère arrival_date explicite + fallback
        // J+1 si arrival_time < departure_time.
        final arrival = arrivalDateFromMetadata(m);
        if (arrival == null) return null;
        final time = (m['arrival_time'] as String?)?.trim();
        final base = fmt(arrival);
        return time != null && time.isNotEmpty
            ? '$base · arrivée $time'
            : base;
      case _LinkedDocRole.departure:
        final departure = parse(m['date']);
        if (departure == null) return null;
        final time = (m['departure_time'] as String?)?.trim();
        final base = fmt(departure);
        return time != null && time.isNotEmpty
            ? '$base · départ $time'
            : base;
      case _LinkedDocRole.hotel:
        final ci = parse(m['check_in']);
        final co = parse(m['check_out']);
        if (ci == null || co == null) return null;
        return '${fmt(ci)} → ${fmt(co)}';
      case _LinkedDocRole.unknown:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitle();
    final route = _route();
    final dateLine = _dateLine();
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Pastille icône — bleu/gris doux, neutre.
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _icon,
                  size: 18,
                  color: AppColors.primary.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary.withValues(alpha: 0.75),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (route != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        route,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (dateLine != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        dateLine,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _LinkedDocRole { arrival, departure, hotel, unknown }

/// Réplique locale du `_normalize` projet pour le matching ville
/// case+accent insensible (cf. `_normalizeCity` ailleurs dans le repo).
String _normalizeCityName(String s) {
  const accents = {
    'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a',
    'ç': 'c',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ï': 'i', 'î': 'i',
    'ñ': 'n',
    'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
  };
  var out = s.toLowerCase().trim();
  accents.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

class _ConflictRow extends StatelessWidget {
  final DocumentConflict conflict;
  final VoidCallback onTap;

  const _ConflictRow({required this.conflict, required this.onTap});

  IconData get _icon => switch (conflict.type) {
        ConflictType.overlappingTransports => Icons.compare_arrows,
        ConflictType.hotelDuringAbsence => Icons.hotel_outlined,
        ConflictType.segmentArrivalMismatch => Icons.event_busy,
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  _icon,
                  size: 14,
                  color: AppColors.accent.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conflict.message,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary.withValues(alpha: 0.9),
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right,
                size: 14,
                color: AppColors.textSecondary.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// V2 (Lalith 2026-05-09) — ligne de doc dans la mini-sheet de pick
/// pour un conflit (typiquement `overlappingTransports`). Plus
/// minimaliste que `_LinkedDocRow` : pas de rôle relatif au segment
/// (les docs en conflit n'ont pas de segment unique de référence),
/// juste emoji catégorie + nom + sous-titre humain.
class _ConflictDocRow extends StatelessWidget {
  final TripDocument document;
  final VoidCallback onTap;

  const _ConflictDocRow({required this.document, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Text(
                categoryEmoji(document.category),
                style: const TextStyle(fontSize: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (document.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        document.subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
