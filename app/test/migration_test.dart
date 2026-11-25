import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopbandit/core/categories.dart';
import 'package:shopbandit/data/db.dart';
import 'package:shopbandit/data/repository.dart';
import 'package:shopbandit/data/sync_service.dart';

import 'fake_remote.dart';

void main() {
  test('real v1 SQLite upgrades offline preserving catalog, entries, statistics and outbox', () async {
    // Frozen v1 schema. Opening this executor through AppDatabase actually runs
    // the v1 -> v2 ALTER TABLE migration, rather than testing a fresh v2 DB.
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (sqlite) {
          sqlite.execute('''
        CREATE TABLE catalog_items (
          id TEXT NOT NULL PRIMARY KEY, household TEXT NOT NULL, name TEXT NOT NULL,
          name_normalized TEXT NOT NULL, purchase_count INTEGER NOT NULL DEFAULT 0,
          last_purchased INTEGER, deleted INTEGER NOT NULL DEFAULT 0, updated TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE list_entries (
          id TEXT NOT NULL PRIMARY KEY, household TEXT NOT NULL, catalog_item TEXT NOT NULL,
          quantity TEXT NOT NULL DEFAULT '', added_by TEXT NOT NULL DEFAULT '', checked INTEGER NOT NULL DEFAULT 0,
          checked_at INTEGER, deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE members (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, household TEXT NOT NULL);
        CREATE TABLE outbox (
          seq INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL, record_id TEXT NOT NULL,
          op TEXT NOT NULL, payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, not_before INTEGER
        );
        CREATE TABLE meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO catalog_items VALUES ('milk', 'h1', 'Milch', 'milch', 7, 1790000000, 0, 'old');
        INSERT INTO catalog_items VALUES ('removed', 'h1', 'Unbekannt', 'unbekannt', 3, NULL, 1, 'old');
        INSERT INTO list_entries VALUES ('entry', 'h1', 'milk', '2 l', 'u1', 0, NULL, 0, 1790000000, 'old');
        INSERT INTO meta VALUES ('household', 'h1');
        INSERT INTO outbox (collection, record_id, op, payload) VALUES ('list_entries', 'entry', 'update', '{"quantity":"2 l"}');
        PRAGMA user_version = 1;
      ''');
        },
      ),
    );
    final remote = FakeRemote()..online = false;
    final sync = SyncService(db, remote);
    final repo = ShopRepository(db, sync, household: 'h1', userId: 'u1');
    final before = await db.select(db.catalogItems).get();
    expect(before, hasLength(2));
    expect(before.first.categoryVersion, 0);
    await repo.initializeCategories();
    final milk = await (db.select(db.catalogItems)..where((c) => c.id.equals('milk'))).getSingle();
    expect(milk.name, 'Milch');
    expect(milk.nameNormalized, 'milch');
    expect(milk.purchaseCount, 7);
    expect(milk.lastPurchased?.millisecondsSinceEpoch, 1790000000000);
    expect(milk.category, categoryId('h1', 'dairy_eggs'));
    final removed = await (db.select(db.catalogItems)..where((c) => c.id.equals('removed'))).getSingle();
    expect(removed.deleted, true);
    expect(removed.purchaseCount, 3);
    expect(removed.category, categoryId('h1', 'other'));
    final entry = await db.select(db.listEntries).getSingle();
    expect(entry.id, 'entry');
    expect(entry.catalogItem, 'milk');
    expect(entry.quantity, '2 l');
    expect(await db.pendingCount(), 3); // original operation + two assignments
    expect(await repo.watchCategories().first, hasLength(12));
    await repo.initializeCategories();
    expect(await db.pendingCount(), 3); // one-time backfill
    expect(await db.getMeta('household'), 'h1');
    await sync.dispose();
    await db.close();
  });
}
