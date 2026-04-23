import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/core/services/currency_service.dart';
import 'package:voyage/core/services/notification_service.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

const _supportedLanguages = [
  (code: 'fr', label: 'Français'),
  (code: 'en', label: 'English'),
];

const _transportModes = [
  (code: 'walk', label: '🚶 À pied'),
  (code: 'bike', label: '🚴 Vélo'),
  (code: 'taxi', label: '🚕 Taxi / VTC'),
  (code: 'metro', label: '🚇 Métro / bus'),
  (code: 'car', label: '🚗 Voiture'),
  (code: 'train', label: '🚆 Train'),
];

const _themeModes = [
  (code: 'system', label: '🖥️ Système'),
  (code: 'light', label: '☀️ Clair'),
  (code: 'dark', label: '🌙 Sombre'),
];

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  static const _typeEmojis = {
    'Road-trip': '🚐',
    'Grand luxe': '✨',
    'Meilleur prix': '💰',
    'Backpack': '🎒',
    'En famille': '👨‍👩‍👧',
    'Voyage pro': '💼',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final profileAsync = ref.watch(userProfileProvider);
    final interestsAsync = ref.watch(userInterestsProvider);

    final profile = profileAsync.valueOrNull;
    final fullName = (profile?['full_name'] as String?) ??
        (user?.userMetadata?['full_name'] as String?) ??
        'Utilisateur';
    final avatarUrl = profile?['avatar_url'] as String?;
    final currency = (profile?['currency'] as String?) ?? 'EUR';
    final language = (profile?['language'] as String?) ?? 'fr';
    final travelerType = profile?['traveler_type'] as String?;
    final typeEmoji = _typeEmojis[travelerType] ?? '🧭';
    final transportMode = profile?['favorite_transport_mode'] as String?;
    final themeMode = (profile?['theme_mode'] as String?) ?? 'system';
    final notificationsEnabled = (profile?['notifications_enabled'] as bool?) ?? true;
    final interests = interestsAsync.valueOrNull ?? const <String>[];
    final interestsLabel = interests.isEmpty
        ? 'Aucun intérêt sélectionné'
        : (interests.length <= 3 ? interests.join(', ') : '${interests.take(3).join(', ')}...');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Profil', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(color: AppColors.border, height: 1)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: Column(children: [
            _Avatar(
              avatarUrl: avatarUrl,
              initial: fullName.isNotEmpty ? fullName[0].toUpperCase() : 'U',
              onTap: () => _pickAvatar(context, ref),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _editName(context, ref, fullName),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(fullName, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  const SizedBox(width: 6),
                  Icon(Icons.edit, size: 16, color: AppColors.textSecondary),
                ],
              ),
            ),
            Text(user?.email ?? '', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ])),
          const SizedBox(height: 24),
          _section('MON PROFIL VOYAGEUR', [
            _tile(context, typeEmoji, 'Type de voyageur', travelerType ?? 'Non défini', onTap: () => context.go('/onboarding/traveler-type')),
            _tile(context, '🎨', 'Centres d\'intérêt', interestsLabel, onTap: () => context.go('/onboarding/interests')),
          ]),
          const SizedBox(height: 16),
          _section('PRÉFÉRENCES', [
            _tile(
              context, '💱', 'Devise',
              _currencyLabel(currency),
              onTap: () => _pickCurrency(context, ref, currency),
            ),
            _tile(
              context, '🌍', 'Langue',
              _languageLabel(language),
              onTap: () => _pickLanguage(context, ref, language),
            ),
            _tile(
              context, '🚕', 'Mode de transport favori',
              transportMode == null ? 'Non défini' : _transportLabel(transportMode),
              onTap: () => _pickTransport(context, ref, transportMode),
            ),
            _tile(
              context, '🎨', 'Thème',
              _themeLabel(themeMode),
              onTap: () => _pickTheme(context, ref, themeMode),
            ),
            _switchTile(
              context, '🔔', 'Notifications',
              notificationsEnabled ? 'Activées' : 'Désactivées',
              value: notificationsEnabled,
              onChanged: (v) => _toggleNotifications(context, ref, v),
            ),
          ]),
          const SizedBox(height: 16),
          _section('COMPTE', [
            _tile(context, '🔒', 'Changer le mot de passe', '',
                onTap: () => _changePassword(context, ref)),
            _tile(context, '🚪', 'Se déconnecter', '', danger: true, onTap: () async {
              await ref.read(authServiceProvider).signOut();
              if (context.mounted) context.go('/login');
            }),
          ]),
        ],
      ),
    );
  }

  static String _currencyLabel(String code) {
    final match = supportedCurrencies.firstWhere(
      (c) => c.code == code,
      orElse: () => (code: code, label: code),
    );
    return match.label;
  }

  static String _languageLabel(String code) =>
      _supportedLanguages.firstWhere((l) => l.code == code, orElse: () => (code: code, label: code)).label;

  static String _transportLabel(String code) =>
      _transportModes.firstWhere((t) => t.code == code, orElse: () => (code: code, label: code)).label;

  static String _themeLabel(String code) =>
      _themeModes.firstWhere((t) => t.code == code, orElse: () => (code: code, label: code)).label;

  Future<void> _pickTheme(BuildContext context, WidgetRef ref, String current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _OptionsSheet(
        title: 'Thème',
        options: _themeModes.map((t) => (value: t.code, label: t.label)).toList(),
        currentValue: current,
      ),
    );
    if (picked != null && picked != current) {
      await _updateProfile(context, ref, {'theme_mode': picked});
    }
  }

  Future<void> _pickAvatar(BuildContext context, WidgetRef ref) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85, maxWidth: 600);
    if (picked == null) return;

    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;
      final bytes = await picked.readAsBytes();
      final ext = picked.path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final path = '$userId/avatar.$ext';
      await client.storage.from('avatars').uploadBinary(
        path, bytes,
        fileOptions: FileOptions(upsert: true, contentType: 'image/$ext'),
      );
      final url = '${client.storage.from('avatars').getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
      await client.from('user_profiles').update({'avatar_url': url}).eq('id', userId);
      ref.invalidate(userProfileProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Avatar mis à jour.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Modifier le nom'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nom complet'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogCtx, ctrl.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;
    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;
      await client.auth.updateUser(UserAttributes(data: {'full_name': newName}));
      await client.from('user_profiles').update({'full_name': newName}).eq('id', userId);
      ref.invalidate(userProfileProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _pickCurrency(BuildContext context, WidgetRef ref, String current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OptionsSheet(
        title: 'Devise',
        options: supportedCurrencies.map((c) => (value: c.code, label: c.label)).toList(),
        currentValue: current,
      ),
    );
    if (picked != null && picked != current) {
      await _updateProfile(context, ref, {'currency': picked});
    }
  }

  Future<void> _pickLanguage(BuildContext context, WidgetRef ref, String current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _OptionsSheet(
        title: 'Langue',
        options: _supportedLanguages.map((l) => (value: l.code, label: l.label)).toList(),
        currentValue: current,
      ),
    );
    if (picked != null && picked != current) {
      await _updateProfile(context, ref, {'language': picked});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Préférence enregistrée. Traduction complète à venir.')),
        );
      }
    }
  }

  Future<void> _pickTransport(BuildContext context, WidgetRef ref, String? current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _OptionsSheet(
        title: 'Transport favori',
        options: _transportModes.map((t) => (value: t.code, label: t.label)).toList(),
        currentValue: current ?? '',
      ),
    );
    if (picked != null && picked != current) {
      await _updateProfile(context, ref, {'favorite_transport_mode': picked});
    }
  }

  Future<void> _updateProfile(BuildContext context, WidgetRef ref, Map<String, dynamic> updates) async {
    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;
      await client.from('user_profiles').update(updates).eq('id', userId);
      ref.invalidate(userProfileProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Changer le mot de passe'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: newCtrl,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Nouveau mot de passe (min 6 car.)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirmer le nouveau mot de passe'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogCtx, true), child: const Text('Changer')),
        ],
      ),
    );
    if (result != true) return;
    final newPwd = newCtrl.text;
    final confirm = oldCtrl.text;
    if (newPwd.length < 6) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mot de passe trop court (min 6).')));
      }
      return;
    }
    if (newPwd != confirm) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Les deux saisies ne correspondent pas.')));
      }
      return;
    }
    try {
      await ref.read(supabaseProvider).auth.updateUser(UserAttributes(password: newPwd));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mot de passe mis à jour.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _toggleNotifications(BuildContext context, WidgetRef ref, bool enable) async {
    if (enable) {
      final granted = await NotificationService.instance.requestPermissions();
      if (!granted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Autorisation refusée. Active les notifications dans les réglages système.')),
        );
        return;
      }
    } else {
      await NotificationService.instance.cancelAll();
    }
    await _updateProfile(context, ref, {'notifications_enabled': enable});
  }

  Widget _switchTile(BuildContext context, String emoji, String title, String subtitle, {
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(children: [
      Text(emoji, style: const TextStyle(fontSize: 20)),
      const SizedBox(width: 14),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
          Text(subtitle, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      )),
      Switch(value: value, onChanged: onChanged, activeThumbColor: AppColors.primary),
    ]),
  );

  Widget _section(String title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12)),
        child: Column(children: children),
      ),
    ],
  );

  Widget _tile(BuildContext context, String emoji, String title, String subtitle, {bool danger = false, VoidCallback? onTap}) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 14),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: danger ? AppColors.error : AppColors.textPrimary)),
            if (subtitle.isNotEmpty) Text(subtitle, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        )),
        if (onTap != null && !danger) Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 18),
      ]),
    ),
  );
}

class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final String initial;
  final VoidCallback onTap;
  const _Avatar({this.avatarUrl, required this.initial, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 84, height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF4F46E5)]),
              image: avatarUrl != null
                  ? DecorationImage(image: NetworkImage(avatarUrl!), fit: BoxFit.cover)
                  : null,
            ),
            child: avatarUrl == null
                ? Center(child: Text(initial, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: Colors.white)))
                : null,
          ),
          Positioned(
            bottom: 0, right: 0,
            child: Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary,
                border: Border.all(color: AppColors.background, width: 2),
              ),
              child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionsSheet extends StatelessWidget {
  final String title;
  final List<({String value, String label})> options;
  final String currentValue;
  const _OptionsSheet({required this.title, required this.options, required this.currentValue});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(alignment: Alignment.centerLeft, child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (_, i) {
                final o = options[i];
                final selected = o.value == currentValue;
                return ListTile(
                  title: Text(o.label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
                  trailing: selected ? Icon(Icons.check, color: AppColors.primary) : null,
                  onTap: () => Navigator.pop(context, o.value),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

