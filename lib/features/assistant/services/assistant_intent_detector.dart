/// Intentions reconnues par l'assistant. V1 : détection par mots-clés FR.
/// Permet à `AssistantService` d'appeler des estimateurs déterministes Lunao
/// AVANT Gemini, plutôt que de laisser Gemini halluciner des chiffres.
enum AssistantIntent {
  /// Question sur le budget / coût / prix d'un voyage.
  budget,
  /// Conversation libre — Gemini répond avec le contexte voyage uniquement.
  general,
}

class AssistantIntentDetector {
  /// Patterns FR pour détecter une question budget. Cherche en lowercase
  /// accent-insensible. Volontairement large : faux positifs OK (l'estimateur
  /// retourne null si pas de baseline et on retombe sur conversation libre).
  static final _budgetKeywords = <String>[
    'budget',
    'cout',
    'cou^t',
    'couter',
    'coutera',
    'couterait',
    'combien',
    'prix',
    'cher',
    'chere',
    'depens',
    'depense',
    'depenser',
    'tarif',
    'argent',
    'economi',
  ];

  static AssistantIntent detect(String userMessage) {
    final norm = _normalize(userMessage);
    if (_budgetKeywords.any(norm.contains)) return AssistantIntent.budget;
    return AssistantIntent.general;
  }

  static String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[àâä]'), 'a')
        .replaceAll(RegExp(r'[ïî]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ûü]'), 'u')
        .replaceAll('ç', 'c');
  }
}
