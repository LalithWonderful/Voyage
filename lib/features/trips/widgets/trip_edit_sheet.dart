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
import 'package:voyage/features/regions/services/country_regions_repository.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/widgets/airport_picker_dialog.dart';
import 'package:voyage/features/trips/widgets/regional_loop_sheet.dart';

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

  /// Calcule les dates effectives d'une étape selon son index dans la liste.
  /// Renvoie un libellé compact (ex: "du 25 au 28/04" ou "du 28/04 au 02/05").
  /// Format **"départ exclusif"** : `to` = date à laquelle l'user repart de
  /// l'étape (= début de l'étape suivante). Cohérent avec le résumé du
  /// dialog d'ajout d'étape qui dit "Ko Samui sera ajouté du jeu. 2 juillet
  /// au sam. 4 juillet" pour 2 jours sur place. Le voyageur pense en
  /// termes "j'arrive le X et je repars le Y" (convention hôtelière).
  String _fmtSegmentDates(int index) {
    var offsetBefore = 0;
    for (var i = 0; i < index; i++) {
      offsetBefore += _segments[i].days;
    }
    final seg = _segments[index];
    final from = _start.add(Duration(days: offsetBefore));
    final to = from.add(Duration(days: seg.days));
    final sameMonth = from.month == to.month && from.year == to.year;
    if (sameMonth) {
      return 'du ${from.day} au ${to.day}/${to.month.toString().padLeft(2, '0')}';
    }
    return 'du ${_fmtDate(from)} au ${_fmtDate(to)}';
  }

  /// Total des jours déjà placés dans les étapes — pour comparer avec la durée du voyage.
  int get _totalSegmentDays => _segments.fold(0, (s, seg) => s + seg.days);

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

  /// Ouvre la sheet "Suggérer une boucle régionale" qui appelle Gemini pour
  /// proposer 3-5 villes autour de la destination principale. Les étapes
  /// sélectionnées par l'utilisateur sont AJOUTÉES à la liste existante (pas
  /// de remplacement — l'utilisateur peut toujours supprimer ce qu'il ne veut pas).
  Future<void> _openRegionalLoop() async {
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
    final result = await showDialog<_SegmentEditResult?>(
      context: context,
      builder: (ctx) => _SegmentEditorDialog(
        existing: existing,
        // Filtre l'autocomplete des villes au pays de la destination quand
        // disponible. Si null (city/place ou code pays pas encore récupéré),
        // on accepte toutes les villes du monde (comportement historique).
        restrictToCountryCode: _destinationCountryCode,
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
                    // ─── Section haut : infos de base (sans card) ─────────────
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
                            width: 42, height: 42,
                            decoration: BoxDecoration(
                              color: sel ? AppColors.primaryLight : AppColors.surface,
                              border: Border.all(color: sel ? AppColors.primary : AppColors.border, width: sel ? 2 : 1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(child: Text(e, style: const TextStyle(fontSize: 22))),
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

                    // ─── Cards de configuration (ordre = chronologie mentale du voyageur :
                    // où précisément → quand → comment je voyage → comment l'IA m'aide).
                    // Le bandeau ⚠️ pays/région vit À L'INTÉRIEUR de la card étapes,
                    // pour ne pas dupliquer l'alerte (cf. _buildSegmentsCard).
                    _buildSegmentsCard(),

                    Row(
                      children: [
                        Expanded(child: _dateField(label: 'Départ', value: _fmtDate(_start), onTap: () => _pickDate(isStart: true))),
                        const SizedBox(width: 10),
                        Expanded(child: _dateField(label: 'Retour', value: _fmtDate(_end), onTap: () => _pickDate(isStart: false))),
                      ],
                    ),
                    const SizedBox(height: 22),

                    _buildStyleCard(),
                    _buildInterestsCard(),
                    _buildBudgetCard(),
                    _buildTransportCard(),
                    _buildPlanningModeCard(),

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
          const SizedBox(height: 14),
          Container(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          _buildHomeAirportRow(),
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
          ? 'Lunao adaptera ses recommandations à ces préférences.'
          : "Optionnel — Lunao utilisera tes préférences globales du profil.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Aller à la destination',
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
          const SizedBox(height: 14),
          Text('Sur place',
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
              ('🛵', 'Scooter', 'scooter'),
              ('💎', 'Le plus confortable', 'comfort'),
              ('💰', 'Le moins cher', 'budget'),
            ].map(_localChip).toList(),
          ),
        ],
      ),
    );
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

  /// État développé : liste réordonnable + bilan jours + boutons + optimiser.
  Widget _buildSegmentsContent() {
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
              setState(() {
                if (newIdx > oldIdx) newIdx--;
                final item = _segments.removeAt(oldIdx);
                _segments.insert(newIdx, item);
              });
            },
            itemBuilder: (ctx, i) {
              final seg = _segments[i];
              return Padding(
                key: ValueKey('seg-$i-${seg.city}-${seg.days}'),
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => _openSegmentEditor(existing: seg, index: i),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: Icon(Icons.drag_indicator, size: 18, color: AppColors.textSecondary),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.place_outlined, size: 18, color: AppColors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(seg.city, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
                                  ),
                                  if (seg.country != null && seg.country!.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Text('· ${seg.country}', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                  ],
                                ],
                              ),
                              Text(
                                '${seg.days} jour${seg.days > 1 ? 's' : ''} · ${_fmtSegmentDates(i)}',
                                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() {
                            _segments.removeAt(i);
                            _enforceSingleSegmentRule();
                          }),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          color: AppColors.textSecondary,
                          tooltip: 'Supprimer cette étape',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          // Bilan : total des jours placés vs durée du voyage
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 2),
            child: Text(
              _totalSegmentDays == _tripDays
                  ? '✓ $_totalSegmentDays jour${_totalSegmentDays > 1 ? 's' : ''} placé${_totalSegmentDays > 1 ? 's' : ''} · couvre tout le voyage'
                  : _totalSegmentDays < _tripDays
                      ? '$_totalSegmentDays / $_tripDays jour${_tripDays > 1 ? 's' : ''} placés · ${_tripDays - _totalSegmentDays} restant${(_tripDays - _totalSegmentDays) > 1 ? 's' : ''} (utilisera "${_destCtrl.text.trim().isEmpty ? 'destination' : _destCtrl.text.trim()}")'
                      : '⚠ $_totalSegmentDays jours placés dépasse les $_tripDays jours du voyage',
              style: TextStyle(
                fontSize: 11,
                color: _totalSegmentDays > _tripDays ? AppColors.error : AppColors.textSecondary,
                fontWeight: _totalSegmentDays == _tripDays ? FontWeight.w600 : FontWeight.normal,
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
                label: const Text('Suggérer'),
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
              hintText: widget.restrictToCountryCode != null
                  ? 'Tape une ville du pays choisi'
                  : 'ex: Strasbourg',
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
