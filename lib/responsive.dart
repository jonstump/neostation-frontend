import 'package:flutter/material.dart';

class Responsive extends StatelessWidget {
  final Widget handheldXS;
  final Widget handheldSmall;
  final Widget handheldMedium;
  final Widget handheldLarge;
  final Widget handheldXL;

  const Responsive({
    super.key,
    required this.handheldXS,
    required this.handheldSmall,
    required this.handheldMedium,
    required this.handheldLarge,
    required this.handheldXL,
  });

  // This size work fine on my design, maybe you need some customization depends on your design

  // Breakpoints tuned for high-DPI gaming devices
  static bool isHandheldXS(BuildContext context) =>
      MediaQuery.of(context).size.width < 560;

  static bool isHandheldSmall(BuildContext context) =>
      MediaQuery.of(context).size.width < 690 && // was 700
      MediaQuery.of(context).size.width >= 560;

  static bool isHandheldMedium(BuildContext context) =>
      MediaQuery.of(context).size.width <
          840 && // was 960 (lowered so the RP5 counts as Large)
      MediaQuery.of(context).size.width >= 690; // was 700

  static bool isHandheldLarge(BuildContext context) =>
      MediaQuery.of(context).size.width < 1280 && // was 1660
      MediaQuery.of(context).size.width >=
          840; // was 960 (lowered so the RP5 is included)

  static bool isHandheldXLarge(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1280; // was 1660

  // Alternative methods based on physical size (for high DPI)
  static bool isPhysicallyLarge(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final physicalWidth = mediaQuery.size.width * mediaQuery.devicePixelRatio;
    return physicalWidth >= 1920; // 1920 physical px
  }

  static int getSystemsCrossAxisCount(BuildContext context) {
    if (isHandheldXLarge(context)) return 7; // Very large desktop
    if (isHandheldLarge(context)) return 6; // Large desktop
    if (isHandheldMedium(context)) return 5; // Desktop/tablet
    if (isHandheldSmall(context)) return 4; // Tablet
    return 4; // Small mobile
  }

  /// Get the crossAxisCount for the games grid
  /// Game grids use more columns so that more content is shown
  static int getGamesCrossAxisCount(BuildContext context) {
    if (isHandheldXLarge(context)) return 5; // Very large desktop
    if (isHandheldLarge(context)) return 4; // Large desktop
    if (isHandheldMedium(context)) return 3; // Desktop/tablet
    if (isHandheldSmall(context)) return 2; // Tablet
    return 2; // Small mobile
  }

  /// Get the crossAxisCount for the settings grid
  /// Settings grids use fewer columns for better readability
  static int getSettingsCrossAxisCount(BuildContext context) {
    if (isHandheldXS(context)) return 1;
    if (isHandheldSmall(context)) return 2;
    if (isHandheldMedium(context)) return 3;
    if (isHandheldLarge(context)) return 3;
    if (isHandheldXLarge(context)) return 3;
    return 3; // Default fallback
  }

  /// Get the crossAxisCount for the scraper options grid
  /// The scraper options grid uses consistent values
  static int getScraperOptionsCrossAxisCount(BuildContext context) {
    if (isHandheldXS(context)) return 3; // Small mobile
    return 4; // Tablet and desktop use 4 columns
  }

  /// Get the crossAxisCount for the theme selection grid
  /// Theme selection grid, optimized for previews
  static int getThemesCrossAxisCount(BuildContext context) {
    if (isHandheldXLarge(context)) return 6; // Very large desktop
    if (isHandheldLarge(context)) return 5; // Large desktop
    if (isHandheldMedium(context)) return 4; // Desktop/tablet
    if (isHandheldSmall(context)) return 4; // Tablet
    return 4; // Small mobile
  }

  /// Generic function - defaults to systems (kept for compatibility)
  static int getCrossAxisCount(BuildContext context) {
    return getSystemsCrossAxisCount(context);
  }

  /// Converts the user's card size ('S', 'M', 'L', 'XL') into a column count.
  static int getSystemsCrossAxisCountFromSize(String size) {
    switch (size) {
      case 'S':
        return 7;
      case 'M':
        return 6;
      case 'L':
        return 5;
      case 'XL':
        return 4;
      default:
        return 6;
    }
  }

  /// Get the crossAxisCount for the Android apps grid
  /// 10 on large screens, fewer on small ones
  static int getAndroidAppsCrossAxisCount(BuildContext context) {
    if (isHandheldXLarge(context)) return 10;
    if (isHandheldLarge(context)) return 10;
    if (isHandheldMedium(context)) return 8;
    if (isHandheldSmall(context)) return 6;
    return 5; // HandheldXS
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    if (size.width >= 1280) {
      // was 1660
      return handheldXL;
    }
    // If our width is more than 840 then we consider it a handheldLarge (the RP5 lands here)
    if (size.width >= 840) {
      // was 960 (lowered so the RP5 is included)
      return handheldLarge;
    }
    // If width is between 690 and 840 we consider it as handheldMedium
    else if (size.width >= 690) {
      // was 700
      return handheldMedium;
    }
    // If width is between 560 and 690 we consider it as handheldSmall
    else if (size.width >= 560) {
      return handheldSmall;
    }
    // Or less than 560 we called it extra small
    else {
      return handheldXS;
    }
  }
}
