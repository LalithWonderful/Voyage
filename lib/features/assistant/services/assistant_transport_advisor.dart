import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Synthèse "départ & transport" en 2 niveaux distincts (arrival + local) —
/// V2 alignée sur le retour Lalith : la préférence "transports en commun"
/// pour la Thaïlande veut dire BTS/MRT à Bangkok, pas un bus 12h pour
/// Bangkok → Krabi. Avec un seul champ, Gemini se trompe ; avec 2, il
/// applique la préférence locale aux déplacements de proximité et garde
/// une logique algorithmique pour les longues distances internes.
class TransportAdvice {
  /// Sous-bloc "Aller à la destination". Toujours fourni.
  final String arrivalLabel;

  /// Sous-bloc "Sur place". Toujours fourni.
  final String localLabel;

  /// True si l'avion est l'option pertinente pour rejoindre la destination.
  /// L'aéroport est alors mentionné dans `arrivalLabel`.
  final bool isFlightRelevant;

  /// Distance approximative origine → destination, en km. Null si non
  /// estimable.
  final double? estimatedDistanceKm;

  /// Code IATA de l'aéroport effectif pour ce voyage.
  final String homeAirportIata;

  /// Mode arrival appliqué (peut être null = best ou heuristique).
  final String? arrivalMode;

  /// Mode local appliqué (peut être null = best).
  final String? localMode;

  /// Raison courte injectée dans le prompt Gemini.
  final String reason;

  const TransportAdvice({
    required this.arrivalLabel,
    required this.localLabel,
    required this.isFlightRelevant,
    required this.estimatedDistanceKm,
    required this.homeAirportIata,
    required this.arrivalMode,
    required this.localMode,
    required this.reason,
  });

  /// Bloc texte à injecter dans le system prompt Gemini. Inclut la règle
  /// importante : la préférence locale ne s'applique pas aux longues
  /// distances inter-étapes.
  String toPromptBlock() {
    final buf = StringBuffer();
    buf.writeln('CONTEXTE TRANSPORT (calculé par Lunao)');
    buf.writeln('- Aéroport de départ par défaut : $homeAirportIata');
    if (estimatedDistanceKm != null) {
      buf.writeln('- Distance estimée origine → destination : '
          '~${estimatedDistanceKm!.round()} km');
    }
    buf.writeln('- Avion pertinent pour rejoindre : '
        '${isFlightRelevant ? "oui" : "non"} ($reason)');
    buf.writeln('- Recommandation pour rejoindre : $arrivalLabel');
    buf.writeln('- Recommandation sur place : $localLabel');
    buf.writeln();
    buf.writeln('RÈGLES IMPORTANTES :');
    buf.writeln('- Si l\'avion n\'est pas pertinent pour rejoindre (proximité, '
        'même pays sous 500 km), ne propose pas de vol et ne mentionne pas '
        'l\'aéroport sauf si l\'utilisateur insiste.');
    buf.writeln('- La préférence "sur place" s\'applique aux déplacements '
        'locaux (intra-ville, hôtel ↔ activité). Elle ne s\'applique PAS '
        'automatiquement aux longues distances entre étapes (ex: Bangkok → '
        'Krabi reste un vol même si l\'utilisateur préfère les transports '
        'en commun à Bangkok). Pour ces trajets internes, choisis le mode '
        'le plus logique selon distance, durée, coût, confort et faisabilité.');
    return buf.toString();
  }
}

class AssistantTransportAdvisor {
  /// Calcule la recommandation transport pour un voyage. Compose 2 sous-
  /// recommandations indépendantes (arrival + local).
  TransportAdvice compute({
    required Trip trip,
    required String? userHomeAirportFromProfile,
    String? userArrivalPreferenceFromProfile,
    String? userLocalPreferenceFromProfile,
  }) {
    final homeIata = trip.homeAirportIata ??
        userHomeAirportFromProfile ??
        'CDG';

    // Mode arrival = override voyage > profil > null (heuristique pure)
    final arrivalMode =
        trip.arrivalTransportMode ?? userArrivalPreferenceFromProfile;
    // Mode local = override voyage > profil > null (heuristique pure)
    final localMode = trip.localTransportMode ?? userLocalPreferenceFromProfile;

    // ─── Arrivée : distance + scoring + préférence éventuelle ─────────
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

    final airportDisplay = _formatAirport(homeIata);
    bool isFlightRelevant;
    String arrivalLabel;
    String reason;

    // Préférence explicite "flight" → toujours avion
    if (_normalizeMode(arrivalMode) == 'flight') {
      isFlightRelevant = true;
      reason = 'préférence utilisateur : avion';
      arrivalLabel = 'Avion préféré · départ $airportDisplay';
    }
    // Préférence "train" → train, sauf si distance très longue → on signale
    else if (_normalizeMode(arrivalMode) == 'train') {
      isFlightRelevant = false;
      reason = 'préférence utilisateur : train';
      arrivalLabel = distanceKm != null && distanceKm > 1000
          ? 'Train préféré · trajet longue distance à prévoir'
          : 'Train préféré';
    }
    // Préférence "car"
    else if (_normalizeMode(arrivalMode) == 'car') {
      isFlightRelevant = false;
      reason = 'préférence utilisateur : voiture';
      arrivalLabel = distanceKm != null && distanceKm > 600
          ? 'Voiture préférée · long trajet à prévoir'
          : 'Voiture préférée';
    }
    // Préférence "bus"
    else if (_normalizeMode(arrivalMode) == 'bus') {
      isFlightRelevant = false;
      reason = 'préférence utilisateur : bus';
      arrivalLabel = 'Bus préféré';
    }
    // Pas de préférence ou 'best' → heuristique distance + pays
    else {
      if (distanceKm != null && distanceKm < 200) {
        isFlightRelevant = false;
        reason = 'destination proche (~${distanceKm.round()} km)';
        arrivalLabel = 'Voiture ou train recommandé · avion non nécessaire';
      } else if (sameCountry && distanceKm != null && distanceKm < 500) {
        isFlightRelevant = false;
        reason = 'même pays, ~${distanceKm.round()} km';
        arrivalLabel = 'Train ou voiture recommandé · avion non nécessaire';
      } else if (distanceKm != null && distanceKm > 900) {
        isFlightRelevant = true;
        reason = 'long-courrier (~${distanceKm.round()} km)';
        arrivalLabel = 'Avion recommandé · départ $airportDisplay';
      } else if (distanceKm != null) {
        isFlightRelevant = false;
        reason = 'distance moyenne (~${distanceKm.round()} km)';
        arrivalLabel =
            'Lunao comparera train, voiture et avion selon ton budget';
      } else if (sameCountry) {
        isFlightRelevant = false;
        reason = 'même pays';
        arrivalLabel = 'Train ou voiture recommandé';
      } else {
        isFlightRelevant = true;
        reason = 'pays différent, distance non estimable';
        arrivalLabel = 'Avion recommandé · départ $airportDisplay';
      }
    }

    // ─── Local : simple lookup label ──────────────────────────────────
    final localLabel = _localLabelFor(_normalizeMode(localMode));

    return TransportAdvice(
      arrivalLabel: arrivalLabel,
      localLabel: localLabel,
      isFlightRelevant: isFlightRelevant,
      estimatedDistanceKm: distanceKm,
      homeAirportIata: homeIata,
      arrivalMode: _normalizeMode(arrivalMode),
      localMode: _normalizeMode(localMode),
      reason: reason,
    );
  }

  /// Normalise un mode : null/'best'/'' → null (laisser Lunao décider).
  String? _normalizeMode(String? mode) {
    if (mode == null) return null;
    final m = mode.trim().toLowerCase();
    if (m.isEmpty || m == 'best') return null;
    return m;
  }

  /// Label pour la ligne "Sur place".
  String _localLabelFor(String? mode) {
    switch (mode) {
      case 'public_transport':
        return 'Transports en commun quand possible';
      case 'walk':
        return 'Marche privilégiée';
      case 'taxi':
        return 'Taxi / VTC privilégié';
      case 'car':
        return 'Voiture privilégiée';
      case 'scooter':
        return 'Scooter privilégié';
      case 'comfort':
        return 'Trajets confortables privilégiés';
      case 'budget':
        return 'Options économiques privilégiées';
      default:
        return 'Lunao choisira selon le contexte';
    }
  }

  ({double lat, double lng})? _findDestinationCoords(Trip trip) {
    if (trip.itinerarySegments.isNotEmpty) {
      final first = trip.itinerarySegments.first;
      if (first.latitude != null && first.longitude != null) {
        return (lat: first.latitude!, lng: first.longitude!);
      }
    }
    return coordsForCity(trip.destination);
  }

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
