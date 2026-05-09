/// V5.2 (Lalith 2026-05-10) — état session des « Étapes à replacer »
/// après une mise à jour depuis documents.
///
/// Quand `applyTimelineDiff` ré-écrit l'itinéraire avec un squelette
/// doc-derived propre, les étapes manuelles / suggestions précédentes
/// (Tokyo, Kyoto, Krabi, Rayong, Ninh Bình…) ne sont PAS auto-replacées
/// pour ne pas casser les dates pinnées des documents (cf. décision
/// produit Lot C). Elles sont mises de côté ici, par voyage, pour que
/// l'utilisateur puisse les recréer via le segment editor pré-rempli.
///
/// Portée :
///  - en mémoire uniquement (StateProvider local)
///  - se vide à un kill d'app
///  - se vide aussi quand un nouvel apply a lieu (= le set est remplacé)
///
/// Trade-off accepté : si l'utilisateur tue l'app entre l'apply et la
/// recréation manuelle, il perd la liste. Acceptable comme MVP avant
/// une vraie persistance en DB (cf. backlog Lot C → option A).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Liste des segments « à replacer » pour un voyage donné, en mémoire
/// pour la session courante. Clé = trip.id.
final unplacedSegmentsProvider =
    StateProvider.family<List<TripSegment>, String>(
  (ref, tripId) => const [],
);
