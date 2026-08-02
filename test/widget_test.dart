import 'package:algaguard_mobile_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('starts at splash and reaches the protected login flow', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: AlgaGuardApp()));
    await tester.pumpAndSettle();
    expect(find.text('Sign in with Keycloak'), findsOneWidget);
  });
}
