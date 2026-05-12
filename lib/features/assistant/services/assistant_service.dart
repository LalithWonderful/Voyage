import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/features/assistant/models/assistant_message.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Erreur Gemini transitoire qu'on a déjà retentée — l'UI affiche un message
/// conversationnel sans exposer le détail technique.
class AssistantTransientException implements Exception {
  @override
  String toString() =>
      'Je suis débordé pour l\'instant 🙏 Réessaie dans quelques instants.';
}

bool _isTransientAiError(Object e) {
  final s = e.toString();
  return s.contains('[503]') ||
      s.contains('[429]') ||
      s.contains('[504]') ||
      s.contains('UNAVAILABLE') ||
      s.contains('overloaded') ||
      s.contains('SocketException') ||
      s.contains('TimeoutException') ||
      s.contains('Failed host lookup');
}

typedef AssistantGeminiTextGenerator =
    Future<String> Function({
      required String systemPrompt,
      required List<Content> contents,
    });

/// Service conversationnel dédié à l'écran Assistant. Distinct de
/// `AiSuggestionsService` car :
/// - sortie texte libre (pas `responseMimeType: 'application/json'`),
/// - prend un historique de tours pour le multi-turn,
/// - système prompt construit dynamiquement depuis le voyage sélectionné +
///   profil utilisateur,
/// - pas de cache (chaque tour change le hash → useless), mais on peut cacher
///   les données de contexte amont (déjà fait par `tripsProvider` etc.).
class AssistantService {
  final LiveApiGuards _guards;
  final AssistantGeminiTextGenerator? _geminiTextGenerator;

  AssistantService({
    LiveApiGuards? guards,
    AssistantGeminiTextGenerator? geminiTextGenerator,
  }) : _guards = guards ?? LiveApiGuards.fromEnvironment(),
       _geminiTextGenerator = geminiTextGenerator;

  /// Construit le system prompt avec la voix Lunao et le contexte voyage.
  /// Public pour pouvoir être testé/inspecté isolément.
  ///
  /// `extraContext` est un bloc DATA optionnel injecté juste avant la fin —
  /// utilisé pour fournir des estimations/calculs Lunao déterministes (ex:
  /// budget) que Gemini doit reformuler sans les modifier.
  String buildSystemPrompt({
    required Trip? trip,
    required String? travelerType,
    required List<String> interests,
    required List<TripActivity> activities,
    String? extraContext,
  }) {
    final buf = StringBuffer();
    buf.writeln(
      "Tu es Lunao, le compagnon de voyage personnel de l'utilisateur. "
      "Tu réponds en français, à la première personne, comme un ami qui s'y connaît en voyage. "
      "Tu ne te présentes JAMAIS comme une IA, un assistant virtuel, un chatbot, "
      "ni ne mentionnes Gemini, Google, ou un modèle de langage. Si on te demande "
      "qui tu es, tu dis simplement \"Je suis Lunao, ton compagnon de voyage\".",
    );
    buf.writeln();
    buf.writeln("Style :");
    buf.writeln(
      "- Réponses courtes (3-5 phrases) sauf si l'utilisateur demande du détail.",
    );
    buf.writeln(
      "- Concret, pratique, chaleureux. Évite le marketing et le jargon.",
    );
    buf.writeln(
      "- Texte simple : pas de titres markdown (#, ##), pas de **gras** "
      "ou *italique*, pas de blocs code (```), pas de tableaux. Tu peux utiliser "
      "des phrases courtes, des retours à la ligne, et des tirets simples (- ou •) "
      "pour structurer. Les emojis ponctuels sont OK.",
    );
    buf.writeln(
      "- Pas de listes interminables — 3 à 5 items max si tu listes.",
    );
    buf.writeln(
      "- Pose une question de clarification UNIQUEMENT si l'info nécessaire "
      "n'est pas dans le bloc CONTEXTE LUNAO plus bas. Ne demande jamais une "
      "information déjà connue (profil, destination, dates, durée, budget, "
      "intérêts, étapes, hébergement...).",
    );
    buf.writeln();
    buf.writeln("Règles sur la personnalisation :");
    buf.writeln(
      "- Tu DOIS exploiter le bloc CONTEXTE LUNAO pour personnaliser tes "
      "réponses. Pas de réponse générique quand des préférences utilisateur "
      "sont disponibles.",
    );
    buf.writeln(
      "- Quand tu fais une recommandation, explique brièvement pourquoi "
      "elle correspond au profil ou aux préférences voyage (ex: \"je te propose "
      "ce quartier parce qu'il colle à tes intérêts gastro et bons plans\").",
    );
    buf.writeln(
      "- Si une préférence du voyage contredit le profil global, "
      "privilégie la préférence du voyage.",
    );
    buf.writeln();
    buf.writeln("Règles strictes sur les chiffres :");
    buf.writeln(
      "- Si un bloc DONNÉES (calculées par Lunao) est fourni, tu réutilises "
      "EXACTEMENT les chiffres et verdicts qui y figurent. Tu ne les inventes "
      "ni ne les modifies. Tu peux les expliquer, les commenter, et proposer "
      "des variations qualitatives (\"version budget serré\", \"confort\", \"plaisir\").",
    );
    buf.writeln(
      "- Si une donnée chiffrée n'est pas fournie, tu signales son absence "
      "plutôt que d'inventer un chiffre.",
    );
    buf.writeln();
    buf.writeln("Limites actuelles :");
    buf.writeln(
      "- Tu ne peux PAS modifier le planning, créer/supprimer un voyage, "
      "ou ajouter des activités automatiquement. Tu peux seulement informer, "
      "conseiller, comparer, suggérer.",
    );
    buf.writeln(
      "- Si on te demande une action, explique gentiment où l'utilisateur peut "
      "le faire dans l'app (planning, wallet, profil...).",
    );
    buf.writeln();

    buf.writeln("CONTEXTE LUNAO");
    buf.writeln(
      "(toutes les infos ci-dessous sont déjà connues — ne les redemande pas)",
    );
    buf.writeln();

    if (travelerType != null && travelerType.isNotEmpty) {
      buf.writeln("Profil voyageur (global) :");
      buf.writeln("- Type : $travelerType");
      if (interests.isNotEmpty) {
        buf.writeln("- Centres d'intérêt : ${interests.join(', ')}");
      }
      buf.writeln();
    }

    if (trip == null) {
      buf.writeln(
        "Voyage : aucun voyage sélectionné. Aide l'utilisateur sur des conseils "
        "voyage généraux, comparaison de destinations, organisation d'idées. "
        "Encourage-le à créer un voyage quand il est prêt, pour des conseils "
        "plus précis.",
      );
    } else {
      buf.writeln(
        "Voyage en cours (les préférences du voyage priment sur le profil global) :",
      );
      buf.writeln(
        "- Destination : ${trip.destination}"
        "${trip.destinationCountryName != null ? ' (${trip.destinationCountryName})' : ''}",
      );
      if (trip.hasExactDates) {
        buf.writeln(
          "- Dates : du ${_fmtDate(trip.startDate)} au "
          "${_fmtDate(trip.endDate)} (${trip.durationDays} jours)",
        );
      } else if (trip.hasUnspecifiedPeriod) {
        buf.writeln(
          "- Dates : à préciser, durée prévue ${trip.durationDays} jours",
        );
      } else {
        final label = trip.targetPeriodLabel ?? 'période non précisée';
        buf.writeln(
          "- Période : ${trip.hasRecommendedPeriod ? 'recommandée — ' : ''}"
          "$label (${trip.durationDays} jours prévus)",
        );
      }
      if (trip.itinerarySegments.isNotEmpty) {
        final segs = trip.itinerarySegments
            .map((s) => "${s.city} (${s.days}j)")
            .join(', ');
        buf.writeln("- Étapes : $segs");
      }
      if (trip.travelers.isNotEmpty) {
        buf.writeln("- Voyageurs : ${trip.travelers.length}");
      }
      if (trip.budgetPerPersonEur != null) {
        buf.writeln(
          "- Budget : ${trip.budgetPerPersonEur}€ par personne"
          "${trip.budgetIncludesFlight == false ? ' (hors vol)' : ''}",
        );
      }
      if (trip.accommodation != null) {
        final a = trip.accommodation!;
        buf.writeln(
          "- Hébergement : ${a.name}"
          "${a.address != null && a.address!.isNotEmpty ? ' · ${a.address}' : ''}",
        );
      }

      if (activities.isNotEmpty) {
        buf.writeln();
        buf.writeln("Activités déjà planifiées :");
        // Cap à 20 activités pour éviter les prompts trop gros.
        final shown = activities.take(20).toList();
        for (final a in shown) {
          final time = a.startTime.isNotEmpty ? a.startTime : '—';
          buf.writeln("- ${_fmtDate(a.dayDate)} $time · ${a.title}");
        }
        if (activities.length > shown.length) {
          buf.writeln("- … et ${activities.length - shown.length} autre(s)");
        }
      }
    }

    if (extraContext != null && extraContext.isNotEmpty) {
      buf.writeln();
      buf.writeln(extraContext);
    }
    return buf.toString();
  }

  /// Envoie un nouveau message utilisateur en s'appuyant sur l'historique
  /// déjà tenu côté provider. Retourne le texte de réponse.
  ///
  /// `extraContext` permet d'injecter un bloc DONNÉES calculé par un
  /// estimateur Lunao (budget, etc.) pour cette tour spécifique.
  ///
  /// Throws [AssistantTransientException] si Gemini est indisponible après retry.
  Future<String> sendMessage({
    required List<AssistantMessage> history,
    required String userMessage,
    required Trip? trip,
    required String? travelerType,
    required List<String> interests,
    required List<TripActivity> activities,
    String? extraContext,
  }) async {
    _guards.assertAllowed(
      LiveApiFamily.gemini,
      operation: 'AssistantService.sendMessage',
    );
    if (AiConstants.geminiApiKey.isEmpty ||
        AiConstants.geminiApiKey == 'COLLE_TA_CLE_ICI') {
      throw Exception('Clé Gemini manquante.');
    }

    final systemPrompt = buildSystemPrompt(
      trip: trip,
      travelerType: travelerType,
      interests: interests,
      activities: activities,
      extraContext: extraContext,
    );
    debugPrint(
      '[assistant] system prompt: ${systemPrompt.length} chars · '
      'history: ${history.length} msgs · trip: ${trip?.destination ?? 'none'}'
      '${extraContext != null ? ' · with extra DATA' : ''}',
    );

    // L'historique : on prend les messages non-erreur, on alterne user/model.
    final contents = <Content>[];
    for (final m in history.where((m) => !m.isError)) {
      if (m.isUser) {
        contents.add(Content.text(m.text));
      } else {
        contents.add(Content.model([TextPart(m.text)]));
      }
    }
    contents.add(Content.text(userMessage));

    try {
      final raw = await _generateGeminiText(
        systemPrompt: systemPrompt,
        contents: contents,
      );
      if (raw.trim().isEmpty) {
        throw Exception('Réponse vide.');
      }
      return raw.trim();
    } catch (e) {
      if (_isTransientAiError(e)) throw AssistantTransientException();
      rethrow;
    }
  }

  Future<String> _generateGeminiText({
    required String systemPrompt,
    required List<Content> contents,
  }) async {
    final generator = _geminiTextGenerator;
    if (generator != null) {
      return generator(systemPrompt: systemPrompt, contents: contents);
    }

    final model = GenerativeModel(
      model: AiConstants.geminiModel,
      apiKey: AiConstants.geminiApiKey,
      systemInstruction: Content.system(systemPrompt),
      generationConfig: GenerationConfig(temperature: 0.8),
    );
    final res = await _generateWithRetry(model, contents);
    return res.text ?? '';
  }

  Future<GenerateContentResponse> _generateWithRetry(
    GenerativeModel model,
    List<Content> contents,
  ) async {
    try {
      return await model.generateContent(contents);
    } catch (e) {
      if (!_isTransientAiError(e)) rethrow;
      debugPrint('[assistant] transient error, retry in 2s: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
      return await model.generateContent(contents);
    }
  }

  static String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd/$mm';
  }
}
