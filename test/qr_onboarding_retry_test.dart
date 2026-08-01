import 'package:algaguard_mobile_app/main.dart';
import 'package:algaguard_mobile_app/src/onboarding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

QrClaim claim() => QrClaim(
  deviceId: 'AG-000001',
  claimCode: 'synthetic-claim',
  bootstrapUrl: Uri.parse('https://api.example.test/bootstrap'),
  environment: 'development',
  bleServiceId: '0000a1a0-0000-1000-8000-00805f9b34fb',
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
);

ProvisioningSession session() => ProvisioningSession(
  sessionId: '50000000-0000-4000-8000-000000000001',
  deviceId: 'AG-000001',
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
  sessionToken: 'x' * 32,
  bindingGrant: 'g' * 194,
);

void main() {
  testWidgets('fresh QR retry clears session secrets before rescan', (
    tester,
  ) async {
    final activeSession = session();
    await tester.pumpWidget(
      MaterialApp(
        home: BleProvisioningScreen(
          claim: claim(),
          session: activeSession,
          retryScreenBuilder: (_) =>
              const Scaffold(body: Text('fresh qr scanner')),
        ),
      ),
    );

    await tester.tap(find.text('Start over with fresh QR'));
    await tester.pumpAndSettle();

    expect(activeSession.retainsToken, false);
    expect(activeSession.retainsBindingGrant, false);
    expect(find.text('fresh qr scanner'), findsOneWidget);
  });
}
