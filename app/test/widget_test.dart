import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shopbandit/auth/session.dart';
import 'package:shopbandit/data/db.dart';
import 'package:shopbandit/data/repository.dart';
import 'package:shopbandit/data/sync_service.dart';
import 'package:shopbandit/l10n/app_localizations.dart';
import 'package:shopbandit/providers.dart';
import 'package:shopbandit/ui/auth_screens.dart';
import 'package:shopbandit/ui/list_screen.dart';
import 'package:shopbandit/ui/theme.dart';
import 'package:shopbandit/ui/categories_screen.dart';
import 'package:shopbandit/ui/settings_screen.dart';
import 'package:shopbandit/ui/category_widgets.dart';
import 'package:shopbandit/core/categories.dart';

import 'fake_remote.dart';

Future<AppSession> _session({bool withRepo = false}) async {
  SharedPreferences.setMockInitialValues({Prefs.serverUrl: 'https://shop.example.com'});
  final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  final session = AppSession(prefs: await SharedPreferences.getInstance(), db: db);
  if (withRepo) {
    final remote = FakeRemote()..online = false;
    session.sync = SyncService(db, remote);
    session.repo = ShopRepository(db, session.sync!, household: 'h1', userId: 'u1');
    await session.repo!.initializeCategories();
  }
  return session;
}

Widget _app(
  AppSession session,
  Widget home, {
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.light,
}) => ProviderScope(
  overrides: [sessionProvider.overrideWith((ref) => session)],
  child: MaterialApp(
    locale: locale,
    theme: buildTheme(brightness),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  ),
);

// The in-memory DB is not closed: closing inside the fake-async test zone
// never completes. Streams close synchronously, so no timers stay pending.
Future<void> _dispose(WidgetTester tester, AppSession session) => tester.pumpWidget(const SizedBox());

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('gradient header uses light status bar icons', (tester) async {
    final session = await _session(withRepo: true);
    await tester.pumpWidget(_app(session, const ListScreen()));
    await tester.pumpAndSettle();
    expect(tester.widget<AppBar>(find.byType(AppBar)).systemOverlayStyle, SystemUiOverlayStyle.light);
    await _dispose(tester, session);
  });

  testWidgets('gradient header fills the whole app bar', (tester) async {
    final session = await _session(withRepo: true);
    await tester.pumpWidget(_app(session, const ListScreen()));
    await tester.pumpAndSettle();
    final gradient = find.descendant(
      of: find.byType(AppBar),
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration == const BoxDecoration(gradient: Brand.headerGradient),
      ),
    );
    expect(tester.getSize(gradient), tester.getSize(find.byType(AppBar)));
    await _dispose(tester, session);
  });

  testWidgets('login validates input before calling the server', (tester) async {
    final session = await _session();
    await tester.pumpWidget(_app(session, const LoginScreen()));
    await tester.tap(find.text('Anmelden'));
    await tester.pump();
    expect(find.text('Bitte eine gültige E-Mail-Adresse eingeben'), findsOneWidget);
    expect(find.text('Bitte Passwort eingeben'), findsOneWidget);
    await _dispose(tester, session);
  });

  testWidgets('register shows live password feedback', (tester) async {
    final session = await _session();
    await tester.pumpWidget(_app(session, const RegisterScreen()));
    final pw = find.widgetWithText(TextFormField, 'Passwort');
    expect(find.byIcon(Icons.check_circle), findsNothing);
    await tester.enterText(pw, 'abc');
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsOneWidget); // lowercase only
    await tester.enterText(pw, 'Abcdefg1!');
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsNWidgets(5));
    await _dispose(tester, session);
  });

  testWidgets('list: add, show quantity, check off with undo', (tester) async {
    final session = await _session(withRepo: true);
    await tester.pumpWidget(_app(session, const ListScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Alles erledigt!'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Was fehlt?'), 'Milch');
    await tester.enterText(find.widgetWithText(TextField, 'Menge'), '2 l');
    await tester.tap(find.byTooltip('Hinzufügen'));
    await tester.pumpAndSettle();
    expect(find.text('Milch'), findsOneWidget);
    expect(find.text('2 l'), findsOneWidget);

    await tester.tap(find.byTooltip('Milch als gekauft markieren'));
    await tester.pumpAndSettle();
    expect(find.text('Alles erledigt!'), findsOneWidget);
    expect(find.text('Milch gekauft'), findsOneWidget);

    // undo snack bar disappears by itself (also after the last item)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Milch gekauft'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Was fehlt?'), 'Milch');
    await tester.tap(find.byTooltip('Hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Milch als gekauft markieren'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Milch'), findsOneWidget);
    await _dispose(tester, session);
  });

  testWidgets('list groups collapse and product category edits regroup immediately', (tester) async {
    final session = await _session(withRepo: true);
    await session.repo!.addItem('Milch', quantity: '2 l');
    await tester.pumpWidget(_app(session, const ListScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Milchprodukte & Eier'), findsOneWidget);
    await tester.tap(find.text('Milchprodukte & Eier'));
    await tester.pumpAndSettle();
    expect(find.text('Milch').hitTestable(), findsNothing);
    await tester.tap(find.text('Milchprodukte & Eier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Milch'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductCategoryPicker), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Getränke').last);
    await tester.tap(find.text('Getränke').last);
    await tester.pumpAndSettle();
    expect((await session.db.select(session.db.catalogItems).getSingle()).category, categoryId('h1', 'drinks'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(find.text('Getränke'), findsOneWidget);
    expect(find.text('Milchprodukte & Eier'), findsNothing);
    expect(find.text('2 l'), findsOneWidget);
    await _dispose(tester, session);
  });

  testWidgets('catalog supports search and category editing while preserving delete', (tester) async {
    final session = await _session(withRepo: true);
    await session.repo!.addItem('Milch');
    await session.repo!.addItem('Brot');
    await tester.pumpWidget(_app(session, const CatalogScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Milchprodukte & Eier'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Artikel suchen'), 'Mil');
    await tester.pumpAndSettle();
    expect(find.text('Brot'), findsNothing);
    await tester.tap(find.text('Milch'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductCategoryPicker), findsOneWidget);
    await tester.tap(find.text('Schließen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Milch löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen').last);
    await tester.pumpAndSettle();
    expect(
      (await session.db.select(session.db.catalogItems).get()).where((c) => c.name == 'Milch').single.deleted,
      true,
    );
    await _dispose(tester, session);
  });

  testWidgets('category management creates and renames offline', (tester) async {
    final session = await _session(withRepo: true);
    await tester.pumpWidget(_app(session, const CategoriesScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kategorie erstellen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Unser Regal');
    await tester.pump();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect((await session.db.select(session.db.categories).get()).where((c) => c.name == 'Unser Regal'), hasLength(1));
    await tester.tap(find.text('Obst & Gemüse'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Frisches');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(find.text('Frisches'), findsOneWidget);
    await _dispose(tester, session);
  });

  testWidgets('English dark mode shows translated groups and usable dialog on narrow screen', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = await _session(withRepo: true);
    await session.repo!.addItem('Milch');
    await tester.pumpWidget(_app(session, const ListScreen(), locale: const Locale('en'), brightness: Brightness.dark));
    await tester.pumpAndSettle();
    expect(find.text('Dairy & Eggs'), findsOneWidget);
    await tester.tap(find.text('Milch'));
    await tester.pumpAndSettle();
    expect(find.text('Category'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _dispose(tester, session);
  });
}
