import 'package:flutter/material.dart';

/// Shared presentation layer for everything around the island.
///
/// The board is deliberately the loud element: rich terrain, saturated player
/// colours, strong contrast. The interface around it is therefore built from
/// calm parchment surfaces and a single teal accent, so it frames the board
/// rather than competing with it. Everything here is layout-neutral — these are
/// surfaces, colours and spacing only, so applying them cannot change what any
/// control does.

const hudInk = Color(0xff1f3a34);
const hudMuted = Color(0xff5f7570);
const hudTeal = Color(0xff256f61);
const hudGold = Color(0xffc98f2c);
const hudSurface = Color(0xfffffdf7);
const hudSurfaceSunk = Color(0xfff2efe3);
const hudBorder = Color(0xffe3ddca);
const hudBackgroundTop = Color(0xfff8f5ed);
const hudBackgroundBottom = Color(0xffe9efe8);

/// Soft, low-contrast elevation. Board pieces cast hard shadows; panels do not,
/// which keeps the depth cue meaningful where it matters.
const hudShadow = [
  BoxShadow(color: Color(0x12203028), blurRadius: 18, offset: Offset(0, 6)),
  BoxShadow(color: Color(0x0a203028), blurRadius: 3, offset: Offset(0, 1)),
];

BorderRadius get hudRadius => BorderRadius.circular(18);

/// One theme applied once at the top of the game screen. Restyling through the
/// theme rather than per-widget means every existing Card, Chip, button, sheet
/// and dialog is upgraded without its call site — and therefore its behaviour,
/// keys and semantics — being touched at all.
ThemeData hudTheme(BuildContext context) {
  final base = Theme.of(context);
  final scheme = base.colorScheme.copyWith(
    primary: hudTeal,
    secondary: hudGold,
    surface: hudSurface,
    onSurface: hudInk,
  );
  OutlinedBorder shape([double radius = 18]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: hudBackgroundTop,
    dividerTheme: const DividerThemeData(
      color: hudBorder,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: hudSurface,
      // Matches HudPanel's lift, so panels built either way sit on the same
      // plane rather than reading as two different surfaces.
      elevation: 2,
      shadowColor: hudInk.withValues(alpha: 0.22),
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: hudRadius,
        side: const BorderSide(color: hudBorder),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: hudSurfaceSunk,
      selectedColor: hudTeal.withValues(alpha: 0.16),
      side: const BorderSide(color: hudBorder),
      shape: shape(12),
      labelStyle: const TextStyle(
        color: hudInk,
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: hudTeal,
        side: const BorderSide(color: hudTeal, width: 1.4),
        shape: shape(14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: hudTeal,
        foregroundColor: Colors.white,
        shape: shape(14),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: hudTeal,
        shape: shape(12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: hudSurfaceSunk,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: hudBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: hudBorder),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: hudSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: hudSurface,
      surfaceTintColor: Colors.transparent,
      shape: shape(22),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: hudInk,
      contentTextStyle: const TextStyle(color: Color(0xfff4f1e6)),
      actionTextColor: hudGold,
      shape: shape(14),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: hudInk.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Color(0xfff4f1e6), fontSize: 12),
    ),
    textTheme: base.textTheme.apply(bodyColor: hudInk, displayColor: hudInk),
  );
}

/// The page ground. A very slight vertical wash stops a phone-sized screen of
/// flat cards from reading as grey.
class HudBackground extends StatelessWidget {
  const HudBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [hudBackgroundTop, hudBackgroundBottom],
      ),
    ),
    child: child,
  );
}

/// A raised parchment surface. Used where a plain `Card` needs a shadow it does
/// not get from the flat card theme.
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.accent,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Draws a colour bar down the leading edge; used to attribute a panel to a
  /// player without relying on colour alone elsewhere.
  final Color? accent;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: hudSurface,
      borderRadius: hudRadius,
      border: Border.all(color: hudBorder),
      boxShadow: hudShadow,
    ),
    clipBehavior: Clip.antiAlias,
    // A Stack, not a stretch Row: these panels live inside a vertical ListView,
    // where a Row's cross axis is unbounded and stretching children there fails
    // layout outright.
    child: Stack(
      children: [
        Padding(
          padding: padding.add(EdgeInsets.only(left: accent == null ? 0 : 5)),
          child: child,
        ),
        if (accent != null)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 5,
            child: ColoredBox(color: accent!),
          ),
      ],
    ),
  );
}

/// Section heading: small, wide-tracked and quiet, so panel titles group the
/// content without shouting over the board.
class HudHeading extends StatelessWidget {
  const HudHeading(this.label, {super.key, this.trailing});
  final String label;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
            color: hudMuted,
          ),
        ),
      ),
      ?trailing,
    ],
  );
}

/// Compact statistic. The icon carries the meaning and the number carries the
/// value, so these stay legible at small sizes and large text scales alike.
class HudStat extends StatelessWidget {
  const HudStat(
    this.icon,
    this.value, {
    super.key,
    this.emphasis = false,
    this.onTap,
  });
  final IconData icon;
  final String value;
  final bool emphasis;

  /// Makes the stat explain itself when tapped.
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final body = _body();
    return onTap == null
        ? body
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            child: body,
          );
  }

  Widget _body() => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: emphasis ? hudGold.withValues(alpha: 0.18) : hudSurfaceSunk,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(
        color: emphasis ? hudGold.withValues(alpha: 0.45) : hudBorder,
      ),
    ),
    // Min size: inside a Wrap a default Row would expand to the whole line.
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: emphasis ? hudGold : hudMuted),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: hudInk,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A resource card in the hand. Deliberately card-shaped rather than a pill:
/// it is the one place the interface should feel like physical components.
class HudResourceCard extends StatelessWidget {
  const HudResourceCard({
    super.key,
    required this.icon,
    required this.label,
    required this.held,
  });
  final Widget icon;

  /// Kept as a single string by the caller; splitting it into separate name and
  /// count widgets would change what text finders match.
  final String label;
  final bool held;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    padding: const EdgeInsets.fromLTRB(8, 7, 11, 7),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: held
            ? const [Color(0xfffffef9), Color(0xffeef4ea)]
            : const [Color(0xfff3f1e9), Color(0xffeceae1)],
      ),
      borderRadius: BorderRadius.circular(13),
      border: Border.all(
        color: held ? hudTeal.withValues(alpha: 0.38) : hudBorder,
        width: held ? 1.4 : 1,
      ),
      boxShadow: held ? hudShadow : null,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(opacity: held ? 1 : 0.42, child: icon),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: held ? FontWeight.w700 : FontWeight.w500,
              fontSize: 13,
              color: held ? hudInk : hudMuted,
            ),
          ),
        ),
      ],
    ),
  );
}
