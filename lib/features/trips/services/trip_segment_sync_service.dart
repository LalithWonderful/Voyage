import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Synchronise les étapes d'un voyage à partir de ses docs Vol/Train.
///
/// V2 (2026-05-07) : la découverte est séparée de l'insertion. La méthode
/// publique [findCandidatesFromTransportDocs] retourne les villes candidates
/// SANS les insérer — l'UI ouvre une sheet de validation. La méthode
/// [applyCandidates] insère uniquement les villes que l'utilisateur a cochées.
/// La méthode legacy [syncFromTransportDocs] (auto-insert) est conservée
/// pour compat mais ne devrait plus être appelée.
///
/// Logique de découverte :
/// - Lit les docs Vol/Train du voyage, triés par date.
/// - Pour chaque endpoint (`from`/`to`), produit un candidat.
/// - **Filtre pays adaptatif** :
///   - `destination_kind = 'city'` → filtre strict (mêmes pays que la destination)
///   - `destination_kind = 'country'`/`'region'` → pas de filtre pays
///     (un voyage "Thaïlande" peut inclure des extensions Vietnam/Tokyo)
///   - destination_kind absent → fallback strict pays (sécurité)
/// - Suggestion par défaut (`suggestedByDefault`) : true si même pays que la
///   destination (haute confiance), false sinon — l'UI coche en conséquence.
/// - Dédoublonne avec les segments existants (city normalisé OU haversine
///   < 30 km).
class TripSegmentSyncService {
  final SupabaseClient _client;

  TripSegmentSyncService(this._client);

  /// Découverte sans insertion : retourne la liste des villes candidates
  /// trouvées dans les docs Vol/Train du voyage. L'UI peut ensuite proposer
  /// une sheet de validation à l'utilisateur.
  Future<List<SegmentCandidate>> findCandidatesFromTransportDocs(
    String tripId,
  ) async {
    final tripRow =
        await _client.from('trips').select().eq('id', tripId).maybeSingle();
    if (tripRow == null) return const [];
    final trip = Trip.fromJson(tripRow);

    final docsRows = await _client
        .from('trip_documents')
        .select()
        .eq('trip_id', tripId)
        .inFilter('category', [DocumentCategory.flight, DocumentCategory.train]);
    final docs = (docsRows as List)
        .map((d) => TripDocument.fromJson(d as Map<String, dynamic>))
        .toList();
    if (docs.isEmpty) return const [];

    // Tri par date.
    final sortedDocs = docs.where((d) {
      final raw = d.metadata['date'] as String?;
      return raw != null && raw.isNotEmpty && DateTime.tryParse(raw) != null;
    }).toList()
      ..sort((a, b) {
        final ad = DateTime.parse(a.metadata['date'] as String);
        final bd = DateTime.parse(b.metadata['date'] as String);
        return ad.compareTo(bd);
      });
    if (sortedDocs.isEmpty) return const [];

    final tripCountry = trip.destinationCountryCode?.trim().toLowerCase();
    final hasTripCountry = tripCountry != null && tripCountry.isNotEmpty;
    // V2 : assouplit le filtre pour les voyages multi-pays explicites.
    // 'country' / 'region' : un voyage "Thaïlande" peut inclure une extension
    // Vietnam, Tokyo, etc. — on ne filtre pas. 'city' : on garde strict.
    final filterByCountry = trip.destinationKind == 'city' || trip.destinationKind == null;

    // 1. Extraction brute des candidats.
    final raw = <_RawCandidate>[];
    for (final doc in sortedDocs) {
      final docDate = DateTime.parse(doc.metadata['date'] as String);
      _appendRaw(
        meta: doc.metadata,
        prefix: 'from',
        date: docDate,
        docName: doc.name,
        out: raw,
      );
      _appendRaw(
        meta: doc.metadata,
        prefix: 'to',
        date: docDate,
        docName: doc.name,
        out: raw,
      );
    }
    if (raw.isEmpty) return const [];

    // 2. Dédoublonne avec les segments existants + entre candidats. Pour
    // chaque ville on garde la PREMIÈRE occurrence (atDate la plus tôt).
    final existing = trip.itinerarySegments;
    final seenNorms = <String>{};
    final candidates = <SegmentCandidate>[];
    for (final c in raw) {
      final norm = _normalize(c.city);
      if (seenNorms.contains(norm)) continue;
      if (_existsInSegments(existing, c)) continue;

      // Filtrage pays (uniquement pour kind=city).
      if (filterByCountry && hasTripCountry) {
        if (c.countryCode == null || c.countryCode!.toLowerCase() != tripCountry) {
          continue;
        }
      }

      // Suggestion par défaut : cochée si même pays (haute confiance), sinon
      // décochée (l'utilisateur valide explicitement les extensions).
      final sameCountry = hasTripCountry &&
          c.countryCode != null &&
          c.countryCode!.toLowerCase() == tripCountry;
      final suggested = !hasTripCountry || sameCountry;

      candidates.add(SegmentCandidate(
        city: c.city,
        country: _countryNameFromCode(c.countryCode),
        countryCode: c.countryCode,
        latitude: c.lat,
        longitude: c.lng,
        atDate: c.atDate,
        sourceDocName: c.docName,
        suggestedByDefault: suggested,
      ));
      seenNorms.add(norm);
    }
    return candidates;
  }

  /// Applique les candidats sélectionnés par l'utilisateur : calcule les
  /// jours, insère chacun à sa position chronologique, persiste.
  /// Retourne la liste des nouvelles étapes effectivement insérées.
  Future<List<TripSegment>> applyCandidates(
    String tripId,
    List<SegmentCandidate> selected,
  ) async {
    if (selected.isEmpty) return const [];

    final tripRow =
        await _client.from('trips').select().eq('id', tripId).maybeSingle();
    if (tripRow == null) return const [];
    final trip = Trip.fromJson(tripRow);

    // Re-fetch les docs pour calculer correctement les `days`.
    final docsRows = await _client
        .from('trip_documents')
        .select()
        .eq('trip_id', tripId)
        .inFilter('category', [DocumentCategory.flight, DocumentCategory.train]);
    final docs = (docsRows as List)
        .map((d) => TripDocument.fromJson(d as Map<String, dynamic>))
        .toList();
    final sortedDocs = docs.where((d) {
      final raw = d.metadata['date'] as String?;
      return raw != null && raw.isNotEmpty && DateTime.tryParse(raw) != null;
    }).toList()
      ..sort((a, b) {
        final ad = DateTime.parse(a.metadata['date'] as String);
        final bd = DateTime.parse(b.metadata['date'] as String);
        return ad.compareTo(bd);
      });

    // Calcul des `days` + construction des nouveaux segments.
    final newSegments = <TripSegment>[];
    final positions = <DateTime>[];
    for (final c in selected) {
      final days = _computeDays(c, sortedDocs, trip);
      newSegments.add(TripSegment(
        city: c.city,
        days: days,
        country: c.country ?? trip.destinationCountryName,
        latitude: c.latitude,
        longitude: c.longitude,
      ));
      positions.add(c.atDate);
    }

    // Insertion chronologique (existants + nouveaux triés par date).
    final positioned = <_Positioned>[];
    final existing = trip.itinerarySegments;
    for (var i = 0; i < existing.length; i++) {
      positioned.add(_Positioned(
        segment: existing[i],
        date: trip.segmentStart(i),
      ));
    }
    for (var i = 0; i < newSegments.length; i++) {
      positioned.add(_Positioned(
        segment: newSegments[i],
        date: positions[i],
      ));
    }
    positioned.sort((a, b) => a.date.compareTo(b.date));
    final mergedSegments = positioned.map((p) => p.segment).toList();

    try {
      await _client.from('trips').update({
        'itinerary_segments':
            mergedSegments.map((s) => s.toJson()).toList(),
      }).eq('id', tripId);
      debugPrint('[trip-segment-sync] +${newSegments.length} étape(s) '
          'ajoutée(s) au voyage $tripId : '
          '${newSegments.map((s) => s.city).join(', ')}');
    } catch (e) {
      debugPrint('[trip-segment-sync] update error : $e');
      return const [];
    }
    return newSegments;
  }

  /// Legacy : auto-insertion sans validation user. Conservée pour compat
  /// mais ne devrait plus être appelée — préférer le couple
  /// findCandidatesFromTransportDocs + applyCandidates.
  @Deprecated('Use findCandidatesFromTransportDocs + applyCandidates instead')
  Future<List<TripSegment>> syncFromTransportDocs(String tripId) async {
    final candidates = await findCandidatesFromTransportDocs(tripId);
    final autoSelected =
        candidates.where((c) => c.suggestedByDefault).toList();
    if (autoSelected.isEmpty) return const [];
    return applyCandidates(tripId, autoSelected);
  }

  // ─── helpers privés ────────────────────────────────────────────────────

  void _appendRaw({
    required Map<String, dynamic> meta,
    required String prefix,
    required DateTime date,
    required String docName,
    required List<_RawCandidate> out,
  }) {
    final city = (meta['${prefix}_city'] as String?)?.trim();
    if (city == null || city.isEmpty) return;
    final country = (meta['${prefix}_country_code'] as String?)?.trim();
    final lat = (meta['${prefix}_latitude'] as num?)?.toDouble();
    final lng = (meta['${prefix}_longitude'] as num?)?.toDouble();
    out.add(_RawCandidate(
      city: city,
      countryCode: country?.toLowerCase(),
      lat: lat,
      lng: lng,
      atDate: date,
      docName: docName,
    ));
  }

  String _normalize(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  bool _existsInSegments(List<TripSegment> segments, _RawCandidate c) {
    final norm = _normalize(c.city);
    for (final s in segments) {
      if (_normalize(s.city) == norm) return true;
      if (c.lat != null &&
          c.lng != null &&
          s.latitude != null &&
          s.longitude != null) {
        if (_haversineKm(c.lat!, c.lng!, s.latitude!, s.longitude!) < 30) {
          return true;
        }
      }
    }
    return false;
  }

  int _computeDays(
    SegmentCandidate c,
    List<TripDocument> sortedDocs,
    Trip trip,
  ) {
    final norm = _normalize(c.city);
    DateTime? departureDate;
    for (final doc in sortedDocs) {
      final fromCity = (doc.metadata['from_city'] as String?)?.trim() ?? '';
      if (fromCity.isEmpty) continue;
      if (_normalize(fromCity) != norm) continue;
      final raw = doc.metadata['date'] as String?;
      if (raw == null) continue;
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      if (d.isAfter(c.atDate)) {
        departureDate = d;
        break;
      }
    }
    final endRef = departureDate ?? trip.endDate;
    final endDay = DateTime(endRef.year, endRef.month, endRef.day);
    final startDay = DateTime(c.atDate.year, c.atDate.month, c.atDate.day);
    final diff = endDay.difference(startDay).inDays;
    return diff.clamp(1, trip.durationDays);
  }

  /// Mapping minimaliste code → nom pays pour affichage UX. Couvre les
  /// principaux pays de l'audience FR + destinations populaires. Fallback
  /// = code uppercased (ex: "VN" si pas mappé).
  String? _countryNameFromCode(String? code) {
    if (code == null || code.isEmpty) return null;
    const map = {
      'fr': 'France', 'be': 'Belgique', 'ch': 'Suisse', 'lu': 'Luxembourg',
      'it': 'Italie', 'es': 'Espagne', 'de': 'Allemagne', 'gb': 'Royaume-Uni',
      'nl': 'Pays-Bas', 'at': 'Autriche', 'pt': 'Portugal', 'ie': 'Irlande',
      'gr': 'Grèce', 'hr': 'Croatie', 'cz': 'République tchèque',
      'pl': 'Pologne', 'hu': 'Hongrie', 'tr': 'Turquie',
      'ma': 'Maroc', 'tn': 'Tunisie', 'dz': 'Algérie', 'eg': 'Égypte',
      'sn': 'Sénégal', 'za': 'Afrique du Sud', 'ke': 'Kenya',
      'th': 'Thaïlande', 'vn': 'Vietnam', 'kh': 'Cambodge', 'la': 'Laos',
      'mm': 'Birmanie', 'sg': 'Singapour', 'my': 'Malaisie', 'id': 'Indonésie',
      'ph': 'Philippines', 'jp': 'Japon', 'kr': 'Corée du Sud', 'cn': 'Chine',
      'in': 'Inde', 'ae': 'Émirats arabes unis', 'sa': 'Arabie saoudite',
      'us': 'États-Unis', 'ca': 'Canada', 'mx': 'Mexique',
      'br': 'Brésil', 'ar': 'Argentine', 'cl': 'Chili', 'pe': 'Pérou',
      'au': 'Australie', 'nz': 'Nouvelle-Zélande',
    };
    return map[code.toLowerCase()] ?? code.toUpperCase();
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    double toRad(double deg) => deg * (pi / 180);
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(toRad(lat1)) * cos(toRad(lat2)) *
            sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthKm * c;
  }
}

/// Candidat d'étape proposé à l'utilisateur dans la sheet de validation.
class SegmentCandidate {
  final String city;
  /// Nom pays humain (ex: "Vietnam") pour affichage UX. Null si non mappé.
  final String? country;
  /// Code ISO 2 lettres (ex: "vn"). Sert au filtrage/affichage drapeau.
  final String? countryCode;
  final double? latitude;
  final double? longitude;
  /// Date à laquelle le voyageur arrive dans cette ville (vol vers, ou
  /// départ depuis). Sert au tri chronologique et au calcul des jours.
  final DateTime atDate;
  /// Nom du doc qui a fait remonter cette ville (ex: "VN1236 Vietnam Airlines").
  /// Affiché en sous-titre dans la sheet pour aider l'utilisateur à recouper.
  final String sourceDocName;
  /// True = à cocher par défaut (même pays que la destination, haute
  /// confiance). False = à laisser décoché (extension hors pays principal).
  final bool suggestedByDefault;

  const SegmentCandidate({
    required this.city,
    required this.country,
    required this.countryCode,
    required this.latitude,
    required this.longitude,
    required this.atDate,
    required this.sourceDocName,
    required this.suggestedByDefault,
  });
}

class _RawCandidate {
  final String city;
  final String? countryCode;
  final double? lat;
  final double? lng;
  final DateTime atDate;
  final String docName;
  _RawCandidate({
    required this.city,
    required this.countryCode,
    required this.lat,
    required this.lng,
    required this.atDate,
    required this.docName,
  });
}

class _Positioned {
  final TripSegment segment;
  final DateTime date;
  _Positioned({required this.segment, required this.date});
}
