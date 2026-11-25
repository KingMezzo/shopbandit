import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopbandit/core/categories.dart';
import 'package:shopbandit/core/product_dictionary.dart';
import 'package:shopbandit/data/db.dart';
import 'package:shopbandit/data/repository.dart';
import 'package:shopbandit/data/sync_service.dart';
import 'package:shopbandit/l10n/app_localizations.dart';
import 'package:shopbandit/ui/category_widgets.dart';

import 'fake_remote.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late FakeRemote remote;
  late SyncService sync;
  late ShopRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    remote = FakeRemote()..online = false;
    sync = SyncService(db, remote);
    repo = ShopRepository(db, sync, household: 'h1', userId: 'u1');
    await repo.initializeCategories();
  });
  tearDown(() async {
    await sync.sync();
    await sync.dispose();
    await db.close();
  });

  test('bootstrap is idempotent, deterministic and household scoped', () async {
    await repo.initializeCategories();
    final categories = await repo.watchCategories().first;
    expect(categories.map((c) => c.key), defaultCategoryKeys);
    expect(categories.every((c) => c.isDefault), true);
    expect(categories.map((c) => c.id).toSet(), hasLength(12));
    expect(categoryId('h1', 'other'), isNot(categoryId('h2', 'other')));
    expect(await db.pendingCount(), 0); // server bootstraps defaults itself
  });

  test('dictionary covers common German and English names safely', () {
    expect(productDictionary.length, greaterThan(400));
    const cases = {
      ' MILCH ': 'dairy_eggs',
      'Gouda': 'dairy_eggs',
      'Jogurt': 'dairy_eggs',
      'Eier': 'dairy_eggs',
      'Bananen': 'fruit_vegetables',
      'Paprika': 'fruit_vegetables',
      'Kartoffeln': 'fruit_vegetables',
      'Brot': 'bakery',
      'Broetchen': 'bakery',
      'Nudeln': 'pantry',
      'Reis': 'pantry',
      'Cola': 'drinks',
      'Orangensaft': 'drinks',
      'Tiefkühlpizza': 'frozen',
      'TK-  Pizza': 'frozen',
      'Waschmittel': 'household',
      'Toilettenpapier': 'household',
      'chicken breast': 'meat',
      'ice cream': 'frozen',
      'milk chocolate': 'other',
      'Milchstraße': 'other',
      'Reisetasche': 'other',
      'Paprikapulver': 'pantry',
      'Kokosmilch': 'canned',
    };
    cases.forEach((name, key) => expect(categorizeProduct(name), key, reason: name));
    for (final entry in productDictionary.entries) {
      expect(categorizeProduct(entry.key), entry.value);
    }
  });

  test('manual category survives restore, checking and bootstrap', () async {
    await repo.addItem('Milch');
    final item = await db.select(db.catalogItems).getSingle();
    expect(item.category, categoryId('h1', 'dairy_eggs'));
    await repo.setCategory(item.id, categoryId('h1', 'drinks'));
    await repo.deleteCatalogItem(item.id);
    await repo.addItem('milch');
    final row = (await repo.watchList().first).single;
    await repo.check(row);
    await repo.check(row, undo: true);
    await repo.initializeCategories();
    final restored = await db.select(db.catalogItems).getSingle();
    expect(restored.id, item.id);
    expect(restored.category, categoryId('h1', 'drinks'));
    expect(restored.categoryManual, true);
    expect(restored.purchaseCount, 0);
  });

  test('custom delete repairs local products and queued offline assignments', () async {
    await repo.createCategory('Unser Regal');
    final own = (await repo.watchCategories().first).last;
    await repo.addItem('Milch');
    final id = (await db.select(db.catalogItems).getSingle()).id;
    await repo.setCategory(id, own.id);
    await repo.deleteCategory(own.id);
    expect((await db.select(db.catalogItems).getSingle()).category, categoryId('h1', 'other'));
    for (final op in await db.select(db.outbox).get()) {
      final body = jsonDecode(op.payload) as Map;
      expect(body['category'], isNot(own.id));
    }
    expect((await repo.watchCategories().first).length, 12);
    await expectLater(repo.deleteCategory(categoryId('h1', 'other')), throwsStateError);
    await expectLater(repo.setCategory(id, own.id), throwsStateError);
  });

  test('rename/reset and ordering persist offline', () async {
    final id = categoryId('h1', 'bakery');
    await repo.renameCategory(id, 'Unser Brot');
    expect((await repo.watchCategories().first).firstWhere((c) => c.id == id).name, 'Unser Brot');
    await repo.renameCategory(id, '');
    final ids = (await repo.watchCategories().first).map((c) => c.id).toList().reversed.toList();
    await repo.reorderCategories(ids);
    expect((await repo.watchCategories().first).map((c) => c.id), ids);
    await expectLater(repo.reorderCategories([id, id]), throwsArgumentError);
  });

  test('offline create then sync uses same categories on a second device', () async {
    await repo.createCategory('Vorratskammer');
    final own = (await repo.watchCategories().first).last;
    await repo.addItem('Milch');
    final id = (await db.select(db.catalogItems).getSingle()).id;
    await repo.setCategory(id, own.id);
    remote.online = true;
    await sync.resetBackoff();
    await sync.sync();
    expect(await db.pendingCount(), 0);
    final db2 = AppDatabase(NativeDatabase.memory());
    final sync2 = SyncService(db2, remote);
    final repo2 = ShopRepository(db2, sync2, household: 'h1', userId: 'u2');
    await repo2.initializeCategories();
    await sync2.sync();
    expect(await repo2.watchCategories().first, hasLength(13));
    expect((await db2.select(db2.catalogItems).getSingle()).category, own.id);
    await sync2.dispose();
    await db2.close();
  });

  test('delete wins over another device offline rename and category assignment', () async {
    remote.online = true;
    remote.seedCategories('h1');
    await repo.createCategory('Regal');
    await repo.addItem('Milch');
    await sync.sync();
    final own = (await repo.watchCategories().first).last;
    final id = (await db.select(db.catalogItems).getSingle()).id;
    final db2 = AppDatabase(NativeDatabase.memory());
    final sync2 = SyncService(db2, remote);
    final repo2 = ShopRepository(db2, sync2, household: 'h1', userId: 'u2');
    await repo2.initializeCategories();
    await sync2.sync();
    remote.online = false;
    await repo2.renameCategory(own.id, 'Alter Name');
    await repo2.setCategory(id, own.id);
    await repo.deleteCategory(own.id);
    remote.online = true;
    await sync.resetBackoff();
    await sync.sync();
    await sync2.resetBackoff();
    await sync2.sync();
    await sync.sync();
    expect((await (db2.select(db2.categories)..where((c) => c.id.equals(own.id))).getSingle()).deleted, true);
    expect((await db2.select(db2.catalogItems).getSingle()).category, categoryId('h1', 'other'));
    await sync2.dispose();
    await db2.close();
  });

  test('replayed product create does not reset manual category or purchases', () async {
    remote.online = true;
    await repo.addItem('Milch');
    await sync.sync();
    final item = await db.select(db.catalogItems).getSingle();
    await remote.update('catalog_items', item.id, {
      'category': categoryId('h1', 'drinks'),
      'category_manual': true,
      'purchase_count+': 4,
    });
    await sync.enqueue('catalog_items', item.id, 'create', {
      'id': item.id,
      'household': 'h1',
      'name': 'Milch',
      'name_normalized': 'milch',
      'category': categoryId('h1', 'dairy_eggs'),
      'category_manual': false,
      'purchase_count': 0,
    });
    await sync.sync();
    final result = await db.select(db.catalogItems).getSingle();
    expect(result.categoryManual, true);
    expect(result.category, categoryId('h1', 'drinks'));
    expect(result.purchaseCount, 4);
  });

  test('remote household is checked locally and foreign assignment rejected', () async {
    await db.setMeta('household', 'h1');
    await sync.applyRemote('categories', {'id': 'foreign', 'household': 'h2', 'key': 'other'});
    expect(await db.select(db.categories).get(), hasLength(12));
    await repo.addItem('Milch');
    final id = (await db.select(db.catalogItems).getSingle()).id;
    await expectLater(repo.setCategory(id, categoryId('h2', 'other')), throwsStateError);
  });

  test('German/English default names translate, custom names always override', () async {
    final de = await AppLocalizations.delegate.load(const Locale('de'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final categories = await repo.watchCategories().first;
    expect(categoryName(categories.first, de), 'Obst & Gemüse');
    expect(categoryName(categories.first, en), 'Fruit & Vegetables');
    expect(categoryName(categories.last, de), 'Sonstiges');
    expect(categoryName(categories.last, en), 'Other');
    expect(categories.map((c) => categoryName(c, de)).toSet(), hasLength(12));
    expect(categories.map((c) => categoryName(c, en)).toSet(), hasLength(12));
    final custom = categories.first.copyWith(name: 'Unser Gemüse');
    expect(categoryName(custom, de), categoryName(custom, en));
    expect(en.manageCategories, 'Manage categories');
  });

  test('realtime tombstone repairs pending assignment and stale rename events stay deleted', () async {
    await repo.createCategory('Regal');
    final own = (await repo.watchCategories().first).last;
    await repo.addItem('Milch');
    final id = (await db.select(db.catalogItems).getSingle()).id;
    await repo.setCategory(id, own.id);
    final record = {
      'id': own.id,
      'household': 'h1',
      'key': own.key,
      'name': own.name,
      'is_default': false,
      'deleted': true,
      'updated': '2026-11-25 10:00:00.000Z',
    };
    await sync.applyEvent((collection: 'categories', action: 'update', record: record));
    expect((await db.select(db.catalogItems).getSingle()).category, categoryId('h1', 'other'));
    await sync.applyEvent((collection: 'categories', action: 'update', record: {...record, 'deleted': false}));
    expect(await repo.watchCategories().first, hasLength(12));
    expect((await db.select(db.outbox).get()).where((o) => o.recordId == own.id), isEmpty);
  });

  test('backfill imports preserve a manual assignment even before version is set', () async {
    await db
        .into(db.catalogItems)
        .insert(
          CatalogItemsCompanion.insert(
            id: 'manual',
            household: 'h1',
            name: 'Milch',
            nameNormalized: 'milch',
            category: Value(categoryId('h1', 'drinks')),
            categoryManual: const Value(true),
            purchaseCount: const Value(9),
          ),
        );
    await repo.initializeCategories();
    final item = await db.select(db.catalogItems).getSingle();
    expect(item.category, categoryId('h1', 'drinks'));
    expect(item.categoryManual, true);
    expect(item.purchaseCount, 9);
  });
}
