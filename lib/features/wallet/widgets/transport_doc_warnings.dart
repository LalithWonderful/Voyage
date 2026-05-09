import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Affiche les warnings UX pour un document Vol ou Train. Bienveillant
/// (couleur ambre, pas erreur), info-rich. Cohérent avec `HotelDocWarnings`.
///
/// Cas signalés :
/// - **Date manquante** : sans `date`, le vol/train n'apparaît pas dans la
///   timeline.
/// - **Date hors plage du voyage** : si `trip` fourni et que la date est
///   hors `[trip.startDate, trip.endDate]`. Non bloquant (vols long-haul
///   avec longues escales sont légitimes), juste un nudge visuel.
/// - **Horaires manquants** : `departure_time` ou `arrival_time` absents.
///   Pénalise le rendu (heure 00:00) + empêche le pipeline trajets de
///   séquencer correctement.
/// - **Aéroport / gare introuvable** : `from_geocoding_failed` ou
///   `to_geocoding_failed` posés au save par le form. Pas de coords donc
///   bouton Itinéraire dégradé.
///
/// `SizedBox.shrink` si rien à signaler — safe à inclure inconditionnellement.
class TransportDocWarnings extends StatelessWidget {
  final TripDocument doc;
  final Trip? trip;
  final double fontSize;
  const TransportDocWarnings({
    super.key,
    required this.doc,
    this.trip,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    if (doc.category != DocumentCategory.flight &&
        doc.category != DocumentCategory.train) {
      return const SizedBox.shrink();
    }
    final m = doc.metadata;
    final missingDate = m['date'] == null || (m['date'] as String).isEmpty;
    final missingTimes = (m['departure_time'] == null ||
            (m['departure_time'] as String).isEmpty) ||
        (m['arrival_time'] == null || (m['arrival_time'] as String).isEmpty);
    final missingFrom = (m['from'] as String?)?.trim().isEmpty ?? true;
    final missingTo = (m['to'] as String?)?.trim().isEmpty ?? true;
    final fromGeocodingFailed = m['from_geocoding_failed'] == true;
    final toGeocodingFailed = m['to_geocoding_failed'] == true;

    // V5.1 (Lalith bug fix 2026-05-10 — Issue 2) — validation par
    // INTERVALLE de transport, pas par date unique. Un vol aller
    // décolle souvent la veille de l'arrivée à destination (LUX→BKK
    // 21/06 → 22/06). Si `trip.startDate` a été réaligné sur l'arrivée
    // (= 22/06), le départ 21/06 ne doit PAS déclencher le warning :
    // l'intervalle [21/06, 22/06] chevauche le voyage [22/06, 06/08].
    // Idem pour le retour BKK→LUX 06/08 → 07/08 vs trip [22/06, 06/08].
    bool dateOutOfRange = false;
    if (!missingDate && trip != null && trip!.hasExactDates) {
      final dep = DateTime.tryParse(m['date'] as String);
      final arrRaw = m['arrival_date'] as String?;
      final arr = arrRaw != null ? DateTime.tryParse(arrRaw) : null;
      if (dep != null) {
        final depDay = DateTime(dep.year, dep.month, dep.day);
        final arrDay = arr != null
            ? DateTime(arr.year, arr.month, arr.day)
            : depDay;
        final tripStart = DateTime(trip!.startDate.year,
            trip!.startDate.month, trip!.startDate.day);
        final tripEnd = DateTime(
            trip!.endDate.year, trip!.endDate.month, trip!.endDate.day);
        // No-overlap si l'intervalle est entièrement avant `tripStart`
        // OU entièrement après `tripEnd`. Toute autre situation = OK.
        dateOutOfRange =
            arrDay.isBefore(tripStart) || depDay.isAfter(tripEnd);
      }
    }

    // V5.1 (Lalith bug fix 2026-05-10 — Issue 1) — détection
    // « hors voyage » par MATCHING DE VILLES, pas par code pays. Un
    // voyage Thaïlande peut avoir des étapes Vietnam, Laos, etc. dans
    // ses segments, donc un vol Phú Quốc→Hanoï est légitime même si
    // le code pays VN ≠ TH. Règle : si l'endpoint matche une ville de
    // segment ou un `sourceAnchorCity`, le transport est légitime.
    // On flag seulement si AUCUN endpoint ne matche.
    bool foreignTransport = false;
    if (trip != null) {
      final tripCities = <String>{};
      for (final s in trip!.itinerarySegments) {
        tripCities.add(_normalizeCityName(s.city));
        final src = s.sourceAnchorCity?.trim();
        if (src != null && src.isNotEmpty) {
          tripCities.add(_normalizeCityName(src));
        }
      }
      // La destination principale du voyage compte aussi (segment de
      // tête type « Bangkok, Thaïlande »).
      final dest = trip!.destination.trim();
      if (dest.isNotEmpty) {
        final firstWord = dest.contains(',')
            ? dest.split(',').first.trim()
            : dest;
        if (firstWord.isNotEmpty) {
          tripCities.add(_normalizeCityName(firstWord));
        }
      }
      if (tripCities.isNotEmpty) {
        final from = (m['from_city'] as String?)?.trim() ??
            (m['from'] as String?)?.trim() ??
            '';
        final to = (m['to_city'] as String?)?.trim() ??
            (m['to'] as String?)?.trim() ??
            '';
        bool matches(String s) {
          if (s.isEmpty) return false;
          return tripCities.contains(_normalizeCityName(s));
        }
        // « hors voyage » uniquement si aucun des deux endpoints ne
        // matche : un vol home → destination matche au moins par sa
        // ville d'arrivée (= légitime). Idem retour.
        foreignTransport = !matches(from) && !matches(to);
        // Sécurité : si on n'a NI from NI to, on s'abstient (ancien
        // cache / fallback). Pas de faux positif.
        if (from.isEmpty && to.isEmpty) foreignTransport = false;
      }
    }

    final hasAny = missingDate ||
        missingTimes ||
        missingFrom ||
        missingTo ||
        fromGeocodingFailed ||
        toGeocodingFailed ||
        dateOutOfRange ||
        foreignTransport;
    if (!hasAny) return const SizedBox.shrink();

    final isFlight = doc.category == DocumentCategory.flight;
    final fromMissingLabel = isFlight ? 'Aéroport de départ manquant' : 'Gare de départ manquante';
    final toMissingLabel = isFlight ? 'Aéroport d\'arrivée manquant' : 'Gare d\'arrivée manquante';
    final fromUnknownLabel = isFlight ? 'Aéroport de départ introuvable' : 'Gare de départ introuvable';
    final toUnknownLabel = isFlight ? 'Aéroport d\'arrivée introuvable' : 'Gare d\'arrivée introuvable';
    final foreignLabel = isFlight ? 'Vol hors du pays du voyage' : 'Trajet hors du pays du voyage';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (missingDate) ...[
          const SizedBox(height: 4),
          _row('Date manquante'),
        ],
        if (dateOutOfRange) ...[
          const SizedBox(height: 4),
          _row('Date hors plage du voyage'),
        ],
        if (missingTimes && !missingDate) ...[
          const SizedBox(height: 4),
          _row('Horaires manquants'),
        ],
        // Distingue "vide" (rien tapé) de "introuvable" (tapé mais pas géocodé) :
        // 2 cas distincts qui ne peuvent pas survenir en même temps (le code
        // form efface le flag failed quand le champ est vidé).
        if (missingFrom) ...[
          const SizedBox(height: 4),
          _row(fromMissingLabel),
        ] else if (fromGeocodingFailed) ...[
          const SizedBox(height: 4),
          _row(fromUnknownLabel),
        ],
        if (missingTo) ...[
          const SizedBox(height: 4),
          _row(toMissingLabel),
        ] else if (toGeocodingFailed) ...[
          const SizedBox(height: 4),
          _row(toUnknownLabel),
        ],
        if (foreignTransport) ...[
          const SizedBox(height: 4),
          _row(foreignLabel),
        ],
      ],
    );
  }

  /// Normalisation locale (lowercase + accent strip) cohérente avec
  /// `pinned_dates._normalize` et `trip_edit_sheet._normalizeCityName`.
  /// Dupliquée ici pour éviter une dépendance croisée juste pour le
  /// comparateur de villes.
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

  Widget _row(String message) {
    return Row(
      children: [
        Icon(Icons.warning_amber_rounded, size: fontSize + 1, color: AppColors.accent),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: fontSize, color: AppColors.accent, fontWeight: FontWeight.w500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
