import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/features/assistant/models/assistant_message.dart';
import 'package:voyage/features/assistant/services/assistant_budget_estimator.dart';
import 'package:voyage/features/assistant/services/assistant_intent_detector.dart';
import 'package:voyage/features/assistant/services/assistant_service.dart';
import 'package:voyage/features/assistant/services/assistant_transport_advisor.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

final assistantServiceProvider = Provider<AssistantService>((ref) {
  return AssistantService();
});

/// ID du voyage sélectionné dans l'écran Assistant. `null` = mode général
/// (aucun voyage). Le default initial est calculé par `defaultAssistantTripId`
/// (voyage en cours, sinon prochain à venir, sinon null).
final selectedAssistantTripIdProvider = StateProvider<String?>((ref) => null);

/// Calcule le voyage par défaut à présélectionner :
/// 1. Un voyage en cours (today entre startDate et endDate)
/// 2. Sinon, le prochain à venir (startDate >= today, le plus proche)
/// 3. Sinon null (mode général)
String? defaultAssistantTripId(List<Trip> trips) {
  if (trips.isEmpty) return null;
  final today = DateTime.now();
  final t0 = DateTime(today.year, today.month, today.day);

  final inProgress = trips.where((t) {
    final start = DateTime(t.startDate.year, t.startDate.month, t.startDate.day);
    final end = DateTime(t.endDate.year, t.endDate.month, t.endDate.day);
    return !t0.isBefore(start) && !t0.isAfter(end);
  }).toList()
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  if (inProgress.isNotEmpty) return inProgress.first.id;

  final upcoming = trips.where((t) {
    final start = DateTime(t.startDate.year, t.startDate.month, t.startDate.day);
    return !start.isBefore(t0);
  }).toList()
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  if (upcoming.isNotEmpty) return upcoming.first.id;

  return null;
}

class AssistantConversationState {
  final List<AssistantMessage> messages;
  final bool isSending;

  const AssistantConversationState({
    this.messages = const [],
    this.isSending = false,
  });

  AssistantConversationState copyWith({
    List<AssistantMessage>? messages,
    bool? isSending,
  }) {
    return AssistantConversationState(
      messages: messages ?? this.messages,
      isSending: isSending ?? this.isSending,
    );
  }
}

class AssistantConversationNotifier
    extends StateNotifier<AssistantConversationState> {
  final Ref _ref;

  AssistantConversationNotifier(this._ref)
      : super(const AssistantConversationState());

  void reset() {
    state = const AssistantConversationState();
  }

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.isSending) return;

    final now = DateTime.now();
    final userMsg = AssistantMessage(
      role: 'user',
      text: trimmed,
      timestamp: now,
    );
    final history = state.messages;
    state = state.copyWith(
      messages: [...history, userMsg],
      isSending: true,
    );

    try {
      final selectedId = _ref.read(selectedAssistantTripIdProvider);
      final trips = await _ref.read(tripsProvider.future);
      final trip = selectedId == null
          ? null
          : trips.where((t) => t.id == selectedId).firstOrNull;

      // Profil utilisateur (best-effort — pas bloquant si absent)
      final profile = await _ref.read(userProfileProvider.future);
      final travelerType = trip?.travelerType ??
          (profile?['traveler_type'] as String?);
      final List<String> interests = trip?.interests ??
          await _ref.read(userInterestsProvider.future);

      // Activités du voyage si applicable
      final activities = trip == null
          ? const <TripActivity>[]
          : await _ref.read(tripActivitiesProvider(trip.id).future);

      // Bloc CONTEXTE TRANSPORT : toujours injecté quand un voyage est
      // sélectionné — évite que Gemini conseille un vol pour Metz.
      final transportBlock = trip == null
          ? null
          : AssistantTransportAdvisor()
              .compute(
                trip: trip,
                userHomeAirportFromProfile:
                    profile?['home_airport_iata'] as String?,
              )
              .toPromptBlock();

      // Détection d'intent + estimateurs déterministes Lunao avant Gemini.
      // Si un estimateur produit un résultat, on injecte le bloc DATA dans
      // le prompt — Gemini reformule sans inventer de chiffres.
      String? extraContext = transportBlock;
      final intent = AssistantIntentDetector.detect(trimmed);
      if (intent == AssistantIntent.budget && trip != null) {
        // Override par voyage si défini, sinon fallback profil.
        final homeAirport = trip.homeAirportIata ??
            (profile?['home_airport_iata'] as String?);
        final estimate = AssistantBudgetEstimator().estimate(
          trip: trip,
          travelerType: travelerType,
          interests: interests,
          homeAirport: homeAirport,
        );
        if (estimate != null) {
          // On concatène : transport (toujours) + budget (si dispo)
          extraContext = [
            ?transportBlock,
            estimate.toPromptBlock(),
          ].join('\n');
          debugPrint('[assistant] intent=budget, estimate injected '
              '(${estimate.totalMinPerPerson}-${estimate.totalAvgPerPerson} '
              '€/pers via ${estimate.baselineName}, '
              'reliability=${estimate.reliability})');
        } else {
          debugPrint('[assistant] intent=budget but no baseline for '
              '"${trip.destination}" — falling back to free convo');
        }
      }

      final service = _ref.read(assistantServiceProvider);
      final reply = await service.sendMessage(
        history: history,
        userMessage: trimmed,
        trip: trip,
        travelerType: travelerType,
        interests: interests,
        activities: activities,
        extraContext: extraContext,
      );

      state = state.copyWith(
        messages: [
          ...state.messages,
          AssistantMessage(
            role: 'assistant',
            text: reply,
            timestamp: DateTime.now(),
          ),
        ],
        isSending: false,
      );
    } on AssistantTransientException catch (e) {
      debugPrint('[assistant] transient: $e');
      state = state.copyWith(
        messages: [
          ...state.messages,
          AssistantMessage(
            role: 'assistant',
            text: e.toString(),
            timestamp: DateTime.now(),
            isError: true,
          ),
        ],
        isSending: false,
      );
    } catch (e) {
      debugPrint('[assistant] error: $e');
      state = state.copyWith(
        messages: [
          ...state.messages,
          AssistantMessage(
            role: 'assistant',
            text: "Désolé, je n'ai pas pu répondre. Réessaie dans un instant 🙏",
            timestamp: DateTime.now(),
            isError: true,
          ),
        ],
        isSending: false,
      );
    }
  }
}

final assistantConversationProvider = StateNotifierProvider<
    AssistantConversationNotifier, AssistantConversationState>((ref) {
  return AssistantConversationNotifier(ref);
});
