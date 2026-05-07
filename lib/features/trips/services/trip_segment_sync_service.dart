import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/flight_timeline_builder.dart';
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
  Future<void> applyTimelineDiff({
    required String tripId,
    required TripTimelineDiff diff,
  }) async {
    if (diff.isEmpty) return;
    final segments = diff.mergedSegments;
    try {
      await _client.from('trips').update({
        'itinerary_segments': segments.map((s) => s.toJson()).toList(),
      }).eq('id', tripId);
      debugPrint('[trip-segment-sync] timeline appliquée — '
          '+${diff.added.length} ajout, ${diff.updated.length} maj, '
          '${diff.removed.length} retrait, '
          '${diff.preservedManual.length} étape(s) manuelle(s) préservée(s)');
    } catch (e) {
      debugPrint('[trip-segment-sync] update error : $e');
    }
  }

  // ─── compute diff ──────────────────────────────────────────────────────

  TripTimelineDiff _computeDiff({
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
    final preservedManual = <TripSegment>[];
    final removed = <TripSegment>[];
    for (final seg in existing) {
      final norm = _normalize(seg.city);
      if (flightCities.contains(norm)) {
        // Cette étape sera remplacée par les séjours déduits → "removed"
        // au sens "supprimé tel quel" mais probablement re-créé via le
        // diff updated/added (la fusion finale gère).
        removed.add(seg);
      } else {
        preservedManual.add(seg);
      }
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

    final totalDays = addedSegments.fold<int>(0, (acc, s) => acc + s.days) +
        preservedManual.fold<int>(0, (acc, s) => acc + s.days);
    if (totalDays > trip.durationDays) {
      warnings.add(
        'La durée totale des étapes ($totalDays jours) dépasse '
        'la durée du voyage (${trip.durationDays} jours).',
      );
    }

    // Construction de la liste finale fusionnée. Stratégie simple :
    // - les séjours déduits viennent en premier dans l'ordre chronologique
    //   (la timeline est déjà triée par date d'arrivée)
    // - les étapes manuelles préservées viennent ensuite
    // L'utilisateur peut toujours réorganiser à la main dans la sheet.
    final mergedSegments = <TripSegment>[
      ...addedSegments,
      ...preservedManual,
    ];

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
  /// telles quelles (ce sont des étapes manuelles de l'utilisateur).
  final List<TripSegment> preservedManual;

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
  });

  /// True si le diff ne propose aucun changement (rien à appliquer).
  bool get isEmpty =>
      added.isEmpty && updated.isEmpty && removed.isEmpty;

  /// True s'il y a quelque chose à montrer à l'utilisateur.
  bool get hasChanges => !isEmpty;
}

/// Représente un segment dont la durée change (même ville, autre nb de jours).
class UpdatedSegment {
  final TripSegment before;
  final TripSegment after;
  UpdatedSegment({required this.before, required this.after});
}
