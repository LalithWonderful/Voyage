/// Un message dans la conversation avec Lunao.
/// Phase 1 : pas persisté (mémoire seulement, perdu au redémarrage app).
class AssistantMessage {
  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime timestamp;
  final bool isError;

  const AssistantMessage({
    required this.role,
    required this.text,
    required this.timestamp,
    this.isError = false,
  });

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
}
