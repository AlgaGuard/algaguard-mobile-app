import 'package:algaguard_mobile_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('starts at splash and reaches the protected login flow', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: AlgaGuardApp()));
    expect(find.text('Start AlgaGuard'), findsOneWidget);
    await tester.tap(find.text('Start AlgaGuard'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in with Keycloak'), findsOneWidget);
  });
}
