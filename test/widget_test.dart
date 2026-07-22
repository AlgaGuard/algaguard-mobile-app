import 'package:algaguard_mobile_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows onboarding and simulated-data disclosure', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AlgaGuardApp()));
    expect(find.text('Scan setup QR'), findsOneWidget);
    expect(find.textContaining('Simulated data'), findsOneWidget);
  });
}
