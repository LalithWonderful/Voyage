/// V5 (Lalith 2026-05-10) — extraction des billets aller-retour.
///
/// Quand Gemini extrait un billet de transport et flag `is_round_trip = true`,
/// ce service traduit la metadata « cocktail » (vol aller + sub-objet
/// `return_leg`) en deux entités séparées prêtes à être insérées dans
/// `trip_documents` :
///   1. l'aller, avec metadata nettoyée (sans `is_round_trip` ni `return_leg`)
///   2. le retour, avec metadata enrichie (booking_reference / airline
///      / company hérités de l'aller si manquants côté retour)
///
/// Service pur, sans I/O, facile à tester. Utilisé par
/// `document_form_sheet.dart` après `extractDocumentFromImage` /
/// `extractDocumentFromText`.
library;

import 'package:voyage/features/planning/services/airport_city_overrides.dart';

/// Résultat de l'extraction d'un billet round-trip.
class RoundTripExtraction {
  /// Metadata nettoyée du DOCUMENT ALLER (champs `is_round_trip` et
  /// `return_leg` retirés). À hydrater dans le formulaire principal.
  final Map<String, dynamic> outboundMetadata;

  /// Metadata du DOCUMENT RETOUR, ou `null` si l'extraction est
  /// one-way OU si le billet était flaggé round-trip sans `return_leg`
  /// exploitable.
  final Map<String, dynamic>? returnMetadata;

  /// Nom prévisualisé du document retour (« Vol retour Turkish Airlines
  /// TK0069 + TK1353 »). `null` quand `returnMetadata` est `null`.
  final String? returnName;

  /// True si Gemini a flag `is_round_trip == true` mais sans fournir
  /// de `return_leg` exploitable. Pour l'UX : on affiche un warning
  /// invitant l'utilisateur à vérifier que le retour est bien
  /// enregistré.
  final bool suspectedRoundTripWithoutReturn;

  const RoundTripExtraction({
    required this.outboundMetadata,
    this.returnMetadata,
    this.returnName,
    this.suspectedRoundTripWithoutReturn = false,
  });
}

/// Analyse la metadata extraite par Gemini pour détecter un éventuel
/// billet aller-retour. Si `is_round_trip == true` ET `return_leg`
/// présent, on renvoie une `RoundTripExtraction` avec les deux entités
/// séparées. Sinon on renvoie une extraction one-way (returnMetadata
/// nul).
///
/// Catégories supportées : `flight`, `train`. Pour les autres
/// catégories, on retourne directement une extraction one-way (la
/// metadata de l'aller = la metadata d'origine, sans toucher).
RoundTripExtraction analyseRoundTripExtraction({
  required Map<String, dynamic> rawMetadata,
  required String category,
}) {
  final isFlight = category == 'flight';
  final isTrain = category == 'train';
  if (!isFlight && !isTrain) {
    return RoundTripExtraction(
      outboundMetadata: Map<String, dynamic>.from(rawMetadata),
    );
  }

  final isRT = rawMetadata['is_round_trip'] == true;
  final retRaw = rawMetadata['return_leg'];

  // Metadata de l'aller : on retire systématiquement les champs de
  // pilotage round-trip pour ne pas polluer le doc principal.
  final outbound = Map<String, dynamic>.from(rawMetadata)
    ..remove('is_round_trip')
    ..remove('return_leg');

  if (isRT && retRaw is Map) {
    final ret = Map<String, dynamic>.from(retRaw);
    // Le retour partage la résa de l'aller. On hérite des champs
    // « identifiants stables » (compagnie, classe…) si manquants côté
    // retour. Dates, heures, numéros de vol/train restent ceux du retour.
    ret.putIfAbsent(
        'reservation_number', () => rawMetadata['reservation_number']);
    if (isFlight) {
      ret.putIfAbsent('airline', () => rawMetadata['airline']);
    } else {
      ret.putIfAbsent('company', () => rawMetadata['company']);
      ret.putIfAbsent('class', () => rawMetadata['class']);
    }
    // V5.1 (Lalith fix 2026-05-10) — canonicalisation des endpoints.
    // Le doc principal passe par `_resolveTransportEndpoint` qui
    // remplit `from_city`/`to_city` via Google Places. Le retour ne
    // passe pas par ce pipeline → sans canonicalisation, les champs
    // `from_city`/`to_city` restent absents et la matching aval (find
    // docs liés, transitions gateway, document_consistency) échoue.
    // Solution : pour les vols, IATA → city via lookupAirport. Sinon
    // on copie `from`/`to` tels quels comme city name.
    _canonicalizeEndpoints(ret, isFlight: isFlight);
    return RoundTripExtraction(
      outboundMetadata: outbound,
      returnMetadata: ret,
      returnName: _buildReturnName(ret, isFlight: isFlight),
    );
  }

  if (isRT) {
    // is_round_trip=true mais aucune return_leg exploitable : warning.
    return RoundTripExtraction(
      outboundMetadata: outbound,
      suspectedRoundTripWithoutReturn: true,
    );
  }

  return RoundTripExtraction(outboundMetadata: outbound);
}

/// V5.1 — pour chaque endpoint (`from`/`to`), si `_city` n'est pas
/// déjà défini :
///  - vol : tente IATA→city via `lookupAirport` (ex. "BKK" → "Bangkok"
///    avec en bonus le nom long de l'aéroport)
///  - sinon (et pour les trains) : recopie `from`/`to` tel quel comme
///    `_city` — c'est probablement déjà un nom de ville/gare lisible.
///
/// Indispensable pour que `findDocsLinkedToSegment` matche le doc retour
/// avec la card « final Bangkok » via `metadata['from_city']`. Sans ça,
/// le retour reste orphelin dans la sheet « Document lié ».
void _canonicalizeEndpoints(
  Map<String, dynamic> meta, {
  required bool isFlight,
}) {
  for (final fieldKey in const ['from', 'to']) {
    final cityKey = '${fieldKey}_city';
    if ((meta[cityKey] as String?)?.trim().isNotEmpty ?? false) continue;
    final raw = (meta[fieldKey] as String?)?.trim() ?? '';
    if (raw.isEmpty) continue;
    if (isFlight && raw.length == 3) {
      final lookup = lookupAirport(raw);
      if (lookup != null) {
        meta[cityKey] = lookup.city;
        // L'IATA d'origine est conservé dans `from`/`to` ; on stocke
        // aussi le nom long de l'aéroport comme valeur affichable
        // dans la card si jamais elle est utilisée comme tel.
        continue;
      }
    }
    // Fallback : on copie le champ texte comme city. Évite que le
    // matching échoue silencieusement sur les docs créés via le
    // chemin round-trip qui ne passent pas par Google Places.
    meta[cityKey] = raw;
  }
}

/// Compose un nom lisible pour le doc retour : « Vol retour Turkish
/// Airlines TK0069 + TK1353 » ou fallback générique. Sert au champ
/// `name` de la ligne `trip_documents` du retour.
String _buildReturnName(
  Map<String, dynamic> ret, {
  required bool isFlight,
}) {
  final num = (ret['flight_number'] as String?)?.trim() ??
      (ret['train_number'] as String?)?.trim() ??
      '';
  final carrier = (ret['airline'] as String?)?.trim() ??
      (ret['company'] as String?)?.trim() ??
      '';
  final parts = <String>[
    if (carrier.isNotEmpty) carrier,
    if (num.isNotEmpty) num,
  ];
  final modeWord = isFlight ? 'Vol retour' : 'Train retour';
  return parts.isEmpty ? modeWord : '$modeWord ${parts.join(' ')}';
}

