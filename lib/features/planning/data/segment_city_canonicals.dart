/// V8.18 (Lalith 2026-05-10 — Q1D segment city resolution) —
/// canonical aliases pour les villes touristiques ambiguës où le
/// géocodage par nom seul retombe sur un homonyme régional sans
/// intérêt voyage.
///
/// Cas observé : "Hoi An" + country Vietnam résolvait sur Hoi An,
/// An Giang, dans le sud (10.39, 105.49) au lieu de Hội An,
/// Quảng Nam (15.88, 108.33), la cité historique célèbre près de
/// Da Nang. Cluster compact (radius < 5km) donc invisible du
/// `[cluster_guard]` — seule la canonicalisation sauve.
///
/// Le système :
/// 1. Lookup par `(city normalisé, country)` ou `(city normalisé)`.
/// 2. Si match → enrichir la query Geocoder avec province + country.
/// 3. Validate result : si > 50km de `expectedLat/Lng`, override
///    avec les coordonnées canoniques (la canonical map est
///    authoritative pour ces villes).
///
/// Liste curated V1 des villes ambiguës observées sur trips
/// Lalith. Ajouter au fil des bugs.
library;

class SegmentCanonicalCity {
  /// Query enrichie passée au Geocoder (fallback si lookup canonical
  /// suffit pas). Inclut province + country pour désambiguïser.
  final String canonicalQuery;

  /// Coordonnées canoniques (centre touristique). Utilisées pour
  /// validation post-geocode + fallback hard si geocoder dérive.
  final double expectedLat;
  final double expectedLng;

  /// Code pays ISO-2 (lowercase) pour `regionHint`.
  final String? countryCode;

  /// V8.19 (Lalith 2026-05-10 — Q1D segment pool guard) — query hints
  /// curated, utilisés en fallback quand le pool gather d'un segment
  /// reste vide (cache miss + budget Cost-1 cramé). Identique aux
  /// `mustSeeQueries` des blueprints destinations mais à une
  /// granularité segment (sub-city). Vide = pas de fallback.
  ///
  /// Tier implicite : `_BlueprintMustSee` (+100 boost) puisque
  /// curated. Le curator (Lalith) liste les iconiques segment.
  final List<String> queryHints;

  const SegmentCanonicalCity({
    required this.canonicalQuery,
    required this.expectedLat,
    required this.expectedLng,
    this.countryCode,
    this.queryHints = const [],
  });
}

/// V1 — canoniques par (city normalisé). Le country n'est pas
/// dans la clé : si l'utilisateur a saisi "Hoi An" sans country
/// ou avec country=Vietnam, on retombe sur la même résolution.
const Map<String, SegmentCanonicalCity> _canonicalCities =
    <String, SegmentCanonicalCity>{
  // ─── Vietnam ─────────────────────────────────────────────────────
  // « Hoi An » résout sur Hoi An, An Giang sans contexte province.
  // Forcer la cité historique de Quảng Nam.
  // V8.19 — queryHints curated pour fallback si pool gather vide.
  'hoi an': SegmentCanonicalCity(
    canonicalQuery: 'Hội An, Quảng Nam, Vietnam',
    expectedLat: 15.8801,
    expectedLng: 108.3380,
    countryCode: 'vn',
    queryHints: [
      'Hoi An Ancient Town',
      'Japanese Covered Bridge Hoi An',
      'Hoi An Night Market',
      'An Bang Beach',
      'Tra Que Vegetable Village',
      'Thanh Ha Pottery Village',
      'Precious Heritage Art Gallery Museum Hoi An',
    ],
  ),
  'hoi an, vietnam': SegmentCanonicalCity(
    canonicalQuery: 'Hội An, Quảng Nam, Vietnam',
    expectedLat: 15.8801,
    expectedLng: 108.3380,
    countryCode: 'vn',
    queryHints: [
      'Hoi An Ancient Town',
      'Japanese Covered Bridge Hoi An',
      'Hoi An Night Market',
      'An Bang Beach',
      'Tra Que Vegetable Village',
      'Thanh Ha Pottery Village',
      'Precious Heritage Art Gallery Museum Hoi An',
    ],
  ),
  'hội an': SegmentCanonicalCity(
    canonicalQuery: 'Hội An, Quảng Nam, Vietnam',
    expectedLat: 15.8801,
    expectedLng: 108.3380,
    countryCode: 'vn',
    queryHints: [
      'Hoi An Ancient Town',
      'Japanese Covered Bridge Hoi An',
      'Hoi An Night Market',
      'An Bang Beach',
      'Tra Que Vegetable Village',
      'Thanh Ha Pottery Village',
      'Precious Heritage Art Gallery Museum Hoi An',
    ],
  ),
  // « Da Nang » est rarement ambigu, mais on canonicalise pour
  // cohérence (même formulation que Hoi An permet diff < 50km).
  'da nang': SegmentCanonicalCity(
    canonicalQuery: 'Đà Nẵng, Vietnam',
    expectedLat: 16.0544,
    expectedLng: 108.2022,
    countryCode: 'vn',
  ),
  'đà nẵng': SegmentCanonicalCity(
    canonicalQuery: 'Đà Nẵng, Vietnam',
    expectedLat: 16.0544,
    expectedLng: 108.2022,
    countryCode: 'vn',
  ),
  // « Tam Coc » / « Ninh Binh » : cité historique au sud de Hanoi.
  'tam coc': SegmentCanonicalCity(
    canonicalQuery: 'Tam Cốc, Ninh Bình, Vietnam',
    expectedLat: 20.2167,
    expectedLng: 105.9333,
    countryCode: 'vn',
  ),
  'ninh binh': SegmentCanonicalCity(
    canonicalQuery: 'Ninh Bình, Vietnam',
    expectedLat: 20.2500,
    expectedLng: 105.9750,
    countryCode: 'vn',
  ),
  'ninh bình': SegmentCanonicalCity(
    canonicalQuery: 'Ninh Bình, Vietnam',
    expectedLat: 20.2500,
    expectedLng: 105.9750,
    countryCode: 'vn',
  ),
  // « Phu Quoc » : île au sud, pas la commune homonyme.
  'phu quoc': SegmentCanonicalCity(
    canonicalQuery: 'Phú Quốc, Kiên Giang, Vietnam',
    expectedLat: 10.2270,
    expectedLng: 103.9670,
    countryCode: 'vn',
  ),
  'phú quốc': SegmentCanonicalCity(
    canonicalQuery: 'Phú Quốc, Kiên Giang, Vietnam',
    expectedLat: 10.2270,
    expectedLng: 103.9670,
    countryCode: 'vn',
  ),
  'hanoi': SegmentCanonicalCity(
    canonicalQuery: 'Hà Nội, Vietnam',
    expectedLat: 21.0285,
    expectedLng: 105.8542,
    countryCode: 'vn',
  ),
  'hà nội': SegmentCanonicalCity(
    canonicalQuery: 'Hà Nội, Vietnam',
    expectedLat: 21.0285,
    expectedLng: 105.8542,
    countryCode: 'vn',
  ),
  // ─── Thaïlande ───────────────────────────────────────────────────
  'koh samet': SegmentCanonicalCity(
    canonicalQuery: 'Ko Samet, Rayong, Thailand',
    expectedLat: 12.5667,
    expectedLng: 101.4500,
    countryCode: 'th',
  ),
  'ko samet': SegmentCanonicalCity(
    canonicalQuery: 'Ko Samet, Rayong, Thailand',
    expectedLat: 12.5667,
    expectedLng: 101.4500,
    countryCode: 'th',
  ),
  'bangkok': SegmentCanonicalCity(
    canonicalQuery: 'Bangkok, Thailand',
    expectedLat: 13.7563,
    expectedLng: 100.5018,
    countryCode: 'th',
  ),
  'krung thep': SegmentCanonicalCity(
    canonicalQuery: 'Bangkok, Thailand',
    expectedLat: 13.7563,
    expectedLng: 100.5018,
    countryCode: 'th',
  ),
  // ─── Cambodge / autres ──────────────────────────────────────────
  // Ajouter au fil des bugs observés.
};

/// Normalise une string ville pour le lookup canonical.
String _normalizeCanonicalCityKey(String s) {
  var n = s.toLowerCase().trim();
  // Strip diacritiques pour matching tolérant ("hội an" ↔ "hoi an").
  const replacements = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'ạ': 'a', 'ả': 'a', 'ầ': 'a', 'ấ': 'a', 'ậ': 'a', 'ằ': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ẽ': 'e', 'ẻ': 'e',
    'ệ': 'e', 'ề': 'e', 'ế': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ị': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ơ': 'o',
    'ọ': 'o', 'ộ': 'o', 'ố': 'o', 'ồ': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ụ': 'u',
    'ư': 'u',
    'ý': 'y', 'ỳ': 'y',
    'ç': 'c', 'đ': 'd', 'ñ': 'n',
  };
  replacements.forEach((from, to) {
    n = n.replaceAll(from, to);
  });
  return n;
}

/// V8.18 — résolution canonical d'une ville segment. Retourne le
/// canonical correspondant ou null si la ville n'est pas dans la
/// map. Le matching est insensible casse + accents.
///
/// Lookup fait sur :
/// 1. `city + ", " + country` (ex: "hoi an, vietnam") si country fourni.
/// 2. `city` seul (ex: "hoi an").
SegmentCanonicalCity? getCanonicalSegmentCity(String city, {String? country}) {
  if (city.trim().isEmpty) return null;
  final normCity = _normalizeCanonicalCityKey(city);
  if (country != null && country.trim().isNotEmpty) {
    final normCountry = _normalizeCanonicalCityKey(country);
    final composed = '$normCity, $normCountry';
    final hit = _canonicalCities[composed];
    if (hit != null) return hit;
  }
  return _canonicalCities[normCity];
}
