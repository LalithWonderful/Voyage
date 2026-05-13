import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/core/widgets/city_autocomplete_field.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/places_service.dart';

void main() {
  group('CityAutocompleteField', () {
    Widget buildField({
      bool acceptAnyDestination = false,
      void Function(String city, String? country, String? placeId, String kind)?
          onSelectedDetailed,
    }) {
      return ProviderScope(
        overrides: [
          placesServiceProvider.overrideWithValue(PlacesService(apiKey: '')),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CityAutocompleteField(
              acceptAnyDestination: acceptAnyDestination,
              onSelectedDetailed: onSelectedDetailed,
            ),
          ),
        ),
      );
    }

    testWidgets(
      'typing "lisbo" with acceptAnyDestination shows Lunao Lisbon suggestion',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        expect(field, findsOneWidget);

        await tester.enterText(field, 'lisbo');
        await tester.pump(const Duration(milliseconds: 400));

        // The suggestion "Lisbonne" should appear in the dropdown.
        expect(find.text('Lisbonne'), findsOneWidget);
      },
    );

    testWidgets(
      'typing "lisbo" without acceptAnyDestination shows Lunao Lisbon suggestion',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: false));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'lisbo');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Lisbonne'), findsOneWidget);
      },
    );

    testWidgets(
      'typing "tok" (too short) shows no suggestions',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'tok');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Lisbonne'), findsNothing);
      },
    );

    testWidgets(
      'selecting a suggestion calls onSelectedDetailed',
      (tester) async {
        String? selectedCity;
        String? selectedPlaceId;
        String? selectedKind;

        await tester.pumpWidget(
          buildField(
            acceptAnyDestination: true,
            onSelectedDetailed: (city, country, placeId, kind) {
              selectedCity = city;
              selectedPlaceId = placeId;
              selectedKind = kind;
            },
          ),
        );
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'lisbo');
        await tester.pump(const Duration(milliseconds: 400));

        await tester.tap(find.text('Lisbonne'));
        await tester.pumpAndSettle();

        expect(selectedCity, 'Lisbonne');
        expect(selectedPlaceId, 'lunao:lisbon');
        expect(selectedKind, 'city');
      },
    );

    testWidgets(
      'typing "fran" with acceptAnyDestination shows Lunao France suggestion',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'fran');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('France'), findsOneWidget);
      },
    );

    testWidgets(
      'typing "bali" with acceptAnyDestination shows Lunao Bali suggestion',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'bali');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Bali'), findsOneWidget);
      },
    );

    testWidgets(
      'typing "tok" (too short) does not show empty-state message',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'tok');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.textContaining('Aucun résultat'), findsNothing);
      },
    );

    testWidgets(
      'typing "tokyo" with no API key shows empty-state message',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'tokyo');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.textContaining('Aucun résultat'), findsOneWidget);
      },
    );

    testWidgets(
      'typing "lisbo" does not show empty-state message because Lunao match exists',
      (tester) async {
        await tester.pumpWidget(buildField(acceptAnyDestination: true));
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'lisbo');
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Lisbonne'), findsOneWidget);
        expect(find.textContaining('Aucun résultat'), findsNothing);
      },
    );

    testWidgets(
      'user can submit free text after empty-state when acceptAnyDestination=true',
      (tester) async {
        String? submittedCity;
        String? submittedKind;

        await tester.pumpWidget(
          buildField(
            acceptAnyDestination: true,
            onSelectedDetailed: (city, country, placeId, kind) {
              submittedCity = city;
              submittedKind = kind;
            },
          ),
        );
        await tester.pumpAndSettle();

        final field = find.byType(TextField);
        await tester.enterText(field, 'tokyo');
        await tester.pump(const Duration(milliseconds: 400));

        // Empty-state is visible
        expect(find.textContaining('Aucun résultat'), findsOneWidget);

        // Submit the text field (tap done / press enter)
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(submittedCity, 'tokyo');
        expect(submittedKind, 'unknown');
      },
    );
  });
}
