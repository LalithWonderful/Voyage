/// Mappings entre vocabulaire utilisateur (intérêts cochés, type voyageur)
/// et tags région (vocabulaire figé V1, cf. allowedTags).
///
/// Servent au scoring déterministe "Je ne sais pas quoi choisir" :
///   region.tags ∩ (interestTags ∪ travelerTags) → score
///
/// Ajout d'une entrée → tous les tags doivent appartenir à `allowedTags`,
/// sinon `validateMappings` throw au boot.
library;

/// Intérêt utilisateur (clé exacte de la BDD `user_interests` /
/// `trips.interests`) → tags région privilégiés.
///
/// V1 : couvre les 14 intérêts du système actuel + 6 intérêts "futurs"
/// (Photo, Histoire, Spiritualité, Safari/animaux, Romantique, Ville, Famille,
/// Road trip) qui ne sont pas encore dans `interestPlacesQueries` mais le
/// seront probablement. Les entries inutilisées n'ont pas d'effet (intersection
/// vide avec les intérêts cochés).
const interestToTags = <String, List<String>>{
  'Culture': ['culture', 'history', 'monuments', 'palaces', 'ruins', 'museums', 'architecture'],
  'Plage': ['beach', 'coast', 'islands', 'diving', 'kitesurf', 'relax'],
  'Gastronomie': ['food', 'wine', 'culture'],
  'Randonnée': ['hiking', 'mountain', 'nature', 'adventure', 'landscape'],
  'Nature': ['nature', 'wildlife', 'lake', 'river', 'glaciers', 'volcano', 'oasis', 'parks', 'landscape'],
  'Nightlife': ['city', 'music', 'food'],
  'Spots populaires': ['first_time', 'monuments', 'city', 'culture', 'photo'],
  'Hors circuit': ['authentic', 'slow_travel', 'remote', 'villages'],
  'Wellness': ['wellness', 'relax', 'slow_travel', 'luxury'],
  'Shopping': ['shopping', 'city', 'food'],
  'Bons plans': ['first_time', 'authentic', 'slow_travel', 'family', 'food'],
  'Esthétique': ['wellness', 'luxury', 'relax'],
  'Sports': ['hiking', 'adventure', 'diving', 'kitesurf', 'mountain'],
  'Événements': ['music', 'city', 'culture', 'balloon'],
  // Entries préparées pour des intérêts futurs (V2)
  'Road trip': ['roadtrip', 'nature', 'coast', 'desert', 'mountain', 'landscape'],
  'Photo': ['photo', 'landscape', 'nature', 'architecture', 'desert', 'coast'],
  'Histoire': ['history', 'culture', 'monuments', 'ruins', 'palaces'],
  'Spiritualité': ['spiritual', 'culture', 'slow_travel'],
  'Safari / animaux': ['safari', 'wildlife', 'nature'],
  'Romantique': ['honeymoon', 'relax', 'beach', 'wine', 'luxury', 'photo'],
  'Famille': ['family', 'theme_parks', 'beach', 'nature', 'first_time'],
  'Ville': ['city', 'shopping', 'food', 'culture', 'first_time'],
};

/// Type voyageur (clé exacte de `trips.traveler_type` / `user_profiles.traveler_type`)
/// → tags région privilégiés.
///
/// V1 : 10 types existants. Solo et "Premier voyage" non inclus en V1
/// (n'existent pas encore dans `travelerPlacesProfiles`). À ajouter ici en
/// même temps qu'au pipeline si on les introduit.
const travelerTypeToTags = <String, List<String>>{
  'Famille': ['family', 'theme_parks', 'beach', 'nature', 'first_time'],
  'Couple': ['honeymoon', 'relax', 'wellness', 'wine', 'food', 'photo'],
  'Senior': ['slow_travel', 'relax', 'culture', 'history', 'wellness', 'city'],
  'Backpack': ['adventure', 'authentic', 'remote', 'hiking', 'nature', 'slow_travel'],
  'Road-trip': ['roadtrip', 'nature', 'landscape', 'coast', 'desert', 'mountain'],
  'Grand luxe': ['luxury', 'wine', 'wellness', 'relax', 'food'],
  'Fun': ['city', 'beach', 'music', 'theme_parks', 'food'],
  'Chill': ['relax', 'beach', 'wellness', 'slow_travel'],
  'Voyage pro': ['city', 'food', 'first_time'],
  'Meilleur prix': ['authentic', 'slow_travel', 'city'],
};

/// Libellé FR user-facing pour chaque tag du vocabulaire `allowedTags`.
/// Affiché sur les cards "régions" (max 3 tags par carte pour éviter la
/// surcharge UI) et sur la card "✨ Recommandé pour toi" pour expliquer
/// le pourquoi du choix.
///
/// **Tout tag dans `allowedTags` DOIT avoir un libellé ici** — sinon
/// `validateMappings` throw au boot.
const tagToFrLabel = <String, String>{
  // Lieux et activités urbaines
  'city': 'Ville',
  'shopping': 'Shopping',
  'food': 'Gastronomie',
  'wine': 'Vin',
  'music': 'Musique',
  'museums': 'Musées',
  'architecture': 'Architecture',
  // Nature et grands espaces
  'nature': 'Nature',
  'mountain': 'Montagne',
  'lake': 'Lacs',
  'river': 'Fleuves',
  'desert': 'Désert',
  'oasis': 'Oasis',
  'volcano': 'Volcans',
  'glaciers': 'Glaciers',
  'parks': 'Parcs nationaux',
  'landscape': 'Paysages',
  'wildlife': 'Faune sauvage',
  'safari': 'Safari',
  // Mer et plages
  'beach': 'Plage',
  'coast': 'Côte',
  'islands': 'Îles',
  'diving': 'Plongée',
  'kitesurf': 'Kitesurf',
  // Culture et patrimoine
  'culture': 'Culture',
  'history': 'Histoire',
  'monuments': 'Monuments',
  'palaces': 'Palais',
  'ruins': 'Sites antiques',
  'spiritual': 'Spiritualité',
  'authentic': 'Local / authentique',
  'villages': 'Villages',
  // Style de voyage
  'roadtrip': 'Road trip',
  'hiking': 'Randonnée',
  'adventure': 'Aventure',
  'relax': 'Détente',
  'wellness': 'Bien-être',
  'slow_travel': 'Voyage lent',
  'remote': 'Hors circuit',
  'luxury': 'Luxe',
  'honeymoon': 'Lune de miel',
  'family': 'Famille',
  'theme_parks': 'Parcs d\'attractions',
  'first_time': 'Découverte',
  'short_trip': 'Court séjour',
  'long_trip': 'Long voyage',
  'photo': 'Photo',
  // Transport / format particulier
  'train': 'Train',
  'balloon': 'Montgolfière',
  // Tags étendus (régions spécifiques V1)
  'roman_sites': 'Sites romains',
  'pandas': 'Pandas',
  'temples': 'Temples',
  'whales': 'Baleines',
  'waterfalls': 'Cascades',
  'sun': 'Soleil',
  'trekking': 'Trekking',
};

/// Convertit une liste de tags techniques en libellés FR user-facing.
/// Tronque à `maxCount` pour ne pas surcharger l'UI (V1 : 3 max sur les cards).
/// Les tags sans libellé sont ignorés silencieusement (ne casse pas l'UI si
/// un tag exotique remonte de Supabase plus tard).
List<String> tagsToFrLabels(List<String> tags, {int maxCount = 3}) {
  final result = <String>[];
  for (final t in tags) {
    final label = tagToFrLabel[t];
    if (label != null) result.add(label);
    if (result.length >= maxCount) break;
  }
  return result;
}

/// Vérifie au boot que les mappings sont cohérents avec `allowedTags`.
/// Throw avec un message explicite si une entrée référence un tag inconnu —
/// signale la dérive AVANT que ça pollue silencieusement le scoring.
///
/// Vérifications :
/// 1. Tous les tags de `interestToTags` ∈ allowedTags
/// 2. Tous les tags de `travelerTypeToTags` ∈ allowedTags
/// 3. Tous les tags de `allowedTags` ont un `tagToFrLabel`
void validateMappings(Set<String> allowedTags) {
  final issues = <String>[];

  for (final entry in interestToTags.entries) {
    for (final t in entry.value) {
      if (!allowedTags.contains(t)) {
        issues.add('interestToTags["${entry.key}"] : tag inconnu "$t"');
      }
    }
  }
  for (final entry in travelerTypeToTags.entries) {
    for (final t in entry.value) {
      if (!allowedTags.contains(t)) {
        issues.add('travelerTypeToTags["${entry.key}"] : tag inconnu "$t"');
      }
    }
  }
  for (final t in allowedTags) {
    if (!tagToFrLabel.containsKey(t)) {
      issues.add('tagToFrLabel : libellé FR manquant pour "$t"');
    }
  }

  if (issues.isNotEmpty) {
    throw StateError(
      'Mappings region_tags incohérents :\n  - ${issues.join("\n  - ")}',
    );
  }
}
