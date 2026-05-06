import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Source de la déduction de l'aéroport d'arrivée. Sert à la fois pour
/// remonter au prompt Gemini ("source: vol wallet") et à la confiance dans
/// la déduction (un billet de vol est plus fiable qu'une heuristique).
enum ArrivalSource {
  /// Vol enregistré dans le wallet — confiance maximale.
  walletFlight,
  /// Adresse d'hébergement — l'aéroport est déduit de la ville.
  accommodation,
  /// Première étape (ou destination) du voyage — déduit de la table.
  tripFirstStop,
  /// Rien d'exploitable — Lunao doit poser la question.
  unknown,
}

/// Synthèse "voici comment l'utilisateur arrive à destination".
/// Permet à Gemini de NE PAS demander "tu arrives à quel aéroport ?"
/// quand l'info peut être déduite — règle énoncée par Lalith.
class ArrivalContext {
  /// IATA de l'aéroport d'arrivée probable, si déduit. Null si inconnu.
  final String? airportIata;

  /// Label affichable de l'aéroport (ex: "Marrakech Menara — RAK").
  /// Null si pas d'aéroport déduit.
  final String? airportLabel;

  /// Ville d'arrivée probable (première étape ou destination).
  final String? city;

  /// Nom de l'hébergement si connu — utile pour le prompt
  /// ("transfert vers Riad Dar X").
  final String? accommodationName;

  /// Adresse de l'hébergement si connue.
  final String? accommodationAddress;

  /// True si un vol a été trouvé dans le wallet.
  final bool hasWalletFlight;

  /// Source de la déduction (transparente pour Gemini).
  final ArrivalSource source;

  const ArrivalContext({
    this.airportIata,
    this.airportLabel,
    this.city,
    this.accommodationName,
    this.accommodationAddress,
    this.hasWalletFlight = false,
    this.source = ArrivalSource.unknown,
  });

  /// True si on a au moins un aéroport probable — Gemini ne doit pas
  /// reposer la question dans ce cas.
  bool get hasInferableAirport => airportIata != null;

  /// Bloc texte à concaténer au prompt Gemini.
  String toPromptBlock() {
    final buf = StringBuffer();
    buf.writeln("CONTEXTE ARRIVÉE (calculé par Lunao)");
    if (city != null) {
      buf.writeln('- Ville d\'arrivée probable : $city');
    }
    buf.writeln('- Vol dans le wallet : ${hasWalletFlight ? "oui" : "non"}');
    if (accommodationName != null) {
      final addr = accommodationAddress != null && accommodationAddress!.isNotEmpty
          ? ' · $accommodationAddress'
          : '';
      buf.writeln('- Hébergement connu : $accommodationName$addr');
    } else {
      buf.writeln('- Hébergement connu : non');
    }
    if (airportLabel != null) {
      buf.writeln('- Aéroport d\'arrivée probable : $airportLabel');
      buf.writeln('- Source : ${_sourceLabel()}');
    } else {
      buf.writeln('- Aéroport d\'arrivée probable : inconnu '
          '(ville absente de la table aéroports)');
    }
    buf.writeln();
    buf.writeln("RÈGLE IMPORTANTE :");
    buf.writeln("- Ne demande jamais à l'utilisateur \"tu arrives à quel "
        "aéroport ?\" si un aéroport probable ou confirmé est fourni "
        "ci-dessus.");
    buf.writeln("- Si la source est \"déduite\", formule avec prudence : "
        "\"probablement\", \"sans doute\".");
    buf.writeln("- Si la source est le \"billet d'avion enregistré\", parle "
        "de manière confirmée : \"tu arrives à...\".");
    buf.writeln("- Si aucun aéroport fiable n'est disponible, demande "
        "uniquement la première ville du voyage (pas l'aéroport). "
        "Exemple : \"Tu commences par quelle ville en Patagonie : "
        "El Calafate, Ushuaia, Bariloche ou une autre ?\"");
    return buf.toString();
  }

  String _sourceLabel() {
    switch (source) {
      case ArrivalSource.walletFlight:
        return "billet d'avion enregistré dans le wallet";
      case ArrivalSource.accommodation:
        return "déduit depuis l'adresse de l'hébergement";
      case ArrivalSource.tripFirstStop:
        return "déduit depuis la première étape du voyage";
      case ArrivalSource.unknown:
        return "inconnue";
    }
  }
}

class AssistantArrivalContextBuilder {
  /// Construit le contexte arrivée selon la cascade :
  /// 1. Vol arrivée enregistré dans le wallet → IATA tiré du métadonnée
  /// 2. Hébergement enregistré → ville déduite + aéroport principal
  /// 3. Première étape du voyage → aéroport principal de la ville
  /// 4. Destination du voyage → aéroport principal
  /// 5. Rien → unknown
  ArrivalContext build({
    required Trip trip,
    required List<TripDocument> tripDocuments,
  }) {
    // ─── 1. Vol dans le wallet ────────────────────────────────────────
    final flights = tripDocuments
        .where((d) => d.category == DocumentCategory.flight)
        .toList();
    if (flights.isNotEmpty) {
      // On prend le 1er vol qui a un IATA d'arrivée exploitable. Format
      // metadata typique (cf. document_model.dart : `to`, parfois `to_iata`
      // selon le code d'extraction Gemini). On accepte les 2 formats.
      for (final f in flights) {
        final toIata = _extractIata(f.metadata['to_iata']) ??
            _extractIata(f.metadata['to']);
        if (toIata != null) {
          final lookup = lookupAirport(toIata);
          final label = lookup == null
              ? toIata
              : (lookup.name != null && lookup.name!.isNotEmpty
                  ? '${lookup.city} ${lookup.name} — ${lookup.iata}'
                  : '${lookup.city} — ${lookup.iata}');
          final accommo = trip.accommodation;
          return ArrivalContext(
            airportIata: toIata,
            airportLabel: label,
            city: lookup?.city ?? trip.destination,
            accommodationName: accommo?.name,
            accommodationAddress: accommo?.address,
            hasWalletFlight: true,
            source: ArrivalSource.walletFlight,
          );
        }
      }
    }

    // ─── 2/3/4. Déduction par ville (étape ou destination) ────────────
    String? cityCandidate;
    if (trip.itinerarySegments.isNotEmpty) {
      cityCandidate = trip.itinerarySegments.first.city;
    }
    cityCandidate ??= trip.destination;

    final inferred = inferAirportForCity(cityCandidate);
    final accommo = trip.accommodation;
    final source = accommo != null
        ? ArrivalSource.accommodation
        : ArrivalSource.tripFirstStop;

    if (inferred != null) {
      final label = inferred.name != null && inferred.name!.isNotEmpty
          ? '${inferred.city} ${inferred.name} — ${inferred.iata}'
          : '${inferred.city} — ${inferred.iata}';
      return ArrivalContext(
        airportIata: inferred.iata,
        airportLabel: label,
        city: cityCandidate,
        accommodationName: accommo?.name,
        accommodationAddress: accommo?.address,
        hasWalletFlight: false,
        source: source,
      );
    }

    // ─── 5. Pas d'aéroport déductible ─────────────────────────────────
    return ArrivalContext(
      city: cityCandidate,
      accommodationName: accommo?.name,
      accommodationAddress: accommo?.address,
      hasWalletFlight: false,
      source: ArrivalSource.unknown,
    );
  }

  /// Extrait un code IATA 3 lettres d'une string. Accepte directement un
  /// code (ex: "RAK") ou une string composite (ex: "Marrakech (RAK)",
  /// "RAK — Menara"). Retourne null si rien d'exploitable.
  String? _extractIata(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    // Cas 1 : la string est exactement un IATA
    if (RegExp(r'^[A-Za-z]{3}$').hasMatch(s)) {
      return s.toUpperCase();
    }
    // Cas 2 : extraire le 1er groupe de 3 lettres maj entre parenthèses
    final paren = RegExp(r'\(([A-Z]{3})\)').firstMatch(s);
    if (paren != null) return paren.group(1);
    // Cas 3 : 3 lettres maj isolées dans la string
    final isolated = RegExp(r'\b([A-Z]{3})\b').firstMatch(s);
    if (isolated != null) return isolated.group(1);
    return null;
  }
}
