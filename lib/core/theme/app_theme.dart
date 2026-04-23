import 'package:flutter/material.dart';

// Palette claire
class _LightColors {
  static const primary = Color(0xFF2563EB);
  static const primaryLight = Color(0xFFDBEAFE);
  static const primaryDark = Color(0xFF1E40AF);
  static const accent = Color(0xFFF59E0B);
  static const accentLight = Color(0xFFFEF3C7);
  static const background = Color(0xFFF8FAFC);
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);
  static const success = Color(0xFF10B981);
  static const error = Color(0xFFEF4444);
}

// Palette sombre (ajustée pour le contraste)
class _DarkColors {
  static const primary = Color(0xFF3B82F6);
  static const primaryLight = Color(0xFF1E3A8A); // bleu très sombre (pour les pills/badges)
  static const primaryDark = Color(0xFF60A5FA);
  static const accent = Color(0xFFF59E0B);
  static const accentLight = Color(0xFF78350F); // amber-900
  static const background = Color(0xFF0F172A); // slate-900
  static const surface = Color(0xFF1E293B); // slate-800
  static const textPrimary = Color(0xFFF1F5F9); // slate-100
  static const textSecondary = Color(0xFF94A3B8); // slate-400
  static const border = Color(0xFF334155); // slate-700
  static const success = Color(0xFF34D399);
  static const error = Color(0xFFF87171);
}

/// Palette d'application résolue dynamiquement selon le thème courant.
/// Pas `const` par construction — il faut retirer `const` sur les `TextStyle(color: AppColors.xxx)`.
class AppColors {
  static Brightness _brightness = Brightness.light;

  /// À appeler quand le thème système change (via le builder de MaterialApp).
  static void setBrightness(Brightness b) => _brightness = b;

  static bool get _dark => _brightness == Brightness.dark;

  static Color get primary => _dark ? _DarkColors.primary : _LightColors.primary;
  static Color get primaryLight => _dark ? _DarkColors.primaryLight : _LightColors.primaryLight;
  static Color get primaryDark => _dark ? _DarkColors.primaryDark : _LightColors.primaryDark;
  static Color get accent => _dark ? _DarkColors.accent : _LightColors.accent;
  static Color get accentLight => _dark ? _DarkColors.accentLight : _LightColors.accentLight;
  static Color get background => _dark ? _DarkColors.background : _LightColors.background;
  static Color get surface => _dark ? _DarkColors.surface : _LightColors.surface;
  static Color get textPrimary => _dark ? _DarkColors.textPrimary : _LightColors.textPrimary;
  static Color get textSecondary => _dark ? _DarkColors.textSecondary : _LightColors.textSecondary;
  static Color get border => _dark ? _DarkColors.border : _LightColors.border;
  static Color get success => _dark ? _DarkColors.success : _LightColors.success;
  static Color get error => _dark ? _DarkColors.error : _LightColors.error;
}

class AppTheme {
  static ThemeData get light => _buildLight();
  static ThemeData get dark => _buildDark();

  static ThemeData _buildLight() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _LightColors.primary,
          primary: _LightColors.primary,
          secondary: _LightColors.accent,
          surface: _LightColors.surface,
          error: _LightColors.error,
        ),
        scaffoldBackgroundColor: _LightColors.background,
        fontFamily: 'Inter',
        appBarTheme: const AppBarTheme(
          backgroundColor: _LightColors.surface,
          foregroundColor: _LightColors.textPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: _LightColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _LightColors.border),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _LightColors.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _LightColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _LightColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _LightColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _LightColors.primary, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: _LightColors.surface,
          selectedItemColor: _LightColors.primary,
          unselectedItemColor: _LightColors.textSecondary,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        dividerColor: _LightColors.border,
      );

  static ThemeData _buildDark() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _DarkColors.primary,
          brightness: Brightness.dark,
          primary: _DarkColors.primary,
          secondary: _DarkColors.accent,
          surface: _DarkColors.surface,
          error: _DarkColors.error,
        ),
        scaffoldBackgroundColor: _DarkColors.background,
        fontFamily: 'Inter',
        appBarTheme: const AppBarTheme(
          backgroundColor: _DarkColors.surface,
          foregroundColor: _DarkColors.textPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: _DarkColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _DarkColors.border),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _DarkColors.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _DarkColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _DarkColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _DarkColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _DarkColors.primary, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: _DarkColors.surface,
          selectedItemColor: _DarkColors.primary,
          unselectedItemColor: _DarkColors.textSecondary,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        dividerColor: _DarkColors.border,
      );
}
