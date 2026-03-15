import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class KodaColors {
  KodaColors._();

  static const bg      = Color(0xFF090B0E);
  static const panel   = Color(0xFF0E1117);
  static const panel2  = Color(0xFF13181F);
  static const border  = Color(0xFF1C2530);
  static const border2 = Color(0xFF253040);
  static const amber   = Color(0xFFF59E0B);
  static const amberD  = Color(0xFFD97706);
  static const amberL  = Color(0xFFFCD34D);
  static const red     = Color(0xFFEF4444);
  static const green   = Color(0xFF22C55E);
  static const blue    = Color(0xFF3B82F6);
  static const dim     = Color(0xFF3A4A5A);
  static const sub     = Color(0xFF607080);
  static const text    = Color(0xFFC8D8E8);
  static const white   = Color(0xFFEEF4FC);
}

class KodaTheme {
  KodaTheme._();

  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: KodaColors.bg,
    colorScheme: const ColorScheme.dark(
      primary:    KodaColors.amber,
      secondary:  KodaColors.blue,
      surface:    KodaColors.panel,
      error:      KodaColors.red,
    ),
    textTheme: GoogleFonts.barlowTextTheme(
      ThemeData.dark().textTheme,
    ).copyWith(
      displayLarge: GoogleFonts.barlowCondensed(
        color: KodaColors.white,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
      ),
      bodyMedium: GoogleFonts.barlow(
        color: KodaColors.text,
        fontSize: 13,
      ),
      labelSmall: GoogleFonts.shareTechMono(
        color: KodaColors.sub,
        fontSize: 10,
        letterSpacing: 2,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: KodaColors.panel,
      elevation: 0,
      titleTextStyle: GoogleFonts.barlowCondensed(
        color: KodaColors.white,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
      ),
      iconTheme: const IconThemeData(color: KodaColors.amber),
    ),
    dividerTheme: const DividerThemeData(
      color: KodaColors.border,
      thickness: 1,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: KodaColors.amber,
      inactiveTrackColor: KodaColors.border2,
      thumbColor: KodaColors.amber,
      overlayColor: KodaColors.amber.withOpacity(0.12),
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? KodaColors.bg : KodaColors.dim),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? KodaColors.amber : KodaColors.border2),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: KodaColors.panel,
      selectedItemColor: KodaColors.amber,
      unselectedItemColor: KodaColors.dim,
      type: BottomNavigationBarType.fixed,
    ),
    cardTheme: const CardThemeData(
      color: KodaColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: KodaColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KodaColors.panel2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: KodaColors.border2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: KodaColors.border2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: KodaColors.amber),
      ),
      labelStyle: GoogleFonts.shareTechMono(color: KodaColors.sub, fontSize: 11),
      hintStyle: GoogleFonts.shareTechMono(color: KodaColors.dim, fontSize: 11),
    ),
  );
}

// Text style helpers
TextStyle monoStyle({
  double size = 11,
  Color color = KodaColors.sub,
  FontWeight weight = FontWeight.normal,
  double spacing = 0,
}) =>
    GoogleFonts.shareTechMono(
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: spacing,
    );

TextStyle condensedStyle({
  double size = 16,
  Color color = KodaColors.white,
  FontWeight weight = FontWeight.w700,
  double spacing = 1,
}) =>
    GoogleFonts.barlowCondensed(
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: spacing,
    );

TextStyle bodyStyle({
  double size = 13,
  Color color = KodaColors.text,
  FontWeight weight = FontWeight.normal,
}) =>
    GoogleFonts.barlow(fontSize: size, color: color, fontWeight: weight);
