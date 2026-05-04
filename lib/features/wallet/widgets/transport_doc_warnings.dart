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

    bool dateOutOfRange = false;
    // Skippé pour les voyages sans dates exactes (mois cible / unspecified /
    // recommended) : les bornes sont synthétiques, le warning serait trompeur.
    if (!missingDate && trip != null && trip!.hasExactDates) {
      final docDate = DateTime.tryParse(m['date'] as String);
      if (docDate != null) {
        final docDay = DateTime(docDate.year, docDate.month, docDate.day);
        final tripStart = DateTime(trip!.startDate.year, trip!.startDate.month, trip!.startDate.day);
        final tripEnd = DateTime(trip!.endDate.year, trip!.endDate.month, trip!.endDate.day);
        dateOutOfRange = docDay.isBefore(tripStart) || docDay.isAfter(tripEnd);
      }
    }

    // "Vol/Train hors du pays du voyage" : on alerte SEULEMENT si les 2
    // endpoints sont dans un même pays ≠ destination du voyage. Pour les
    // vols internationaux légitimes (ex: Paris→Tokyo dans voyage Japon =
    // CDG-FR + NRT-JP), un seul endpoint est hors → pas de warning.
    // Si on n'a pas l'info pays sur l'un des 2 (ancien cache, fallback
    // Geocoding texte), on s'abstient pour ne pas faire de faux positif.
    bool foreignTransport = false;
    final tripCountry = trip?.destinationCountryCode?.trim().toLowerCase();
    if (tripCountry != null && tripCountry.isNotEmpty) {
      final fromCountry = (m['from_country_code'] as String?)?.trim().toLowerCase();
      final toCountry = (m['to_country_code'] as String?)?.trim().toLowerCase();
      if (fromCountry != null && fromCountry.isNotEmpty &&
          toCountry != null && toCountry.isNotEmpty) {
        foreignTransport = fromCountry == toCountry && fromCountry != tripCountry;
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
