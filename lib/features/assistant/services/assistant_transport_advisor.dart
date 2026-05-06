import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Synthèse "départ & transport" pour un voyage donné. Sert à 2 usages :
/// 1. Afficher dans la carte "Contexte utilisé par Lunao" un texte adapté
///    ("Voiture ou train recommandé · avion non nécessaire" pour Metz)
///    plutôt que d'afficher systématiquement "Départ Paris CDG".
/// 2. Injecter un bloc CONTEXTE TRANSPORT dans le prompt Gemini pour
///    éviter qu'il conseille un vol quand l'avion n'est pas pertinent.
class TransportAdvice {
  /// Le texte UX prêt à afficher dans la carte. Toujours fourni.
  /// Ex: "Voiture ou train recommandé · avion non nécessaire"
  /// Ex: "Avion recommandé · départ Paris Charles de Gaulle — CDG"
  final String label;

  /// True si l'avion est l'option pertinente (long courrier, hors UE…).
  /// L'aéroport est alors mentionné dans le label.
  final bool isFlightRelevant;

  /// Distance approximative origine → destination, en km. Null si non
  /// estimable (destination sans coords dans nos tables).
  final double? estimatedDistanceKm;

  /// Code IATA de l'aéroport effectif pour ce voyage (override voyage,
  /// sinon profil, sinon fallback CDG).
  final String homeAirportIata;

  /// Raison courte injectée dans le prompt Gemini ("destination proche",
  /// "long-courrier", "même pays sous 500 km"…). Aide Gemini à comprendre
  /// le verdict.
  final String reason;

  const TransportAdvice({
    required this.label,
    required this.isFlightRelevant,
    required this.estimatedDistanceKm,
    required this.homeAirportIata,
    required this.reason,
  });

  /// Bloc texte prêt à injecter dans le system prompt Gemini.
  String toPromptBlock() {
    final buf = StringBuffer();
    buf.writeln('CONTEXTE TRANSPORT (calculé par Lunao)');
    buf.writeln('- Aéroport de départ par défaut : $homeAirportIata');
    if (estimatedDistanceKm != null) {
      buf.writeln('- Distance estimée origine → destination : '
          '~${estimatedDistanceKm!.round()} km');
    }
    buf.writeln('- Avion pertinent pour ce voyage : '
        '${isFlightRelevant ? "oui" : "non"} ($reason)');
    buf.writeln('- Recommandation à transmettre : $label');
    buf.writeln();
    buf.writeln('Si l\'avion n\'est pas pertinent (proximité, même pays sous '
        '500 km), ne propose pas de vol et ne mentionne pas l\'aéroport sauf '
        'si l\'utilisateur insiste. Privilégie train, voiture ou bus selon le '
        'contexte.');
    return buf.toString();
  }
}

class AssistantTransportAdvisor {
  /// Calcule la recommandation transport pour un voyage. Logique V1 simple :
  /// - Distance < 200 km → train/voiture, jamais avion
  /// - Même pays + distance < 500 km → train/voiture, pas avion
  /// - Distance > 900 km → avion recommandé
  /// - Entre les deux ou distance inconnue → laisser Lunao comparer
  ///
  /// V2 prendra en compte la préférence transport explicite (`preferred_
  /// transport_mode` à venir sur trip + profile).
  TransportAdvice compute({
    required Trip trip,
    required String? userHomeAirportFromProfile,
  }) {
    final homeIata = trip.homeAirportIata ??
        userHomeAirportFromProfile ??
        'CDG';

    final originCoords = coordsForAirport(homeIata);
    final destCoords = _findDestinationCoords(trip);

    double? distanceKm;
    if (originCoords != null && destCoords != null) {
      distanceKm = haversineKm(
        originCoords.lat,
        originCoords.lng,
        destCoords.lat,
        destCoords.lng,
      );
    }

    final originCountry = _countryCodeForAirport(homeIata);
    final destCountry = trip.destinationCountryCode?.toUpperCase();
    final sameCountry = originCountry != null &&
        destCountry != null &&
        originCountry == destCountry;

    // ─── Scoring ──────────────────────────────────────────────────────
    bool isFlightRelevant;
    String reason;

    if (distanceKm != null && distanceKm < 200) {
      isFlightRelevant = false;
      reason = 'destination proche (~${distanceKm.round()} km)';
    } else if (sameCountry && distanceKm != null && distanceKm < 500) {
      isFlightRelevant = false;
      reason = 'même pays, ~${distanceKm.round()} km';
    } else if (distanceKm != null && distanceKm > 900) {
      isFlightRelevant = true;
      reason = 'long-courrier (~${distanceKm.round()} km)';
    } else if (distanceKm != null) {
      // 200-900 km hors même-pays-court : ambigu, laissons Lunao comparer
      isFlightRelevant = false;
      reason = 'distance moyenne (~${distanceKm.round()} km)';
    } else if (sameCountry) {
      isFlightRelevant = false;
      reason = 'même pays';
    } else {
      // Pays différent + distance inconnue → on présume avion
      isFlightRelevant = true;
      reason = 'pays différent, distance non estimable';
    }

    // ─── Label UX ─────────────────────────────────────────────────────
    final airportDisplay = _formatAirport(homeIata);
    String label;
    if (!isFlightRelevant) {
      if (distanceKm != null && distanceKm < 200) {
        label = 'Voiture ou train recommandé · avion non nécessaire';
      } else if (sameCountry && (distanceKm == null || distanceKm < 500)) {
        label = 'Train ou voiture recommandé · avion non nécessaire';
      } else if (distanceKm != null && distanceKm <= 900) {
        label = 'Lunao comparera train, voiture et avion selon ton budget';
      } else {
        label = 'Train ou voiture recommandé';
      }
    } else {
      label = 'Avion recommandé · départ $airportDisplay';
    }

    return TransportAdvice(
      label: label,
      isFlightRelevant: isFlightRelevant,
      estimatedDistanceKm: distanceKm,
      homeAirportIata: homeIata,
      reason: reason,
    );
  }

  /// Récupère des coords pour la destination du voyage. Stratégie :
  /// 1. Premier segment d'itinéraire avec lat/lng renseigné
  /// 2. Sinon, lookup dans la table d'aéroports par nom de ville
  /// 3. Sinon null
  ({double lat, double lng})? _findDestinationCoords(Trip trip) {
    if (trip.itinerarySegments.isNotEmpty) {
      final first = trip.itinerarySegments.first;
      if (first.latitude != null && first.longitude != null) {
        return (lat: first.latitude!, lng: first.longitude!);
      }
    }
    return coordsForCity(trip.destination);
  }

  /// Heuristique pour déduire le code pays ISO 2 lettres d'un aéroport
  /// IATA. Couvre les cas FR principaux (audience cible) et quelques
  /// hubs Europe. Fallback null pour ne pas se tromper. À étendre au fil
  /// de l'eau (ou à intégrer comme champ dans `_AirportInfo`).
  String? _countryCodeForAirport(String iata) {
    const fr = {
      'CDG', 'ORY', 'BVA', 'NCE', 'LYS', 'MRS', 'TLS', 'BOD', 'NTE',
      'MPL', 'SXB', 'LIL', 'BES', 'RNS', 'AJA', 'BIA', 'FSC', 'CLY',
      'PTP', 'FDF', 'RUN', 'DZA', 'PPT', 'NOU', 'CAY', 'SXM',
    };
    const be = {'BRU', 'CRL', 'ANR'};
    const ch = {'GVA', 'ZRH', 'BSL'};
    const lu = {'LUX'};
    const it = {'FCO', 'CIA', 'MXP', 'LIN', 'BLQ', 'VCE', 'NAP', 'CTA', 'PMO', 'BRI'};
    const es = {'BCN', 'MAD', 'AGP', 'PMI', 'IBZ', 'TFS', 'TFN', 'LPA', 'VLC', 'SVQ', 'BIO'};
    const de = {'FRA', 'MUC', 'BER', 'HAM', 'DUS', 'CGN', 'STR', 'SCN'};
    const uk = {'LHR', 'LGW', 'STN', 'LTN', 'LCY', 'MAN', 'EDI', 'BHX', 'GLA', 'BRS'};
    const nl = {'AMS', 'RTM', 'EIN'};

    if (fr.contains(iata)) return 'FR';
    if (be.contains(iata)) return 'BE';
    if (ch.contains(iata)) return 'CH';
    if (lu.contains(iata)) return 'LU';
    if (it.contains(iata)) return 'IT';
    if (es.contains(iata)) return 'ES';
    if (de.contains(iata)) return 'DE';
    if (uk.contains(iata)) return 'GB';
    if (nl.contains(iata)) return 'NL';
    return null;
  }

  String _formatAirport(String iata) {
    final lookup = lookupAirport(iata);
    if (lookup == null) return iata;
    if (lookup.name != null && lookup.name!.isNotEmpty) {
      return '${lookup.city} ${lookup.name} — ${lookup.iata}';
    }
    return '${lookup.city} — ${lookup.iata}';
  }
}
