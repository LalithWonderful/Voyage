import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';

class AssistantScreen extends StatelessWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Assistant', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(color: AppColors.border, height: 1)),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              _BotMsg('Bonjour Lalith 👋 Je suis votre assistant voyage. Je connais votre profil (Road-trip · Esthétique · Nightlife) et vos voyages à venir. Comment puis-je vous aider ?'),
              _UserMsg('Quel est le meilleur quartier pour dormir à Lisbonne pour le nightlife ?'),
              _BotMsg('Pour le nightlife à Lisbonne, je recommande :\n\n🌙 Bairro Alto — bars animés, terrasses, idéal pour votre profil\n🎶 Cais do Sodré — clubs jusqu\'à l\'aube\n📸 LX Factory — soirées branchées le week-end\n\nJe peux ajouter une de ces zones à votre planning du soir ?'),
              _UserMsg('Oui, ajoute LX Factory le samedi soir.'),
              _BotMsg('✅ LX Factory ajouté au planning du samedi 2 mai à 20:00. J\'ai aussi trouvé un bon plan : entrée gratuite avant 22h le samedi !'),
            ],
          ),
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              color: AppColors.surface,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    const Expanded(child: TextField(
                      decoration: InputDecoration(hintText: 'Posez votre question...', border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                      style: TextStyle(fontSize: 13),
                    )),
                    const SizedBox(width: 8),
                    Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primary),
                      child: const Icon(Icons.send, color: Colors.white, size: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
      decoration: BoxDecoration(color: AppColors.primary, borderRadius: const BorderRadius.only(topLeft: Radius.circular(14), topRight: Radius.circular(14), bottomLeft: Radius.circular(14), bottomRight: Radius.circular(4))),
      child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.4)),
    ),
  );
}

class _BotMsg extends StatelessWidget {
  final String text;
  const _BotMsg(this.text);
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10, right: 48),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: const BorderRadius.only(topLeft: Radius.circular(14), topRight: Radius.circular(14), bottomLeft: Radius.circular(4), bottomRight: Radius.circular(14))),
      child: Text(text, style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.4)),
    ),
  );
}
