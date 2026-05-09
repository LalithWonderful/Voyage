/// V4 (Lalith 2026-05-10) — gestion de la « fraîcheur » du planning
/// d'activités quand l'itinéraire de séjour change structurellement.
///
/// Règle produit non-négociable : un planning généré par Lunao est lié
/// à une structure d'étapes précise (villes, ordre, durées, dates).
/// Quand cette structure change (ajout/suppression/réordonnancement,
/// apply d'un diff transport, etc.), le planning généré DEVIENT stale.
///
/// Politique MVP retenue : on **supprime** les activités générées
/// (`suggested = true`) au lieu de les marquer stale. Plus simple et
/// suffisant pour un dirigeant produit qui veut éviter les corruptions
/// silencieuses. Le voyageur régénère depuis l'écran planning.
///
/// Préservées :
///  - activités créées manuellement (`suggested = false` via
///    `activity_create_sheet.dart`)
///  - activités importées d'un document daté (`suggested = false` via
///    `document_to_activity.dart` — billets, réservations partenaires)
///
/// Hors scope MVP (peut venir plus tard) :
///  - liste « Activités à replacer » pour les manuels qui ne fittent
///    plus la nouvelle structure
///  - warnings de conflit pour les imports tombés sur une étape
///    supprimée
library;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Compare deux listes de segments et retourne `true` si la structure
/// diffère (longueur, villes ou durées). Les autres champs (lat/lng,
/// `sourceAnchorCity`, etc.) ne comptent PAS — ils ne changent pas
/// l'expérience temporelle du voyage.
///
/// Comparaison case-sensitive sur city : si l'utilisateur ne fait que
/// reformater "bangkok" → "Bangkok", on considère que la structure n'a
/// pas changé (pas de raison de blast le planning).
bool segmentsStructurallyDiffer(List<TripSegment> a, List<TripSegment> b) {
  if (a.length != b.length) return true;
  for (var i = 0; i < a.length; i++) {
    if (a[i].city != b[i].city) return true;
    if (a[i].days != b[i].days) return true;
  }
  return false;
}

/// Supprime les activités GÉNÉRÉES par Lunao pour un voyage donné
/// (`suggested = true`). Les activités utilisateur et les imports de
/// documents (`suggested = false`) sont préservés.
///
/// Retourne le nombre de lignes supprimées (utile pour la feedback
/// utilisateur — « 12 activités générées ont été réinitialisées »).
Future<int> clearGeneratedActivitiesForTrip(
  SupabaseClient client,
  String tripId,
) async {
  final deleted = await client
      .from('trip_activities')
      .delete()
      .eq('trip_id', tripId)
      .eq('suggested', true)
      .select();
  return (deleted as List).length;
}
