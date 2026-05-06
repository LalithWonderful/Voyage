import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/assistant/providers/assistant_provider.dart';
import 'package:voyage/features/assistant/services/assistant_transport_advisor.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/services/airport_city_overrides.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/widgets/trip_edit_sheet.dart';

/// Carte "Contexte utilisé par Lunao" — repliable. Affiche transparentement
/// les données sur lesquelles Lunao s'appuie pour répondre, et offre une
/// action de modification cohérente avec le contexte :
/// - Voyage sélectionné → ouvre la sheet d'édition de CE voyage
/// - Mode général → navigue vers /profile (préférences globales)
class LunaoContextCard extends ConsumerStatefulWidget {
  const LunaoContextCard({super.key});

  @override
  ConsumerState<LunaoContextCard> createState() => _LunaoContextCardState();
}

class _LunaoContextCardState extends ConsumerState<LunaoContextCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final selectedId = ref.watch(selectedAssistantTripIdProvider);
    final trips = ref.watch(tripsProvider).valueOrNull ?? const [];
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final globalInterests =
        ref.watch(userInterestsProvider).valueOrNull ?? const <String>[];

    final trip = selectedId == null
        ? null
        : trips.where((t) => t.id == selectedId).firstOrNull;

    final summary = _buildCompactSummary(trip, profile, globalInterests);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Contexte utilisé par Lunao',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                            letterSpacing: 0.4,
                          ),
                        ),
                        if (!_expanded) ...[
                          const SizedBox(height: 3),
                          Text(
                            summary,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textPrimary,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Container(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: trip == null
                  ? _buildGeneralBody(profile, globalInterests)
                  : _buildTripBody(trip, profile, globalInterests),
            ),
          ],
        ],
      ),
    );
  }

  // ─── COMPACT (replié) ─────────────────────────────────────────────────

  String _buildCompactSummary(
    Trip? trip,
    Map<String, dynamic>? profile,
    List<String> globalInterests,
  ) {
    final parts = <String>[];
    if (trip != null) {
      parts.add(trip.destination);
      final interests =
          trip.interests?.isNotEmpty == true ? trip.interests! : globalInterests;
      if (interests.isNotEmpty) {
        parts.addAll(interests.take(3));
      }
      if (trip.budgetPerPersonEur != null) {
        parts.add('${trip.budgetPerPersonEur!.toInt()} €/pers.');
      }
    } else {
      // Mode général : profil global
      final type = profile?['traveler_type'] as String?;
      if (type != null && type.isNotEmpty) parts.add(type);
      if (globalInterests.isNotEmpty) {
        parts.addAll(globalInterests.take(3));
      }
      if (parts.isEmpty) parts.add('Profil incomplet');
    }
    return parts.join(' · ');
  }

  // ─── DÉPLIÉ — voyage sélectionné ──────────────────────────────────────

  Widget _buildTripBody(
    Trip trip,
    Map<String, dynamic>? profile,
    List<String> globalInterests,
  ) {
    final voyageLine = _formatVoyageLine(trip);
    final advice = AssistantTransportAdvisor().compute(
      trip: trip,
      userHomeAirportFromProfile:
          profile?['home_airport_iata'] as String?,
    );
    final preferencesLine = _formatPreferencesLine(trip, profile);
    final tripInterests =
        trip.interests?.isNotEmpty == true ? trip.interests! : globalInterests;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('Voyage', voyageLine),
        const SizedBox(height: 10),
        _section('Départ & transport', advice.label),
        const SizedBox(height: 10),
        _section('Préférences du voyage', preferencesLine),
        const SizedBox(height: 10),
        _section(
          "Centres d'intérêt",
          tripInterests.isEmpty ? 'Aucun précisé' : tripInterests.join(' · '),
        ),
        const SizedBox(height: 12),
        _modifyButton(
          label: 'Modifier les préférences de ce voyage',
          onPressed: () => openTripEditSheet(context, ref, trip: trip),
        ),
      ],
    );
  }

  String _formatVoyageLine(Trip trip) {
    final segs = <String>[trip.destination];
    if (trip.hasExactDates) {
      segs.add(
          '${_fmtDate(trip.startDate)} → ${_fmtDate(trip.endDate)}');
    } else if (trip.hasUnspecifiedPeriod) {
      segs.add('Dates à préciser');
    } else if (trip.hasRecommendedPeriod) {
      segs.add('Recommandé : ${trip.targetPeriodLabel ?? '—'}');
    } else if (trip.targetPeriodLabel != null) {
      segs.add(trip.targetPeriodLabel!);
    }
    segs.add('${trip.durationDays} jours');
    return segs.join(' · ');
  }

  String _formatPreferencesLine(Trip trip, Map<String, dynamic>? profile) {
    final type = trip.travelerType ??
        (profile?['traveler_type'] as String?);
    final parts = <String>[];
    if (type != null && type.isNotEmpty) parts.add(type);
    if (trip.budgetPerPersonEur != null) {
      final budget = trip.budgetPerPersonEur!.toInt();
      final flightNote = trip.budgetIncludesFlight == false
          ? '(vol non inclus)'
          : '(vol inclus)';
      parts.add('Budget $budget €/pers. $flightNote');
    } else {
      parts.add('Budget non renseigné');
    }
    final travelers = trip.travelers.length;
    if (travelers > 1) parts.add('$travelers voyageurs');
    return parts.join(' · ');
  }

  // ─── DÉPLIÉ — mode général ────────────────────────────────────────────

  Widget _buildGeneralBody(
    Map<String, dynamic>? profile,
    List<String> globalInterests,
  ) {
    final type = (profile?['traveler_type'] as String?) ?? 'non précisé';
    final airport = (profile?['home_airport_iata'] as String?) ?? 'CDG';
    final profilLine =
        '$type · Aéroport par défaut ${_formatAirport(airport)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('Profil voyageur', profilLine),
        const SizedBox(height: 10),
        _section(
          "Centres d'intérêt",
          globalInterests.isEmpty
              ? 'Aucun précisé'
              : globalInterests.join(' · '),
        ),
        const SizedBox(height: 12),
        _modifyButton(
          label: 'Modifier mon profil voyageur',
          onPressed: () => context.go('/profile'),
        ),
      ],
    );
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────

  Widget _section(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            color: AppColors.textPrimary,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _modifyButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.edit, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  String _formatAirport(String iata) {
    final lookup = lookupAirport(iata);
    if (lookup == null) return iata;
    if (lookup.name != null && lookup.name!.isNotEmpty) {
      return '${lookup.city} ${lookup.name} — ${lookup.iata}';
    }
    return '${lookup.city} — ${lookup.iata}';
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}
