// Helpers d'extraction de "ville" depuis les `address_components` Google.
// Partagé entre `GeocodingService` (chemin texte) et `PlacesService` (chemin
// placeId), pour garantir un comportement identique sur les 2 chemins.

/// Préfixes de subdivisions trop fines pour servir d'étape de voyage. Quand
/// `locality` matche l'un, on bypasse pour tomber sur `administrative_area_level_1`
/// (= province / préfecture / état). Couvre les cas Asie où Google renvoie le
/// sous-district où est physiquement l'aéroport (ex: "Tambon Nong Prue" au lieu
/// de "Pattaya"/"Chonburi").
const _localityBypassPrefixes = <String>[
  'Tambon ',
  'tambon ',
  'TAMBON ',
  'Khwaeng ', // Bangkok sub-districts
  'khwaeng ',
  'KHWAENG ',
  'Amphoe ',
  'amphoe ',
  'AMPHOE ',
];

bool _looksLikeFineSubdivision(String value) {
  for (final prefix in _localityBypassPrefixes) {
    if (value.startsWith(prefix)) return true;
  }
  return false;
}

/// Préfixes administratifs à retirer du nom retourné. Cas thaï : Google
/// renvoie souvent "Chang Wat Krabi" (= "Province de Krabi") au lieu de
/// "Krabi". Idem pour d'autres pays. Strip pour avoir le nom courant.
const _adminNamePrefixes = <String>[
  'Chang Wat ', // จังหวัด — préfixe province en Thaïlande
  'Changwat ',
  'Province de ',
  'Province of ',
  'Préfecture de ',
  'Prefecture of ',
];

String _stripAdminPrefix(String value) {
  for (final prefix in _adminNamePrefixes) {
    if (value.startsWith(prefix)) return value.substring(prefix.length).trim();
  }
  return value;
}

/// Choisit le meilleur candidat "ville touristique" parmi les niveaux
/// d'address_components extraits de Google. Cascade :
///
/// 1. `locality` (Bangkok, Tokyo, Paris, etc.) — sauf si elle matche un
///    pattern de subdivision trop fine (Tambon/Khwaeng/Amphoe en Asie),
///    dans ce cas on continue.
/// 2. `postal_town` (UK : Londres, Manchester, etc.).
/// 3. `administrative_area_level_1` (province en Asie = Bangkok, Krabi,
///    Phuket ; préfecture au Japon = Tokyo, Kyoto ; pas idéal en France où
///    c'est la région, mais fallback acceptable).
/// 4. `sublocality_level_1`.
/// 5. `administrative_area_level_2`.
///
/// Le résultat est normalisé via `_stripAdminPrefix` pour retirer les
/// préfixes administratifs ("Chang Wat ", "Province de ", etc.) et avoir
/// le nom courant ("Krabi" au lieu de "Chang Wat Krabi").
///
/// Retourne null si aucun candidat trouvé. Le caller peut alors fallback
/// sur le nom du lieu (`name` du Place Details / `formatted_address` du
/// Geocoding) — moins propre mais évite un blocage.
String? pickCityFromComponents({
  String? locality,
  String? postalTown,
  String? adminLevel1,
  String? sublocalityLevel1,
  String? adminLevel2,
}) {
  if (locality != null && locality.isNotEmpty && !_looksLikeFineSubdivision(locality)) {
    return _stripAdminPrefix(locality);
  }
  if (postalTown != null && postalTown.isNotEmpty) return _stripAdminPrefix(postalTown);
  if (adminLevel1 != null && adminLevel1.isNotEmpty) return _stripAdminPrefix(adminLevel1);
  if (sublocalityLevel1 != null && sublocalityLevel1.isNotEmpty) return _stripAdminPrefix(sublocalityLevel1);
  if (adminLevel2 != null && adminLevel2.isNotEmpty) return _stripAdminPrefix(adminLevel2);
  return null;
}
