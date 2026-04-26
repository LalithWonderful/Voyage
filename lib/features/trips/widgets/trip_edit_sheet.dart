import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/city_autocomplete_field.dart';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
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
  /// Clé du card "ÉTAPES DU VOYAGE" pour auto-scroll quand le bandeau apparaît.
  final GlobalKey _segmentsCardKey = GlobalKey();

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
    _planningMode = widget.trip.planningMode;
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
    setState(() => _destinationKind = pick.kind);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _destCtrl.dispose();
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
        'cover_emoji': _emoji,
        'travelers': _travelers.map((t) => t.toJson()).toList(),
        'traveler_type': _travelerType,
        'interests': _interests.toList(),
        'itinerary_segments': _segments.isEmpty ? null : _segments.map((s) => s.toJson()).toList(),
        'planning_mode': _planningMode?.dbValue,
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
  /// Renvoie un libellé compact (ex: "du 25 au 27/04" ou "du 28/04 au 02/05").
  String _fmtSegmentDates(int index) {
    var offsetBefore = 0;
    for (var i = 0; i < index; i++) {
      offsetBefore += _segments[i].days;
    }
    final seg = _segments[index];
    final from = _start.add(Duration(days: offsetBefore));
    final to = from.add(Duration(days: seg.days - 1));
    final sameMonth = from.month == to.month && from.year == to.year;
    if (sameMonth) {
      return 'du ${from.day} au ${to.day}/${to.month.toString().padLeft(2, '0')}';
    }
    return 'du ${_fmtDate(from)} au ${_fmtDate(to)}';
  }

  /// Total des jours déjà placés dans les étapes — pour comparer avec la durée du voyage.
  int get _totalSegmentDays => _segments.fold(0, (s, seg) => s + seg.days);

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
    );
    if (result == null || result.isEmpty || !mounted) return;
    setState(() => _segments.addAll(result));
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
    final result = await showDialog<TripSegment?>(
      context: context,
      builder: (ctx) => _SegmentEditorDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (index != null) {
        _segments[index] = result;
      } else {
        _segments.add(result);
      }
    });
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
                      onSelectedDetailed: (dest, _, _, kind) => setState(() {
                        _destCtrl.text = dest;
                        _destinationKind = kind;
                        // Si pays/région sans étapes, déplie automatiquement la
                        // card étapes pour que les CTA "Ajouter/Suggérer" soient
                        // visibles immédiatement (la card est juste en dessous,
                        // donc l'auto-scroll n'est même plus indispensable, mais
                        // on garde au cas où le clavier soit déplié).
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
                      }),
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
              if (trailing != null) trailing,
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
          : 'Préférences spécifiques à ce voyage, utilisées par l\'IA.',
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
                      'Sans ville, l\'IA ne sait pas où chercher des activités. Choisis une option ci-dessous.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // CTA primaire : laisser l'IA proposer une boucle (le plus probable
        // pour quelqu'un qui tape juste un pays).
        ElevatedButton.icon(
          onPressed: _openRegionalLoop,
          icon: const Text('💡', style: TextStyle(fontSize: 16)),
          label: const Text('Suggérer une boucle régionale'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 44),
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
      onTap: () => setState(() => _segmentsCardExpanded = true),
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
                    'Ajoute des étapes pour que l\'IA colle au bon endroit chaque jour.',
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
                          onPressed: () => setState(() => _segments.removeAt(i)),
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
class _SegmentEditorDialog extends ConsumerStatefulWidget {
  final TripSegment? existing;
  const _SegmentEditorDialog({this.existing});

  @override
  ConsumerState<_SegmentEditorDialog> createState() => _SegmentEditorDialogState();
}

class _SegmentEditorDialogState extends ConsumerState<_SegmentEditorDialog> {
  String _city = '';
  String? _country;
  late int _days;
  String? _error;

  @override
  void initState() {
    super.initState();
    _city = widget.existing?.city ?? '';
    _country = widget.existing?.country;
    _days = widget.existing?.days ?? 2;
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
    // Si l'utilisateur édite la ville sans changer la sélection autocomplete, on
    // garde le pays existant (cas modif d'une étape déjà saisie). Si la ville a
    // changé via la saisie manuelle, _country a été reset à null.
    Navigator.of(context).pop(TripSegment(city: city, days: _days, country: _country));
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
              labelText: 'Ville',
              hintText: 'ex: Strasbourg',
              onSelectedDetailed: (city, country, _, _) => setState(() {
                _city = city;
                _country = country;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            Text('JOURS SUR PLACE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
            const SizedBox(height: 6),
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
            const SizedBox(height: 4),
            Text(
              'Les dates précises sont calculées automatiquement à partir de l\'ordre des étapes.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: AppColors.error, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        ElevatedButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
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
              'En partant de $anchorName, l\'IA propose ce nouvel ordre pour limiter les zigzags. Le nombre de jours par étape reste le même.',
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
