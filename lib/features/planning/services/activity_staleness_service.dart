/// V8 (Lalith 2026-05-10) — politique simplifiée de fraîcheur du
/// planning quand l'itinéraire mute structurellement.
///
/// Décision produit : les activités générées par Lunao
/// (`suggested = true`) sont **disposable**. Quand l'itinéraire change
/// (ajout/suppression/réordo de segment, apply timeline diff), on les
/// SUPPRIME tout de suite — pas de bandeau « obsolètes », pas de
/// restauration. Le voyageur régénère.
///
/// Préservées (jamais touchées par ce service) :
///  - activités créées manuellement (`suggested = false` via
///    `activity_create_sheet.dart`)
///  - activités importées d'un document daté (`suggested = false` via
///    `document_to_activity.dart` — billets, réservations partenaires)
///
/// Pour les activités utilisateur sortant des segments après mutation,
/// voir `findOrphanedActivities` (alimente la bannière « Activités
/// à replacer », logique séparée).
///
/// Historique : avant V8 on marquait `planning_status='stale'` pour
/// permettre une restauration. Cette UX a été retirée — trop de bruit
/// dans le planning pour peu de valeur. Les rows legacy avec
/// `planning_status='stale'` sont aussi nettoyées par
/// `deleteGeneratedActivitiesForTrip` (filtre `suggested=true` les
/// couvre — elles ont toutes été générées).
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
///    via `deleteGeneratedActivitiesForTrip` sur mutation structurelle).
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

/// V8 (Lalith 2026-05-10) — supprime DÉFINITIVEMENT les activités
/// générées par Lunao pour un voyage donné. À appeler à chaque
/// mutation structurelle de l'itinéraire (cf. `trip_edit_sheet.dart`,
/// `trip_segment_sync_service.dart`).
///
/// SAFETY : filtre strict `suggested = true`. Les activités créées
/// manuellement par l'utilisateur (`suggested = false`) et les
/// imports de documents (`suggested = false`) ne sont JAMAIS
/// touchés par cette fonction.
///
/// Couvre aussi les rows legacy avec `planning_status = 'stale'`
/// (V6 → V7) : elles ont toutes `suggested = true` par construction.
///
/// Retourne le nombre de lignes supprimées (= signal pour la snackbar).
Future<int> deleteGeneratedActivitiesForTrip(
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
