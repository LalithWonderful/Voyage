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
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/services/document_to_activity.dart';
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

/// V6 (Lalith 2026-05-10 — Lot E TODO 1) — détecte les activités
/// utilisateur dont la date de jour n'est plus couverte par aucun
/// segment de l'itinéraire (= « orphelines » après une mutation
/// structurelle).
///
/// Couvre le cas typique : l'utilisateur a ajouté « Dîner au Sirocco »
/// pour le jour 5 quand le voyage démarrait au 22/06 (= 26/06). Après
/// avoir réaligné le voyage sur 24/06 et raccourci Bangkok, le jour
/// 26/06 n'est plus dans le voyage → l'activité est orpheline.
///
/// Filtres :
///  - on IGNORE les `suggested = true` (Lunao les a déjà supprimées
///    via `clearGeneratedActivitiesForTrip` sur mutation structurelle).
///  - on IGNORE les activités virtuelles (ID starts with `doc:`,
///    cf. [virtualActivityPrefix]) — leur visibilité dépend du doc
///    parent, géré par `document_consistency.dart`.
///
/// Retourne uniquement les vraies activités utilisateur (table
/// `trip_activities`, `suggested = false`, ID natif) qui flottent
/// hors plage segments.
List<TripActivity> findOrphanedActivities({
  required List<TripActivity> activities,
  required List<TripSegment> segments,
  required DateTime tripStartDate,
}) {
  if (segments.isEmpty) return const [];
  // Pré-calcul des bornes des segments (date-only, fin exclusive).
  final ranges = <({DateTime start, DateTime end})>[];
  var offset = 0;
  for (final s in segments) {
    final start = _dateOnly(tripStartDate.add(Duration(days: offset)));
    final end = _dateOnly(tripStartDate.add(Duration(days: offset + s.days)));
    ranges.add((start: start, end: end));
    offset += s.days;
  }
  bool covered(DateTime day) {
    final d = _dateOnly(day);
    for (final r in ranges) {
      if (!d.isBefore(r.start) && d.isBefore(r.end)) return true;
    }
    return false;
  }
  return [
    for (final a in activities)
      if (!a.suggested &&
          !a.id.startsWith(virtualActivityPrefix) &&
          !covered(a.dayDate))
        a,
  ];
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// V6 (Lalith 2026-05-10 — Lot E TODO 3) — marque les activités
/// GÉNÉRÉES par Lunao comme `stale` (au lieu de les SUPPRIMER comme
/// dans le MVP V4). Les activités utilisateur et les imports de
/// documents (`suggested = false`) sont préservés tels quels.
///
/// Avantage : l'utilisateur peut consulter les activités obsolètes
/// dans une section dédiée (planning_screen) et les restaurer
/// individuellement si la mutation d'itinéraire les a invalidées à
/// tort. Un bouton « Régénérer le planning » les supprime
/// définitivement et lance une nouvelle suggestion.
///
/// Pré-requis DB : la colonne `planning_status` doit exister
/// (cf. supabase/sql/trip_activities_planning_status.sql).
///
/// Retourne le nombre de lignes marquées (= signal pour la snackbar).
Future<int> markGeneratedActivitiesStale(
  SupabaseClient client,
  String tripId,
) async {
  final updated = await client
      .from('trip_activities')
      .update({'planning_status': 'stale'})
      .eq('trip_id', tripId)
      .eq('suggested', true)
      .neq('planning_status', 'stale')
      .select();
  return (updated as List).length;
}

/// Alias rétrocompat pour le code non encore migré. À retirer dans une
/// session de cleanup ultérieure.
@Deprecated('Use markGeneratedActivitiesStale instead (V6 Lot E TODO 3)')
Future<int> clearGeneratedActivitiesForTrip(
  SupabaseClient client,
  String tripId,
) =>
    markGeneratedActivitiesStale(client, tripId);

/// Supprime DÉFINITIVEMENT les activités stale d'un voyage. Appelé
/// quand l'utilisateur clique « Régénérer le planning » ou « Tout
/// supprimer » dans la section « Activités obsolètes ».
Future<int> deleteStaleActivitiesForTrip(
  SupabaseClient client,
  String tripId,
) async {
  final deleted = await client
      .from('trip_activities')
      .delete()
      .eq('trip_id', tripId)
      .eq('planning_status', 'stale')
      .select();
  return (deleted as List).length;
}

/// Restore une activité stale en `planned`. Appelé quand l'utilisateur
/// clique « Restaurer » sur une activité obsolète qu'il veut récupérer.
Future<void> restoreStaleActivity(
  SupabaseClient client,
  String activityId,
) async {
  await client
      .from('trip_activities')
      .update({'planning_status': 'planned'})
      .eq('id', activityId)
      .eq('planning_status', 'stale');
}
