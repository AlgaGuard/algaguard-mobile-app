import 'package:flutter/material.dart';

class AlgaGuardBrandLogo extends StatelessWidget {
  const AlgaGuardBrandLogo({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'AlgaGuard',
    image: true,
    child: Image.asset(
      'assets/brand/algaguard-logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    ),
  );
}
