import 'package:flutter/material.dart';

class AlgaGuardBrandLogo extends StatelessWidget {
  const AlgaGuardBrandLogo({
    super.key,
    this.size = 120,
    this.withWordmark = false,
  });

  final double size;
  final bool withWordmark;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'AlgaGuard',
    image: true,
    child: Image.asset(
      withWordmark
          ? 'assets/brand/algaguard-logo-tagline-transparent.png'
          : 'assets/brand/algaguard-logo-transparent.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    ),
  );
}
