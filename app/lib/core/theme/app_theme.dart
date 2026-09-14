import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const Color stoksyncSeedColor = Color(0xFF3F51B5);

ThemeData buildStokSyncTheme(Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: stoksyncSeedColor,
      brightness: brightness,
    ),
    textTheme: GoogleFonts.interTextTheme(),
  );
}
