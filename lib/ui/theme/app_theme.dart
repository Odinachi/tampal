import 'package:flutter/material.dart';

class AppTheme {
  // Brand colors
  static const primaryColor = Color(0xFF3B82F6); // Electric Blue
  static const primaryLight = Color(0xFF60A5FA);
  static const primaryDark = Color(0xFF2563EB);
  static const accentColor = Color(0xFF38BDF8); // Sky
  static const violetColor = Color(0xFF818CF8); // Indigo
  static const emeraldColor = Color(0xFF10B981); // Emerald
  
  // Surfaces & Backgrounds
  static const darkBg = Color(0xFF0C0D11); // Studio Obsidian
  static const surfaceDark = Color(0xFF101217); // Elevated surface
  static const darkCard = Color(0xFF14151D); // Card surface
  static const darkCardHover = Color(0xFF181A23); // Hover state
  static const glassBorder = Color(0xFF1E222E); // Clean slate border
  static const glassBorderHover = Color(0xFF2B3040); // Active border

  // Status colors
  static const successColor = Color(0xFF10B981);
  static const warningColor = Color(0xFFF59E0B);
  static const errorColor = Color(0xFFEF4444);

  // Typography colors
  static const textPrimary = Color(0xFFEDEDED);
  static const textSecondary = Color(0xFF8E93A4);
  static const textMuted = Color(0xFF525768);

  // Gradients
  static const primaryGradient = LinearGradient(
    colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const cyanGradient = LinearGradient(
    colors: [Color(0xFF1E222E), Color(0xFF14151D)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const surfaceGradient = LinearGradient(
    colors: [Color(0xFF14151D), Color(0xFF0F1016)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        secondary: accentColor,
        surface: darkCard,
        error: errorColor,
        onPrimary: Colors.white,
        onSurface: Color(0xFFF1F5F9),
      ),
      cardTheme: const CardThemeData(
        color: darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: Color(0xFF334155), width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFFF8FAFC),
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: Color(0xFF94A3B8)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFF1F5F9),
          side: const BorderSide(color: Color(0xFF475569)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1E293B),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryLight, width: 1.5),
        ),
        hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF1E293B),
        contentTextStyle: const TextStyle(color: Color(0xFFF8FAFC)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF475569)),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
