/// Constantes V1 du système "régions des grands pays".
///
/// 14 pays "large" (le choix d'une région est OBLIGATOIRE — le sélecteur de
/// rayon manuel est masqué, chaque région applique son `recommended_radius_km`)
/// + 2 pays "travel_region" (Turquie, Thaïlande — où le choix d'une région est
/// recommandé mais l'utilisateur peut basculer sur "Tout le pays / rayon
/// manuel" via une 6e card en bas de la liste).
library;

/// ISO 2 des pays où la sélection de région est OBLIGATOIRE.
/// À jour V1 : 14 pays (USA, Chine, Brésil, Inde, Australie, Canada, Russie,
/// Argentine, Mexique, Indonésie, Arabie saoudite, Afrique du Sud, Algérie,
/// Kazakhstan).
const largeCountries = <String>{
  'US', 'CN', 'BR', 'IN', 'AU', 'CA', 'RU', 'AR',
  'MX', 'ID', 'SA', 'ZA', 'DZ', 'KZ',
};

/// ISO 2 des pays où la sélection de région est RECOMMANDÉE mais pas obligatoire.
/// L'utilisateur voit les cards de régions + une 6e card "Tout le pays".
const travelRegionCountries = <String>{
  'TR', 'TH',
};

/// True si le pays bascule sur la sheet de choix de régions (large ou
/// travel_region). Pour les autres pays (Espagne, Italie, Maroc, France...)
/// on garde le sélecteur de rayon manuel actuel.
bool isCountryWithRegions(String? countryCode) {
  if (countryCode == null || countryCode.isEmpty) return false;
  final upper = countryCode.toUpperCase();
  return largeCountries.contains(upper) || travelRegionCountries.contains(upper);
}

/// True si une région DOIT être choisie (pas d'option "Tout le pays").
bool isLargeCountry(String? countryCode) {
  if (countryCode == null || countryCode.isEmpty) return false;
  return largeCountries.contains(countryCode.toUpperCase());
}

/// True si une région est recommandée mais une option "Tout le pays" reste
/// disponible.
bool isTravelRegionCountry(String? countryCode) {
  if (countryCode == null || countryCode.isEmpty) return false;
  return travelRegionCountries.contains(countryCode.toUpperCase());
}

/// Vocabulaire de tags figé pour la V1. Toute nouvelle région ajoutée à la
/// table `country_regions` (Supabase ou JSON asset) DOIT utiliser uniquement
/// ces tags — sinon `validateRegionTags` throw au boot pour signaler la
/// dérive.
///
/// Cette liste est partagée entre :
/// 1. Les régions (`tags` colonne) → décrivent ce que la région propose.
/// 2. `interestToTags` → traduit les intérêts utilisateur en tags région.
/// 3. `travelerTypeToTags` → traduit le profil voyageur en tags région.
/// 4. `tagToFrLabel` → libellé FR pour l'affichage UI.
///
/// **Ajouter un tag = mettre à jour les 4 endroits.** Le check au boot
/// vérifie au moins (1) ⊆ allowedTags pour éviter les typos.
const allowedTags = <String>{
  // Vocabulaire de base (validé Lalith)
  'city', 'culture', 'food', 'beach', 'nature', 'history', 'mountain',
  'desert', 'adventure', 'relax', 'first_time', 'roadtrip', 'family',
  'wellness', 'slow_travel', 'authentic', 'diving', 'hiking', 'wine',
  'photo', 'balloon', 'monuments', 'palaces', 'ruins', 'safari',
  'wildlife', 'glaciers', 'volcano', 'theme_parks', 'kitesurf', 'train',
  'long_trip', 'short_trip', 'remote', 'luxury', 'honeymoon', 'river',
  'lake', 'oasis', 'spiritual', 'music', 'coast', 'shopping', 'landscape',
  'islands', 'museums', 'architecture', 'villages', 'parks',
  // Tags spécifiques présents dans certaines régions de la V1 (élargissement
  // contrôlé du vocabulaire pour rester fidèle aux données fournies).
  'roman_sites',  // DZ Constantine & est
  'pandas',       // CN Sichuan
  'temples',      // TH Nord
  'whales',       // MX Baja California
  'waterfalls',   // AR Chutes d'Iguazú
  'sun',          // BR Nordeste plages
  'trekking',     // DZ Tassili & Hoggar
};

/// Vérifie qu'aucune région n'utilise un tag hors `allowedTags`. À appeler
/// au boot après chargement des régions. Throw si une dérive est détectée
/// pour signaler le problème AVANT qu'il pollue silencieusement le scoring.
///
/// Retourne le set des tags inconnus s'il y en a, vide sinon (utile pour
/// fail soft en prod : log warning sans crasher l'app).
Set<String> findUnknownTags(Iterable<List<String>> regionTagsList) {
  final unknown = <String>{};
  for (final regionTags in regionTagsList) {
    for (final t in regionTags) {
      if (!allowedTags.contains(t)) unknown.add(t);
    }
  }
  return unknown;
}
