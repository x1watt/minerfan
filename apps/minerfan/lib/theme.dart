import 'package:flutter/material.dart';

/// Accent colors offered in Settings (name, ARGB).
const accentColors = <(String, int)>[
  ('Orange', 0xFFFF6A13),
  ('Amber', 0xFFFFC107),
  ('Green', 0xFF00E676),
  ('Teal', 0xFF1DE9B6),
  ('Blue', 0xFF448AFF),
  ('Purple', 0xFFB388FF),
  ('Pink', 0xFFFF4081),
  ('Red', 0xFFFF5252),
  ('White', 0xFFEEEEEE),
];

const _card = Color(0xFF101010);
const _line = Color(0xFF222222);

/// True black with neutral grey surfaces and one accent color. Material 3
/// derives every surface from the seed color, which is what tinted the old
/// theme brown; here the surfaces are set explicitly and only controls use
/// the accent.
ThemeData blackTheme(Color accent) {
  final onAccent = accent.computeLuminance() > 0.45 ? Colors.black : Colors.white;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: Color.alphaBlend(accent.withAlpha(0x38), Colors.black),
    onPrimaryContainer: accent,
    secondary: accent,
    onSecondary: onAccent,
    secondaryContainer: const Color(0xFF262626),
    onSecondaryContainer: Colors.white,
    tertiary: accent,
    surface: Colors.black,
    onSurface: const Color(0xFFEDEDED),
    onSurfaceVariant: const Color(0xFFA0A0A0),
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF0A0A0A),
    surfaceContainer: _card,
    surfaceContainerHigh: const Color(0xFF161616),
    surfaceContainerHighest: const Color(0xFF1E1E1E),
    surfaceTint: Colors.transparent,
    outline: const Color(0xFF3A3A3A),
    outlineVariant: _line,
  );
  final indicator = Color.alphaBlend(accent.withAlpha(0x40), Colors.black);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    dividerTheme: const DividerThemeData(color: _line, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: _card,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: _line)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      indicatorColor: indicator,
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? accent : const Color(0xFF9E9E9E))),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.black,
      indicatorColor: indicator,
      selectedIconTheme: IconThemeData(color: accent),
      unselectedIconTheme: const IconThemeData(color: Color(0xFF9E9E9E)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: accent,
      unselectedLabelColor: const Color(0xFF9E9E9E),
      indicatorColor: accent,
      dividerColor: _line,
    ),
    listTileTheme: const ListTileThemeData(iconColor: Color(0xFFBDBDBD)),
    // Locked controls (while a miner runs) keep showing what is selected.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((st) {
        final off = st.contains(WidgetState.disabled);
        if (st.contains(WidgetState.selected)) return off ? const Color(0xFFBDBDBD) : onAccent;
        return off ? const Color(0xFF4A4A4A) : const Color(0xFF9E9E9E);
      }),
      trackColor: WidgetStateProperty.resolveWith((st) {
        if (st.contains(WidgetState.selected)) return st.contains(WidgetState.disabled) ? accent.withAlpha(0x80) : accent;
        return const Color(0xFF1A1A1A);
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected) ? Colors.transparent : const Color(0xFF3A3A3A)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected)
            ? Color.alphaBlend(accent.withAlpha(st.contains(WidgetState.disabled) ? 0x28 : 0x40), Colors.black)
            : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((st) {
          final off = st.contains(WidgetState.disabled);
          if (st.contains(WidgetState.selected)) return off ? accent.withAlpha(0xB0) : accent;
          return off ? const Color(0xFF616161) : const Color(0xFFBDBDBD);
        }),
        side: WidgetStateProperty.resolveWith((st) => BorderSide(
            color: st.contains(WidgetState.selected) ? accent.withAlpha(st.contains(WidgetState.disabled) ? 0x60 : 0xA0) : const Color(0xFF333333))),
      ),
    ),
  );
}
