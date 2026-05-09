import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/planning/services/activity_staleness_service.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/flight_timeline_builder.dart';
import 'package:voyage/features/trips/services/preserved_segments.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Synchronise les étapes d'un voyage à partir de la chronologie des vols.
///
/// V3 (2026-05-08) : refonte complète. Avant, on cherchait juste à ajouter
/// les villes manquantes en respectant les segments existants — mauvaise
/// idée quand un segment auto-seedé "Bangkok 47 jours" couvre la durée
/// totale d'un voyage qui contient en réalité un circuit. La logique V3 :
///
/// 1. **Calcule** la timeline réelle depuis les vols
///    (cf. [buildTripStayTimelineFromFlightDocuments]).
/// 2. **Compare** à l'état actuel (segments existants), produit un
///    [TripTimelineDiff] avec added/updated/removed/preservedManual/warnings.
/// 3. **Applique** seulement après validation utilisateur.
///
/// Règles de merge :
/// - Si un segment existant a la MÊME ville qu'un séjour de la timeline ET
///   sa durée est compatible (= durée du voyage entier ou similaire à la
///   durée déduite), on le considère "auto-seedé" et on le remplace.
/// - Si un segment existant a une ville qui n'apparaît dans AUCUN vol, on
///   le PRÉSERVE (étape manuelle de l'utilisateur).
/// - Les nouveaux séjours déduits sont ajoutés.
class TripSegmentSyncService {
  final SupabaseClient _client;

  TripSegmentSyncService(this._client);

  /// Calcule un diff prévisualisable entre l'état actuel des segments du
  /// voyage et la timeline déduite de ses vols. Ne modifie rien.
  /// Retourne null si le voyage est introuvable.
  Future<TripTimelineDiff?> findTimelineDiff({
    required String tripId,
    String? userHomeAirportFromProfile,
  }) async {
    final tripRow =
        await _client.from('trips').select().eq('id', tripId).maybeSingle();
    if (tripRow == null) return null;
    final trip = Trip.fromJson(tripRow);

    final docsRows = await _client
        .from('trip_documents')
        .select()
        .eq('trip_id', tripId)
        .inFilter('category', [DocumentCategory.flight, DocumentCategory.train]);
    final docs = (docsRows as List)
        .map((d) => TripDocument.fromJson(d as Map<String, dynamic>))
        .toList();

    // Résout la home base : aéroport override voyage, sinon profil, sinon CDG.
    final homeIata = trip.homeAirportIata ??
        userHomeAirportFromProfile ??
        'CDG';
    final homeLookup = lookupAirport(homeIata);
    final homeCity = homeLookup?.city;

    final timeline = buildTripStayTimelineFromFlightDocuments(
      docs: docs,
      tripEndDate: trip.endDate,
      homeAirportCity: homeCity,
    );

    return _computeDiff(trip: trip, timeline: timeline);
  }

  /// Applique un diff précédemment calculé : remplace les segments du voyage
  /// par la liste fusionnée. Idempotent.
  ///
  /// V5.4 (Lalith 2026-05-10) — auto-placement par dates d'origine. Les
  /// étapes préservées (manuelles + window-linked) sont d'abord
  /// retentées sur leurs dates EXACTES dans le nouveau squelette
  /// doc-derived. Celles dont les dates restent libres → réinsérées
  /// automatiquement. Les autres → retournées comme leftovers que le
  /// caller stocke dans le bandeau « À replacer ».
  ///
  /// Retourne la liste des étapes préservées qu'on N'A PAS pu replacer
  /// automatiquement.
  Future<List<PreservedSegmentInfo>> applyTimelineDiff({
    required String tripId,
    required TripTimelineDiff diff,
  }) async {
    if (diff.isEmpty) return const [];
    // V5.4 — auto-placement aux dates d'origine. La date de référence
    // pour le calcul des cumuls dans le nouveau squelette = la date
    // effective d'arrivée (post-réalignement) ou la date courante.
    final tripStart = diff.effectiveTripStartDate ?? diff.currentTripStartDate;
    final autoPlaced = autoPlacePreservedSegments(
      skeleton: diff.mergedSegments,
      tripStartDate: tripStart,
      preserved: diff.preservedManual,
    );
    final segments = autoPlaced.placed;
    final leftovers = autoPlaced.leftovers;
    final updateMap = <String, dynamic>{
      'itinerary_segments': segments.map((s) => s.toJson()).toList(),
    };
    // V2 (Lalith 2026-05-09) — réaligne `start_date` sur la date
    // d'ARRIVÉE du premier vol quand celle-ci diffère du `trip.startDate`
    // courant. Sans ça, la cascade cumulative des segments
    // (`trip.startDate + sum(days)`) produit Bangkok au 21/06 alors que
    // l'utilisateur arrive vraiment le 22/06 — d'où le warning
    // `segmentArrivalMismatch`.
    if (diff.tripStartDateNeedsUpdate) {
      final eff = diff.effectiveTripStartDate!;
      updateMap['start_date'] = '${eff.year.toString().padLeft(4, '0')}-'
          '${eff.month.toString().padLeft(2, '0')}-'
          '${eff.day.toString().padLeft(2, '0')}';
    }
    try {
      await _client.from('trips').update(updateMap).eq('id', tripId);
      // V4 (Lalith 2026-05-10) — quand l'itinéraire est ré-écrit depuis
      // les documents, les activités GÉNÉRÉES par Lunao deviennent
      // stale (mauvaises villes / mauvais jours). On les supprime.
      // Préservées : activités utilisateur + imports de documents.
      final clearedActivities =
          await clearGeneratedActivitiesForTrip(_client, tripId);
      final autoPlacedCount =
          diff.preservedManual.length - leftovers.length;
      debugPrint('[trip-segment-sync] timeline appliquée — '
          '+${diff.added.length} ajout, ${diff.updated.length} maj, '
          '${diff.removed.length} retrait, '
          '${diff.preservedManual.length} étape(s) préservée(s) '
          '($autoPlacedCount replacée(s) auto, ${leftovers.length} restantes)'
          '${diff.tripStartDateNeedsUpdate ? ' + start_date réalignée' : ''}'
          '${clearedActivities > 0 ? ' + $clearedActivities activité(s) générée(s) supprimée(s)' : ''}');
    } catch (e) {
      debugPrint('[trip-segment-sync] update error : $e');
      // En cas d'échec d'écriture, on retourne quand même les leftovers
      // calculés (au moins l'utilisateur peut tenter un re-apply).
    }
    return leftovers;
  }

  // ─── compute diff ──────────────────────────────────────────────────────

  TripTimelineDiff _computeDiff({
    required Trip trip,
    required List<FlightStayCandidate> timeline,
  }) =>
      debugComputeDiff(trip: trip, timeline: timeline);

  /// V4 (Lalith 2026-05-10) — logique pure exposée pour tester la
  /// régression « Mettre à jour mon voyage corrompt l'ordre » sans
  /// instancier de `SupabaseClient`. Pas d'I/O.
  @visibleForTesting
  static TripTimelineDiff debugComputeDiff({
    required Trip trip,
    required List<FlightStayCandidate> timeline,
  }) {
    final existing = trip.itinerarySegments;

    // Set des villes mentionnées dans les vols (pour distinguer manuel vs
    // auto-seed). On garde aussi `from_city` pour la détection : une étape
    // manuelle "Ayutthaya" ajoutée à la main n'apparaît dans AUCUN to_city
    // ni from_city des docs Vol/Train du voyage. À l'inverse, "Bangkok"
    // apparaît dans plusieurs vols → l'étape Bangkok est "présente dans
    // les vols" et donc remplaçable.
    final flightCities = <String>{};
    for (final s in timeline) {
      flightCities.add(_normalize(s.city));
    }

    // Étapes manuelles : ville absente de tous les séjours déduits → on
    // les préserve telles quelles, à leur position courante.
    // V5.4 (Lalith 2026-05-10) — on capture les DATES D'ORIGINE de
    // chaque étape préservée pour permettre l'auto-placement aux mêmes
    // dates dans le nouveau squelette (cf. `autoPlacePreservedSegments`).
    final preservedManual = <PreservedSegmentInfo>[];
    final removed = <TripSegment>[];
    var origOffset = 0;
    for (var i = 0; i < existing.length; i++) {
      final seg = existing[i];
      final norm = _normalize(seg.city);
      if (flightCities.contains(norm)) {
        // Cette étape sera remplacée par les séjours déduits → "removed"
        // au sens "supprimé tel quel" mais probablement re-créé via le
        // diff updated/added (la fusion finale gère).
        removed.add(seg);
      } else {
        final segStart = trip.startDate.add(Duration(days: origOffset));
        final segEnd =
            trip.startDate.add(Duration(days: origOffset + seg.days));
        preservedManual.add(PreservedSegmentInfo(
          city: seg.city,
          country: seg.country,
          days: seg.days,
          startDate: segStart,
          endDateExclusive: segEnd,
          originalIndex: i,
          source: (seg.sourceAnchorCity?.trim().isNotEmpty ?? false)
              ? PreservedSegmentSource.windowLinked
              : PreservedSegmentSource.manual,
          sourceAnchorCity: seg.sourceAnchorCity,
        ));
      }
      origOffset += seg.days;
    }

    // Convertit chaque séjour déduit en TripSegment.
    final addedSegments = <TripSegment>[];
    for (final s in timeline) {
      addedSegments.add(TripSegment(
        city: s.city,
        days: s.days,
        country: s.country ?? trip.destinationCountryName,
        latitude: s.latitude,
        longitude: s.longitude,
      ));
    }

    // Distingue "added" (nouvelle ville) vs "updated" (ville déjà présente
    // mais avec une durée différente).
    final added = <TripSegment>[];
    final updated = <UpdatedSegment>[];
    final existingByNormCity = <String, TripSegment>{};
    for (final s in existing) {
      existingByNormCity.putIfAbsent(_normalize(s.city), () => s);
    }
    for (final s in addedSegments) {
      final norm = _normalize(s.city);
      final prev = existingByNormCity[norm];
      if (prev == null) {
        added.add(s);
      } else {
        updated.add(UpdatedSegment(
          before: prev,
          after: s,
        ));
      }
    }

    // Warnings : 2 séjours dans la même ville (split), couverture partielle...
    final warnings = <String>[];
    final cityCounts = <String, int>{};
    for (final s in addedSegments) {
      final n = _normalize(s.city);
      cityCounts[n] = (cityCounts[n] ?? 0) + 1;
    }
    cityCounts.forEach((city, count) {
      if (count > 1) {
        final original = addedSegments
            .firstWhere((s) => _normalize(s.city) == city)
            .city;
        warnings.add(
          '$original sera automatiquement séparé en $count séjours, '
          'car $count passages ont été détectés dans tes vols.',
        );
      }
    });

    // V4 (Lalith 2026-05-10) — fix critique : NE PAS concaténer
    // aveuglément `addedSegments + preservedManual`. C'était la source du
    // bug "65 jours placés pour un voyage de 46 jours" — le merge naïf
    // appendait toutes les étapes manuelles APRÈS le squelette doc-derived
    // sans vérifier la capacité, créant un drift cumulatif et explosant la
    // durée totale.
    //
    // Stratégie conservative : le squelette doc-derived est SOURCE DE
    // VÉRITÉ et est appliqué seul. Les étapes manuelles préservées sont
    // SURFACE'ES dans la sheet (`preservedManual`) et dans un warning,
    // mais NE sont PAS ré-insérées automatiquement. L'utilisateur peut
    // les recréer via « Affiner les étapes » qui a déjà la logique de
    // placement window-aware (`itinerary_mutation.dart`).
    //
    // Trade-off accepté avec Lalith : préférable à un itinéraire corrompu.
    final docTotalDays =
        addedSegments.fold<int>(0, (acc, s) => acc + s.days);
    if (docTotalDays > trip.durationDays) {
      warnings.add(
        'La durée totale des étapes déduites ($docTotalDays jours) '
        'dépasse la durée du voyage (${trip.durationDays} jours). '
        'Vérifie tes documents.',
      );
    }
    if (preservedManual.isNotEmpty) {
      final cities = preservedManual.map((m) => m.city).join(', ');
      final n = preservedManual.length;
      final pluralS = n > 1 ? 's' : '';
      final pluralVerb = n > 1 ? 'seront pas réinsérées' : 'sera pas réinsérée';
      warnings.add(
        '$n étape$pluralS manuelle$pluralS ($cities) ne $pluralVerb '
        'automatiquement. Tu pourras ${n > 1 ? "les" : "l'"}ajouter '
        'via « Affiner les étapes » dans le voyage.',
      );
    }

    // Liste finale = squelette doc-derived UNIQUEMENT. Les manuels
    // sont visibles via `preservedManual` côté UI — pas dans le voyage.
    final mergedSegments = <TripSegment>[...addedSegments];

    return TripTimelineDiff(
      added: added,
      updated: updated,
      removed: removed,
      preservedManual: preservedManual,
      warnings: warnings,
      timeline: timeline,
      mergedSegments: mergedSegments,
      tripDestination: trip.destination,
      tripDurationDays: trip.durationDays,
      currentTripStartDate: trip.startDate,
    );
  }

  static String _normalize(String s) {
    return s
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[àâä]'), 'a')
        .replaceAll(RegExp(r'[ïî]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ûü]'), 'u')
        .replaceAll('ç', 'c');
  }
}

/// Diff prévisualisable entre l'état actuel des segments d'un voyage et la
/// timeline déduite des vols.
class TripTimelineDiff {
  /// Séjours déduits qui ne sont pas dans les segments actuels (nouvelle
  /// ville).
  final List<TripSegment> added;

  /// Segments existants dont la ville est aussi dans la timeline mais avec
  /// une durée différente — ils seront remplacés.
  final List<UpdatedSegment> updated;

  /// Segments existants dont la ville apparaît dans les vols et qui seront
  /// remplacés par les séjours déduits (potentiellement plusieurs séjours
  /// pour la même ville si elle est visitée plusieurs fois).
  final List<TripSegment> removed;

  /// Étapes existantes qui n'apparaissent dans AUCUN vol — préservées
  /// telles quelles (ce sont des étapes manuelles ou window-linked).
  /// V5.4 (Lalith 2026-05-10) — type enrichi : on capture les dates
  /// d'origine pour permettre l'auto-placement aux mêmes dates dans le
  /// nouveau squelette doc-derived au moment de l'apply.
  final List<PreservedSegmentInfo> preservedManual;

  /// Messages informatifs pour l'utilisateur ("Bangkok sera découpé en 2
  /// séjours", "Durée totale dépasse le voyage"...).
  final List<String> warnings;

  /// Timeline brute issue du builder (séjours avec startDate/endDate).
  /// Utile pour l'affichage UX des dates dans la sheet preview.
  final List<FlightStayCandidate> timeline;

  /// Liste finale des segments du voyage si le diff est appliqué.
  final List<TripSegment> mergedSegments;

  /// Destination du voyage (pour le titre de la sheet).
  final String tripDestination;

  /// Durée totale du voyage (pour les warnings).
  final int tripDurationDays;

  /// V2 (Lalith 2026-05-09) — date de début actuelle du voyage (= la
  /// `Trip.startDate` au moment où le diff a été calculé). Permet de
  /// détecter si le voyage doit être réaligné sur la date d'ARRIVÉE
  /// du premier vol. Cas typique du bug : `trip.startDate = 21/06`
  /// (= jour de départ de Luxembourg) alors que l'arrivée à Bangkok
  /// est le 22/06 → segments cumulatifs décalés d'un jour.
  final DateTime currentTripStartDate;

  const TripTimelineDiff({
    required this.added,
    required this.updated,
    required this.removed,
    required this.preservedManual,
    required this.warnings,
    required this.timeline,
    required this.mergedSegments,
    required this.tripDestination,
    required this.tripDurationDays,
    required this.currentTripStartDate,
  });

  /// V2 (2026-05-09) — date effective de début de voyage selon les
  /// transports : date d'arrivée du PREMIER vol détecté. Null si la
  /// timeline est vide.
  DateTime? get effectiveTripStartDate =>
      timeline.isEmpty ? null : timeline.first.startDate;

  /// V2 (2026-05-09) — vrai si la `start_date` du voyage doit être
  /// mise à jour pour s'aligner sur l'arrivée réelle du premier vol.
  /// Comparaison date-only (ignore l'heure). Faux quand timeline vide
  /// ou quand les dates coïncident déjà.
  bool get tripStartDateNeedsUpdate {
    final eff = effectiveTripStartDate;
    if (eff == null) return false;
    final cur = currentTripStartDate;
    return eff.year != cur.year ||
        eff.month != cur.month ||
        eff.day != cur.day;
  }

  /// True si le diff ne propose aucun changement (rien à appliquer).
  /// V2 (2026-05-09) : factorise aussi le besoin de réaligner
  /// `trip.startDate` — si segments OK mais start_date décalée, le
  /// diff reste applicable.
  bool get isEmpty =>
      added.isEmpty &&
      updated.isEmpty &&
      removed.isEmpty &&
      !tripStartDateNeedsUpdate;

  /// True s'il y a quelque chose à montrer à l'utilisateur.
  bool get hasChanges => !isEmpty;
}

/// Représente un segment dont la durée change (même ville, autre nb de jours).
class UpdatedSegment {
  final TripSegment before;
  final TripSegment after;
  UpdatedSegment({required this.before, required this.after});
}
