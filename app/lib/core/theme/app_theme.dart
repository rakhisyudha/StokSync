import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const Color stoksyncPrimaryLight = Color(0xFF2563EB);
const Color stoksyncPrimaryDark = Color(0xFF8DB5FF);
const Color stoksyncCanvasLight = Color(0xFFF7F9FC);
const Color stoksyncCanvasDark = Color(0xFF0A1020);
const Color stoksyncSurfaceLight = Color(0xFFFFFFFF);
const Color stoksyncSurfaceDark = Color(0xFF111A2C);
const Color stoksyncSurfaceContainerLight = Color(0xFFEEF2F7);
const Color stoksyncSurfaceContainerDark = Color(0xFF17243A);
const Color stoksyncOnSurfaceLight = Color(0xFF152238);
const Color stoksyncOnSurfaceDark = Color(0xFFF8FAFC);
const Color stoksyncOnSurfaceVariantLight = Color(0xFF526073);
const Color stoksyncOnSurfaceVariantDark = Color(0xFFC1CBD9);
const Color stoksyncOutlineLight = Color(0xFFCBD5E1);
const Color stoksyncOutlineDark = Color(0xFF405069);
const Color stoksyncErrorLight = Color(0xFFC9362B);
const Color stoksyncErrorDark = Color(0xFFFFB4AB);

const double stoksyncSpace4 = 4;
const double stoksyncSpace8 = 8;
const double stoksyncSpace12 = 12;
const double stoksyncSpace16 = 16;
const double stoksyncSpace24 = 24;
const double stoksyncSpace32 = 32;
const double stoksyncSpace40 = 40;
const double stoksyncRadius12 = 12;
const double stoksyncRadius16 = 16;

// Retained as a compatibility symbol for callers from the first theme pass.
const Color stoksyncSeedColor = stoksyncPrimaryLight;

final class StokSyncSemanticColors
    extends ThemeExtension<StokSyncSemanticColors> {
  const StokSyncSemanticColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  @override
  StokSyncSemanticColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return StokSyncSemanticColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  StokSyncSemanticColors lerp(
    covariant ThemeExtension<StokSyncSemanticColors>? other,
    double t,
  ) {
    if (other is! StokSyncSemanticColors) {
      return this;
    }
    return StokSyncSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      onSuccessContainer: Color.lerp(
        onSuccessContainer,
        other.onSuccessContainer,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      onWarningContainer: Color.lerp(
        onWarningContainer,
        other.onWarningContainer,
        t,
      )!,
    );
  }
}

StokSyncSemanticColors _semanticColors(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return const StokSyncSemanticColors(
      success: Color(0xFF62D29A),
      onSuccess: Color(0xFF062B1B),
      successContainer: Color(0xFF124D36),
      onSuccessContainer: Color(0xFFB7F4D2),
      warning: Color(0xFFFFC56D),
      onWarning: Color(0xFF3D2000),
      warningContainer: Color(0xFF633600),
      onWarningContainer: Color(0xFFFFE0B2),
    );
  }
  return const StokSyncSemanticColors(
    success: Color(0xFF18794E),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFD5F5E3),
    onSuccessContainer: Color(0xFF063A25),
    warning: Color(0xFFA8550A),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFE6C7),
    onWarningContainer: Color(0xFF4A2100),
  );
}

ColorScheme _buildColorScheme(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return ColorScheme.dark(
      primary: stoksyncPrimaryDark,
      onPrimary: const Color(0xFF08245B),
      primaryContainer: const Color(0xFF183C81),
      onPrimaryContainer: const Color(0xFFD9E6FF),
      secondary: const Color(0xFF9FC9FF),
      onSecondary: const Color(0xFF062A4D),
      secondaryContainer: const Color(0xFF164A78),
      onSecondaryContainer: const Color(0xFFD5E9FF),
      tertiary: const Color(0xFFB8C5FF),
      onTertiary: const Color(0xFF202C61),
      tertiaryContainer: const Color(0xFF39477D),
      onTertiaryContainer: const Color(0xFFE0E5FF),
      error: stoksyncErrorDark,
      onError: const Color(0xFF5A0A04),
      errorContainer: const Color(0xFF7E2A23),
      onErrorContainer: const Color(0xFFFFDAD6),
      surface: stoksyncSurfaceDark,
      onSurface: stoksyncOnSurfaceDark,
      surfaceTint: stoksyncPrimaryDark,
      onSurfaceVariant: stoksyncOnSurfaceVariantDark,
      outline: stoksyncOutlineDark,
      outlineVariant: const Color(0xFF293852),
      inverseSurface: const Color(0xFFE6EBF4),
      onInverseSurface: const Color(0xFF17243A),
      inversePrimary: stoksyncPrimaryLight,
    ).copyWith(
      surfaceContainerLowest: stoksyncCanvasDark,
      surfaceContainerLow: const Color(0xFF0F1829),
      surfaceContainer: stoksyncSurfaceContainerDark,
      surfaceContainerHigh: const Color(0xFF1A2942),
      surfaceContainerHighest: const Color(0xFF20304B),
    );
  }
  return ColorScheme.light(
    primary: stoksyncPrimaryLight,
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFFDBEAFE),
    onPrimaryContainer: const Color(0xFF08245B),
    secondary: const Color(0xFF286B9E),
    onSecondary: const Color(0xFFFFFFFF),
    secondaryContainer: const Color(0xFFD3E9FF),
    onSecondaryContainer: const Color(0xFF062A4D),
    tertiary: const Color(0xFF4E5FA8),
    onTertiary: const Color(0xFFFFFFFF),
    tertiaryContainer: const Color(0xFFE0E5FF),
    onTertiaryContainer: const Color(0xFF202C61),
    error: stoksyncErrorLight,
    onError: const Color(0xFFFFFFFF),
    errorContainer: const Color(0xFFFFDAD6),
    onErrorContainer: const Color(0xFF410002),
    surface: stoksyncSurfaceLight,
    onSurface: stoksyncOnSurfaceLight,
    surfaceTint: stoksyncPrimaryLight,
    onSurfaceVariant: stoksyncOnSurfaceVariantLight,
    outline: stoksyncOutlineLight,
    outlineVariant: const Color(0xFFE0E6EE),
    inverseSurface: const Color(0xFF293548),
    onInverseSurface: const Color(0xFFF0F4FC),
    inversePrimary: stoksyncPrimaryDark,
  ).copyWith(
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF9FBFD),
    surfaceContainer: stoksyncSurfaceContainerLight,
    surfaceContainerHigh: const Color(0xFFE6EBF2),
    surfaceContainerHighest: const Color(0xFFDDE4ED),
  );
}

ThemeData buildStokSyncTheme(Brightness brightness) {
  final scheme = _buildColorScheme(brightness);
  final semantic = _semanticColors(brightness);
  final textTheme = GoogleFonts.interTextTheme().apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final compactShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  );
  final largeShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  );
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: scheme.outline),
  );
  final focusedFieldBorder = fieldBorder.copyWith(
    borderSide: BorderSide(color: scheme.primary, width: 2),
  );
  final errorFieldBorder = fieldBorder.copyWith(
    borderSide: BorderSide(color: scheme.error, width: 2),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? stoksyncCanvasDark
        : stoksyncCanvasLight,
    extensions: [semantic],
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: largeShape.copyWith(
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: focusedFieldBorder,
      errorBorder: errorFieldBorder,
      focusedErrorBorder: errorFieldBorder,
      labelStyle: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
      floatingLabelStyle: textTheme.bodyLarge?.copyWith(color: scheme.primary),
      hintStyle: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
      helperStyle: textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      errorStyle: textTheme.bodySmall?.copyWith(color: scheme.error),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: compactShape,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: compactShape,
        side: BorderSide(color: scheme.outline),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: compactShape,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: largeShape,
      elevation: 2,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primaryContainer,
      side: BorderSide(color: scheme.outlineVariant),
      shape: compactShape,
      labelStyle: textTheme.labelMedium?.copyWith(color: scheme.onSurface),
      secondaryLabelStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: largeShape,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: textTheme.bodyLarge?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
      behavior: SnackBarBehavior.floating,
      shape: compactShape,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
  );
}

StokSyncSemanticColors semanticColorsOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<StokSyncSemanticColors>() ??
      _semanticColors(theme.brightness);
}
