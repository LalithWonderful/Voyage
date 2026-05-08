/// Détection de conflits avant d'appliquer une `SubTripSuggestion` au voyage.
///
/// Lot 1 (V1) : détection city-level uniquement — pas de chevauchement de
/// dates précis. Suffit pour les 3 cas du brief Lalith :
/// - Hôtel à l'ancrage → bloquer `replaceAnchorGateway` (l'utilisateur dort
///   vraiment là-bas, ne pas effacer la ville)
/// - Hôtel à la ville suggérée → suggérer la card mais signaler "déjà
///   réservé là-bas" pour que l'user comprenne pourquoi c'est pertinent
/// - Vol/transport vers l'ancrage → confirme le pattern gateway (info
///   neutre, pas un blocage)
///
/// Lot 2 affinera avec :
/// - Détection date-précise (overlap avec check_in/check_out)
/// - Conflit transfert "Hanoï → Ninh Bình" qui rend `replace` incohérent
/// - Validation de la chronologie après transformation
library;

import 'package:voyage/features/wallet/models/document_model.dart';

/// Verdict de la pré-validation d'une suggestion.
enum SuggestionVerdict {
  /// La suggestion peut être appliquée sans précaution particulière.
  allow,
  /// La suggestion peut être appliquée mais on signale un point d'attention
  /// (ex: hôtel déjà à la ville suggérée, l'user verra son hébergement
  /// associé). Card cliquable, hint informatif.
  allowWithNotice,
  /// L'application risque de casser le planning (ex: replace alors que
  /// l'user a un hôtel à l'ancrage). Card désactivée en V1, demandera
  /// confirmation explicite en V2.
  block,
}

/// Résultat structuré du conflict detector — verdict + texte humain pour UI.
class SuggestionPreflight {
  final SuggestionVerdict verdict;

  /// Texte court à afficher sur la card (hint ou raison de blocage).
  /// Vide si verdict = allow et pas d'info supplémentaire utile.
  final String? notice;

  const SuggestionPreflight({
    required this.verdict,
    this.notice,
  });
}

/// Normalise un nom de ville pour comparaison. Doit rester aligné sur
/// `_normalizeCity` côté `sub_trip_suggestions.dart` (copie locale pour
/// éviter une exposition de l'helper privé).
String _normalize(String s) {
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

/// Vrai si AU MOINS un doc hôtel du voyage est rattaché à `city`. Match
/// d'abord sur `metadata['address_city']` (structuré, fourni par
/// Geocoding API), fallback texte sur `metadata['address']` (substring
/// case+accent insensible).
///
/// Note : address_city peut être null si l'user a saisi l'hôtel en mode
/// fallback texte sans placeId. On reste tolérant.
bool _hasHotelInCity(List<TripDocument> docs, String city) {
  final norm = _normalize(city);
  if (norm.isEmpty) return false;
  for (final d in docs) {
    if (d.category != DocumentCategory.hotel) continue;
    final m = d.metadata;
    final structuredCity = (m['address_city'] as String?)?.trim();
    if (structuredCity != null && structuredCity.isNotEmpty) {
      if (_normalize(structuredCity) == norm) return true;
    }
    // Fallback : substring sur l'adresse libre. Tolère "Hanoi, Vietnam"
    // contenant "hanoi" — sans confondre avec "Han" (on cherche le mot
    // entier via délimiteurs simples).
    final address = (m['address'] as String?)?.trim();
    if (address != null && address.isNotEmpty) {
      final normAddr = _normalize(address);
      // Match simple : ville présente comme mot dans l'adresse.
      // Délimité par début/fin/espace/virgule/tiret.
      final pattern = RegExp(
        r'(^|[\s,;\-])' + RegExp.escape(norm) + r'($|[\s,;\-])',
      );
      if (pattern.hasMatch(normAddr)) return true;
    }
  }
  return false;
}

/// Vrai si un vol arrive à `city` (`metadata['to_city']` match). Sert à
/// confirmer le pattern gateway — info neutre, pas un blocage.
bool _hasArrivalFlightTo(List<TripDocument> docs, String city) {
  final norm = _normalize(city);
  for (final d in docs) {
    if (d.category != DocumentCategory.flight) continue;
    final to = (d.metadata['to_city'] as String?)?.trim();
    if (to != null && _normalize(to) == norm) return true;
  }
  return false;
}

/// Pré-validation d'une suggestion.
///
/// Règles V1 (Lot 1) :
/// - Si la suggestion est `replaceAnchorGateway` ET un hôtel existe à
///   l'ancrage → BLOCK ("Cette étape contient déjà une réservation").
///   On ne remplace pas une ville où l'user dort réellement.
/// - Si un hôtel existe à la ville suggérée → ALLOW_WITH_NOTICE
///   ("Ton hébergement est à [ville suggérée]"). Confirme la pertinence.
/// - Si un hôtel existe à la ville suggérée ET pas à l'ancrage → idem
///   ALLOW_WITH_NOTICE. Renforce le signal gateway.
/// - Sinon → ALLOW.
///
/// `anchorCity` = ville d'ancrage de la suggestion.
/// `suggestedCities` = villes que la suggestion injecterait.
/// `mode` = mode d'insertion (string pour découpler d'enum).
/// `docs` = documents du voyage (vols, hôtels, transferts).
SuggestionPreflight preflightSuggestion({
  required String anchorCity,
  required List<String> suggestedCities,
  required String mode,
  required List<TripDocument> docs,
}) {
  final hotelInAnchor = _hasHotelInCity(docs, anchorCity);
  final hotelInSuggested = suggestedCities.any(
    (c) => _hasHotelInCity(docs, c),
  );

  // Cas critique : on veut effacer l'ancrage alors que l'user a un hôtel
  // dessus. Bloquer dur en V1.
  if (mode == 'replaceAnchorGateway' && hotelInAnchor) {
    return const SuggestionPreflight(
      verdict: SuggestionVerdict.block,
      notice:
          'Cette étape contient déjà une réservation d\'hôtel. '
          'Vérifie avant de remplacer.',
    );
  }

  // Hôtel à la ville suggérée → notice positive ("ça colle, ton hôtel
  // est là-bas"). Renforce le signal pour l'user.
  if (hotelInSuggested) {
    return SuggestionPreflight(
      verdict: SuggestionVerdict.allowWithNotice,
      notice:
          'Lunao a trouvé une réservation d\'hôtel à '
          '${suggestedCities.first}. Cette étape colle à ton itinéraire.',
    );
  }

  // Vol vers l'ancrage + pas d'hôtel à l'ancrage → pattern gateway pur.
  // Info neutre, allow propre (pas de notice nécessaire — le whyText
  // de la suggestion suffit).
  if (!hotelInAnchor && _hasArrivalFlightTo(docs, anchorCity)) {
    return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
  }

  return const SuggestionPreflight(verdict: SuggestionVerdict.allow);
}
