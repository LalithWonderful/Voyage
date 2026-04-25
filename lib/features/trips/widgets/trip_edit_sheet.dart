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

const _travelerTypes = [
  ('🚐', 'Road-trip'),
  ('✨', 'Grand luxe'),
  ('💰', 'Meilleur prix'),
  ('🎒', 'Backpack'),
  ('👨‍👩‍👧', 'En famille'),
  ('💼', 'Voyage pro'),
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
  bool _saving = false;

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

  Future<void> _addTraveler() async {
    final result = await showDialog<Traveler>(
      context: context,
      builder: (_) => const _AddTravelerDialog(),
    );
    if (result != null) setState(() => _travelers.add(result));
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
    if (_totalSegmentNights > _tripNights) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Tes étapes totalisent $_totalSegmentNights nuits mais le voyage ne dure que $_tripNights nuits. '
            'Réduis ou supprime des étapes pour pouvoir enregistrer.',
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
      offsetBefore += _segments[i].nights;
    }
    final seg = _segments[index];
    final from = _start.add(Duration(days: offsetBefore));
    final to = from.add(Duration(days: seg.nights - 1));
    final sameMonth = from.month == to.month && from.year == to.year;
    if (sameMonth) {
      return 'du ${from.day} au ${to.day}/${to.month.toString().padLeft(2, '0')}';
    }
    return 'du ${_fmtDate(from)} au ${_fmtDate(to)}';
  }

  /// Total des nuits déjà placées dans les étapes — pour comparer avec la durée du voyage.
  int get _totalSegmentNights => _segments.fold(0, (s, seg) => s + seg.nights);

  /// Durée du voyage en nuits (= durée en jours - 1, car la dernière nuit n'est pas comptée
  /// si l'utilisateur rentre le jour du retour).
  int get _tripNights => _end.difference(_start).inDays;

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
      existingNightsPlaced: _totalSegmentNights,
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
                    TextField(controller: _destCtrl),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(child: _dateField(label: 'Départ', value: _fmtDate(_start), onTap: () => _pickDate(isStart: true))),
                        const SizedBox(width: 10),
                        Expanded(child: _dateField(label: 'Retour', value: _fmtDate(_end), onTap: () => _pickDate(isStart: false))),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Étapes du voyage (optionnel — pour les voyages multi-villes)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('ÉTAPES DU VOYAGE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        if (_segments.isNotEmpty)
                          Text('${_segments.length} étape${_segments.length > 1 ? 's' : ''}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Si tu visites plusieurs villes pendant ce voyage, ajoute chaque étape pour que les suggestions IA collent au bon endroit chaque jour. Sinon, laisse vide.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 8),
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
                            key: ValueKey('seg-$i-${seg.city}-${seg.nights}'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              onTap: () => _openSegmentEditor(existing: seg, index: i),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
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
                                            '${seg.nights} nuit${seg.nights > 1 ? 's' : ''} · ${_fmtSegmentDates(i)}',
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
                      // Bilan : total des nuits placées vs durée du voyage
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6, top: 2),
                        child: Text(
                          _totalSegmentNights == _tripNights
                              ? '✓ ${_totalSegmentNights} nuit${_totalSegmentNights > 1 ? 's' : ''} placée${_totalSegmentNights > 1 ? 's' : ''} · couvre tout le voyage'
                              : _totalSegmentNights < _tripNights
                                  ? '${_totalSegmentNights} / $_tripNights nuit${_tripNights > 1 ? 's' : ''} placées · ${_tripNights - _totalSegmentNights} restante${(_tripNights - _totalSegmentNights) > 1 ? 's' : ''} (utilisera "${_destCtrl.text.trim().isEmpty ? 'destination' : _destCtrl.text.trim()}")'
                                  : '⚠ ${_totalSegmentNights} nuits placées dépasse les $_tripNights nuits du voyage',
                          style: TextStyle(
                            fontSize: 11,
                            color: _totalSegmentNights > _tripNights ? AppColors.error : AppColors.textSecondary,
                            fontWeight: _totalSegmentNights == _tripNights ? FontWeight.w600 : FontWeight.normal,
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
                      const SizedBox(height: 8),
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
                      Text(
                        'Réorganise tes étapes pour limiter les allers-retours géographiques.',
                        style: TextStyle(fontSize: 10, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 18),

                    // Style de ce voyage (optionnel, override du profil global)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('STYLE DE CE VOYAGE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        if (_travelerType != null || _interests.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() {
                              _travelerType = null;
                              _interests.clear();
                            }),
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                            child: Text('Utiliser mon profil', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _travelerType == null && _interests.isEmpty
                          ? 'Vide = l\'IA utilise ton profil voyageur global.'
                          : 'Préférences spécifiques à ce voyage, utilisées par l\'IA.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                    ),
                    const SizedBox(height: 10),

                    Text('Type de voyageur', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _travelerTypes.map((t) {
                        final sel = _travelerType == t.$2;
                        return GestureDetector(
                          onTap: () => setState(() => _travelerType = sel ? null : t.$2),
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
                    const SizedBox(height: 12),

                    Text('Centres d\'intérêt', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(
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
                    const SizedBox(height: 18),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('VOYAGEURS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        Text('${_travelers.length} ${_travelers.length > 1 ? 'personnes' : 'personne'}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._travelers.asMap().entries.map((e) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: Text('${e.value.name} · ${e.value.age} ans', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                          IconButton(
                            onPressed: () => setState(() => _travelers.removeAt(e.key)),
                            icon: const Icon(Icons.close, size: 18),
                            color: AppColors.textSecondary,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          ),
                        ],
                      ),
                    )),
                    OutlinedButton.icon(
                      onPressed: _addTraveler,
                      icon: const Icon(Icons.person_add_alt_1, size: 18),
                      label: const Text('Ajouter un voyageur'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 44),
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 20),
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
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Enregistrer'),
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
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Prénom'), textCapitalization: TextCapitalization.words, autofocus: true),
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

/// Dialog d'édition d'une étape (ville + nombre de nuits).
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
  late int _nights;
  String? _error;

  @override
  void initState() {
    super.initState();
    _city = widget.existing?.city ?? '';
    _country = widget.existing?.country;
    _nights = widget.existing?.nights ?? 2;
  }

  void _submit() {
    final city = _city.trim();
    if (city.isEmpty) {
      setState(() => _error = 'Le nom de la ville est requis.');
      return;
    }
    if (_nights < 1) {
      setState(() => _error = 'Au moins 1 nuit.');
      return;
    }
    // Si l'utilisateur édite la ville sans changer la sélection autocomplete, on
    // garde le pays existant (cas modif d'une étape déjà saisie). Si la ville a
    // changé via la saisie manuelle, _country a été reset à null.
    Navigator.of(context).pop(TripSegment(city: city, nights: _nights, country: _country));
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
              onSelectedDetailed: (city, country, _) => setState(() {
                _city = city;
                _country = country;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            Text('NUITS SUR PLACE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
            const SizedBox(height: 6),
            Row(
              children: [
                IconButton(
                  onPressed: _nights > 1 ? () => setState(() => _nights--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                  color: AppColors.primary,
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '$_nights nuit${_nights > 1 ? 's' : ''}',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _nights < 30 ? () => setState(() => _nights++) : null,
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
              'En partant de $anchorName, l\'IA propose ce nouvel ordre pour limiter les zigzags. Les nuits par étape restent les mêmes.',
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
                '${list[i].nights}n',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
    ];
  }
}
