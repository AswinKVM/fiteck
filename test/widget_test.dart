import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:myapp1/main.dart';

void main() {
  testWidgets('Fitness Tracker App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    // Build our app and trigger a frame.
    await tester.pumpWidget(const FitnessTrackerApp());

    // Verify that StartupPage displays a circular progress indicator initially.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Wait for the async SharedPreferences check and redirection to happen.
    await tester.pumpAndSettle();

    // Verify that the Profile Setup Page is displayed since 'name' is not set.
    expect(find.text('Profile Setup'), findsOneWidget);
  });
}
