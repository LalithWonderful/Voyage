import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/assistant/providers/assistant_provider.dart';
import 'package:voyage/features/assistant/widgets/lunao_context_card.dart';
import 'package:voyage/features/assistant/widgets/trip_context_chip.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _hasInitDefault = false;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _initDefaultTripIfNeeded() {
    if (_hasInitDefault) return;
    final tripsAsync = ref.read(tripsProvider);
    tripsAsync.whenData((trips) {
      _hasInitDefault = true;
      final current = ref.read(selectedAssistantTripIdProvider);
      if (current != null) return;
      final defaultId = defaultAssistantTripId(trips);
      if (defaultId != null) {
        ref.read(selectedAssistantTripIdProvider.notifier).state = defaultId;
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _onSend() async {
    final text = _inputController.text;
    if (text.trim().isEmpty) return;
    _inputController.clear();
    await ref.read(assistantConversationProvider.notifier).sendMessage(text);
    _scrollToBottom();
  }

  String _greeting() {
    final selectedId = ref.watch(selectedAssistantTripIdProvider);
    if (selectedId == null) {
      return "Salut 👋 Je suis Lunao.\n\n"
          "Choisis un voyage en haut de l'écran pour que je puisse t'aider "
          "avec ton planning, tes idées, ton budget ou tes trajets.\n\n"
          "Tu peux aussi me poser une question générale sur un voyage.";
    }
    final trips = ref.watch(tripsProvider).valueOrNull ?? const [];
    final trip = trips.where((t) => t.id == selectedId).firstOrNull;
    if (trip == null) return "Salut 👋 Je suis Lunao.";
    return "Salut 👋 Je suis Lunao. Je peux t'aider sur ton voyage à "
        "${trip.destination} : planning, idées, budget, trajets ou conseils "
        "pratiques.";
  }

  @override
  Widget build(BuildContext context) {
    _initDefaultTripIfNeeded();
    final state = ref.watch(assistantConversationProvider);

    // Re-scroll quand un nouveau message arrive.
    ref.listen(assistantConversationProvider, (prev, next) {
      if (prev?.messages.length != next.messages.length) _scrollToBottom();
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Assistant',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        actions: [
          if (state.messages.isNotEmpty)
            IconButton(
              tooltip: 'Recommencer la conversation',
              icon: const Icon(Icons.refresh),
              onPressed: state.isSending
                  ? null
                  : () {
                      ref
                          .read(assistantConversationProvider.notifier)
                          .reset();
                    },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: AppColors.border, height: 1),
        ),
      ),
      body: Column(
        children: [
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: const [
                TripContextChip(),
              ],
            ),
          ),
          Container(color: AppColors.border, height: 1),
          const SizedBox(height: 12),
          const LunaoContextCard(),
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                _BotMsg(_greeting()),
                for (final m in state.messages)
                  m.isUser
                      ? _UserMsg(m.text)
                      : _BotMsg(m.text, isError: m.isError),
                if (state.isSending) const _TypingIndicator(),
              ],
            ),
          ),
          _Composer(
            controller: _inputController,
            isSending: state.isSending,
            onSend: _onSend,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      color: AppColors.surface,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !isSending,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Pose ta question...',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: isSending ? null : onSend,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSending
                      ? AppColors.textSecondary
                      : AppColors.primary,
                ),
                child: isSending
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send, color: Colors.white, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserMsg extends StatelessWidget {
  final String text;
  const _UserMsg(this.text);
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 48),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              height: 1.4,
            ),
          ),
        ),
      );
}

class _BotMsg extends StatelessWidget {
  final String text;
  final bool isError;
  const _BotMsg(this.text, {this.isError = false});
  @override
  Widget build(BuildContext context) {
    final bg = isError
        ? AppColors.error.withValues(alpha: 0.08)
        : AppColors.surface;
    final border = isError ? AppColors.error : AppColors.border;
    final color = isError ? AppColors.error : AppColors.textPrimary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, right: 48),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(14),
          ),
        ),
        child: SelectableText(
          text,
          style: TextStyle(fontSize: 13, color: color, height: 1.4),
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, right: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(14),
          ),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _Dot(opacity: _dotOpacity(i)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  double _dotOpacity(int i) {
    final t = (_ctrl.value + i * 0.2) % 1.0;
    // Simple bell : 0 → 1 → 0
    return (1 - (t - 0.5).abs() * 2).clamp(0.3, 1.0);
  }
}

class _Dot extends StatelessWidget {
  final double opacity;
  const _Dot({required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: AppColors.textSecondary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
