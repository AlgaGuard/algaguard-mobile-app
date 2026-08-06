import 'package:flutter/material.dart';
import 'theme.dart';

/// Marks data as coming from the ESP32 demo simulator rather than a live
/// sensor read. Purple is reserved exclusively for this convention -- see
/// theme.dart's AlgaGuardColors doc comment -- and must never be reused for
/// any other badge, status, or icon-circle color.
class SimulatedBadge extends StatelessWidget {
  const SimulatedBadge({super.key, this.label = 'Simulated demo data'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark
        ? AlgaGuardColors.purple500.withValues(alpha: 0.18)
        : AlgaGuardColors.purple50;
    final foreground = dark
        ? const Color(0xffc6aef2)
        : AlgaGuardColors.purple700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.science_outlined, size: 14, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
