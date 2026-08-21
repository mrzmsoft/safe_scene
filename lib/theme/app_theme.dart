import 'package:flutter/material.dart';

import '../models/filter_segment.dart';

/// Semantic colour tokens for Safe Scene.
///
/// Every widget in the app should pull from this palette instead of inline
/// literals so the whole product stays consistent. The palette is deliberately
/// narrow and deep: a near-black navy base, one primary (signal sky) and one
/// accent (family teal), plus three action colours that map 1:1 to the rule
/// engine (`skip` / `mute` / `blackout`).
abstract final class AppColors {
  // ---- Surfaces (deepest → lightest) ------------------------------------
  /// Global app backdrop (player, landing page).
  static const background = Color(0xFF080B13);

  /// Default body surface (scaffolds, home page).
  static const surface = Color(0xFF0E141F);

  /// Raised panels (cards, dialogs, the scene editor rail).
  static const surfaceContainer = Color(0xFF141A27);

  /// Interactive fills (chips, input fields, hover fills).
  static const surfaceElevated = Color(0xFF1B2433);

  /// Translucent panel used over media (floating controls, tooltips).
  static const overlay = Color(0xFF0F1520);

  // ---- Hairlines ---------------------------------------------------------
  static const border = Color(0xFF233044);
  static const borderFaint = Color(0xFF1A2230);

  // ---- Text --------------------------------------------------------------
  static const textPrimary = Color(0xFFEFF3FA);
  static const textSecondary = Color(0xFFA9B3C6);
  static const textMuted = Color(0xFF67738A);
  static const textFaint = Color(0xFF46506A);

  // ---- Brand · signal sky ------------------------------------------------
  static const brand = Color(0xFF3FC6F2);
  static const brandStrong = Color(0xFF12A4E5);
  static const brandSoft = Color(0xFF8FE3FD);
  static const brandContainer = Color(0xFF0C3550);
  static const onBrand = Color(0xFF062A3A);

  // ---- Accent · family teal ----------------------------------------------
  static const accent = Color(0xFF43E5C8);
  static const onAccent = Color(0xFF03302A);
  static const accentContainer = Color(0xFF0C3D36);

  // ---- Semantic / action -------------------------------------------------
  /// Skip (nudity / explicit visuals) — red family.
  static const skip = Color(0xFFF87171);

  /// Mute (profanity) — amber family.
  static const mute = Color(0xFFFBBF24);

  /// Blackout — violet family.
  static const blackout = Color(0xFFA78BFA);

  static const danger = Color(0xFFF87171);
  static const success = Color(0xFF4ADE80);
}

/// Reusable gradients (brand moments, ambient glows, player scrims).
abstract final class AppGradients {
  /// Solid brand fill for primary actions / the app logo.
  static const brand = LinearGradient(
    colors: [Color(0xFF4CC9F6), Color(0xFF12A4E5)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Text highlight gradient.
  static const brandText = LinearGradient(
    colors: [Color(0xFF8FE3FD), Color(0xFF3FC6F2)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// A subtler, always-legible version of the brand fill for pills/chips.
  static const brandMuted = LinearGradient(
    colors: [Color(0xFF123A52), Color(0xFF0E2A3E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Player overlay scrims.
  static const scrimTop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xE6000000), Color(0x66000000), Colors.transparent],
    stops: [0.0, 0.45, 1.0],
  );

  static const scrimBottom = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, Color(0x66000000), Color(0xE6000000)],
    stops: [0.0, 0.55, 1.0],
  );
}

/// Corner radii used across the product.
abstract final class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;
}

/// The colour mapped to each rule [FilterAction]. Single source of truth so the
/// seek bar, scene editor, badges and counter cards never drift apart.
Color appActionColor(FilterAction action) => switch (action) {
      FilterAction.skip => AppColors.skip,
      FilterAction.mute => AppColors.mute,
      FilterAction.blackout => AppColors.blackout,
    };

/// The icon mapped to each rule [FilterAction].
IconData appActionIcon(FilterAction action) => switch (action) {
      FilterAction.skip => Icons.fast_forward,
      FilterAction.mute => Icons.volume_off,
      FilterAction.blackout => Icons.visibility_off,
    };

/// The full Material 3 dark theme for Safe Scene.
///
/// Everything downstream (dialogs, buttons, inputs, chips, snackbars…) is themed
/// here so screen code reads as layout + content instead of styling noise.
ThemeData buildAppTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.brand,
    onPrimary: AppColors.onBrand,
    primaryContainer: AppColors.brandContainer,
    onPrimaryContainer: AppColors.brandSoft,
    secondary: AppColors.accent,
    onSecondary: AppColors.onAccent,
    secondaryContainer: AppColors.accentContainer,
    onSecondaryContainer: Color(0xFFBDFBEE),
    error: AppColors.danger,
    onError: Color(0xFF3D0A0A),
    errorContainer: Color(0xFF42181C),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    outline: AppColors.border,
    outlineVariant: AppColors.borderFaint,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    splashFactory: InkRipple.splashFactory,

    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        height: 1.15,
        letterSpacing: -0.5,
        color: AppColors.textPrimary,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: -0.3,
        color: AppColors.textPrimary,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.25,
        color: AppColors.textPrimary,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: AppColors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: AppColors.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0.1,
        color: AppColors.textPrimary,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.55,
        color: AppColors.textSecondary,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: AppColors.textSecondary,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: AppColors.textMuted,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: AppColors.textPrimary,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: AppColors.textPrimary,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.6,
        color: AppColors.textMuted,
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: AppColors.onBrand,
        disabledBackgroundColor: AppColors.surfaceElevated,
        disabledForegroundColor: AppColors.textFaint,
        elevation: 0,
        shadowColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.brandSoft,
        disabledForegroundColor: AppColors.textFaint,
        side: BorderSide(color: AppColors.brand.withValues(alpha: 0.55)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.brandSoft,
        disabledForegroundColor: AppColors.textFaint,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        hoverColor: Colors.white.withValues(alpha: 0.07),
        highlightColor: Colors.white.withValues(alpha: 0.10),
        focusColor: Colors.white.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceElevated,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: const TextStyle(
        color: AppColors.textMuted,
        fontSize: 13,
        fontWeight: FontWeight.w400,
      ),
      labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      floatingLabelStyle: const TextStyle(
        color: AppColors.brandSoft,
        fontSize: 13,
      ),
      prefixIconColor: AppColors.textMuted,
      suffixIconColor: AppColors.textMuted,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        borderSide: const BorderSide(color: AppColors.brand, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        borderSide: const BorderSide(color: AppColors.danger, width: 1.4),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        borderSide: const BorderSide(color: AppColors.border),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.xl),
        side: const BorderSide(color: AppColors.border),
      ),
      titleTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      contentTextStyle: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 14,
        height: 1.5,
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 36, vertical: 36),
    ),

    cardTheme: CardThemeData(
      color: AppColors.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: const BorderSide(color: AppColors.borderFaint),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceElevated,
      selectedColor: AppColors.brand.withValues(alpha: 0.18),
      labelStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      showCheckmark: false,
    ),

    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: AppColors.overlay.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.border),
      ),
      textStyle: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceElevated,
      contentTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm + 2),
        side: const BorderSide(color: AppColors.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      width: 460,
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.brand.withValues(alpha: 0.16);
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.brandSoft;
          }
          return AppColors.textSecondary;
        }),
        iconColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.brandSoft;
          }
          return AppColors.textSecondary;
        }),
        side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm + 2),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: AppColors.brand,
      inactiveTrackColor: AppColors.border,
      thumbColor: AppColors.brandSoft,
      overlayColor: AppColors.brand.withValues(alpha: 0.16),
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      valueIndicatorColor: AppColors.surfaceElevated,
      valueIndicatorTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 11,
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.onBrand;
        return Colors.white70;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.brand;
        return AppColors.surfaceElevated;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return AppColors.border;
      }),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: AppColors.brand,
      linearTrackColor: AppColors.borderFaint,
      circularTrackColor: AppColors.borderFaint,
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: const BorderSide(color: AppColors.border),
      ),
      textStyle: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
    ),

    dividerTheme: const DividerThemeData(
      color: AppColors.borderFaint,
      thickness: 1,
      space: 1,
    ),

    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(4),
      thumbColor: const WidgetStatePropertyAll(AppColors.border),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      interactive: true,
    ),
  );
}