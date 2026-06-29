import 'package:cineviet_app_v2/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CineViet v2 boots', (tester) async {
    await tester.pumpWidget(const CineVietV2App());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
