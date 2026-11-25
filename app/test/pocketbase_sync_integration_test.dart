import 'dart:async';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shopbandit/core/categories.dart';
import 'package:shopbandit/data/db.dart';
import 'package:shopbandit/data/remote.dart';
import 'package:shopbandit/data/repository.dart';
import 'package:shopbandit/data/sync_service.dart';

const _url = String.fromEnvironment('SHOPBANDIT_TEST_URL');

/// A network switch around the real API; no simulated server behavior.
class _Connection implements SyncRemote {
  _Connection(this.remote);
  final PocketBaseRemote remote;
  bool online = true;

  void _check() {
    if (!online) throw RemoteUnreachable('test airplane mode');
  }

  @override
  Future<void> create(String collection, Map<String, dynamic> body) async {
    _check();
    await remote.create(collection, body);
  }

  @override
  Future<void> update(String collection, String id, Map<String, dynamic> body) async {
    _check();
    await remote.update(collection, id, body);
  }

  @override
  Future<List<Map<String, dynamic>>> listSince(String collection, String since) async {
    _check();
    return remote.listSince(collection, since);
  }

  @override
  Future<List<Map<String, dynamic>>> members() async {
    _check();
    return remote.members();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test('real PocketBase: two devices, offline outbox, manual categories, realtime and deletion conflict', () async {
    final host = Uri.parse(_url).host;
    expect(
      ['127.0.0.1', 'localhost', 'host.docker.internal'],
      contains(host),
      reason: 'Only disposable local test servers are allowed',
    );
    final pb1 = PocketBase(_url);
    final pb2 = PocketBase(_url);
    final email = 'sync${DateTime.now().microsecondsSinceEpoch}@example.com';
    const password = 'CategorySync123!x';
    await pb1
        .collection('users')
        .create(body: {'email': email, 'password': password, 'passwordConfirm': password, 'name': 'Sync Test'});
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    final auth = await pb1.collection('users').authWithPassword(email, password);
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    await pb2.collection('users').authWithPassword(email, password);
    final household = auth.record.getStringValue('household');
    final db1 = AppDatabase(NativeDatabase.memory());
    final db2 = AppDatabase(NativeDatabase.memory());
    final connection1 = _Connection(PocketBaseRemote(pb1));
    final connection2 = _Connection(PocketBaseRemote(pb2));
    final sync1 = SyncService(db1, connection1);
    final sync2 = SyncService(db2, connection2);
    final repo1 = ShopRepository(db1, sync1, household: household, userId: auth.record.id);
    final repo2 = ShopRepository(db2, sync2, household: household, userId: auth.record.id);
    Future<void> Function()? unsubscribe;
    try {
      await repo1.initializeCategories();
      await repo2.initializeCategories();
      await sync1.sync();
      await sync2.sync();
      expect(await repo2.watchCategories().first, hasLength(12));
      connection1.online = false;
      await repo1.createCategory('Offline Regal');
      final own = (await repo1.watchCategories().first).last;
      await repo1.addItem('Milch', quantity: '2 l');
      final milk = await db1.select(db1.catalogItems).getSingle();
      await repo1.setCategory(milk.id, own.id);
      await sync1.sync();
      expect(sync1.state, SyncState.offline);
      expect(await db1.pendingCount(), greaterThan(0));
      expect((await pb2.collection('categories').getFullList()).length, 12);
      connection1.online = true;
      await sync1.resetBackoff();
      await sync1.sync();
      await sync2.sync();
      expect(sync1.state, SyncState.idle);
      expect(await db1.pendingCount(), 0);
      expect((await repo2.watchList().first).single.item.category, own.id);
      expect((await repo2.watchList().first).single.entry.quantity, '2 l');
      final serverMilk = await pb1.collection('catalog_items').getOne(milk.id);
      expect(serverMilk.getBoolValue('category_manual'), true);

      final renamed = Completer<void>();
      unsubscribe = await connection2.remote.subscribe((event) {
        unawaited(
          sync2
              .applyEvent(event)
              .then(
                (_) {
                  if (event.collection == 'categories' &&
                      event.record['id'] == own.id &&
                      event.record['name'] == 'Live Regal' &&
                    !renamed.isCompleted) {
                  renamed.complete();
                }
                },
                onError: (Object error, StackTrace stack) {
                  if (!renamed.isCompleted) renamed.completeError(error, stack);
                },
              ),
        );
      });
      await repo1.renameCategory(own.id, 'Live Regal');
      await sync1.sync();
      await renamed.future.timeout(const Duration(seconds: 15));
      expect((await repo2.watchCategories().first).last.name, 'Live Regal');
      await unsubscribe();
      unsubscribe = null;

      connection2.online = false;
      await repo2.renameCategory(own.id, 'Offline stale rename');
      await repo2.setCategory(milk.id, own.id);
      await repo1.deleteCategory(own.id);
      await sync1.sync();
      connection2.online = true;
      await sync2.resetBackoff();
      await sync2.sync();
      await sync1.sync();
      expect((await db2.select(db2.catalogItems).getSingle()).category, categoryId(household, 'other'));
      expect(await repo2.watchCategories().first, hasLength(12));
      expect(await db2.pendingCount(), 0);

      final row = (await repo2.watchList().first).single;
      await repo2.check(row);
      await sync2.sync();
      await repo2.check(row, undo: true);
      await sync2.sync();
      await sync1.sync();
      final restored = (await repo1.watchList().first).single.item;
      expect(restored.purchaseCount, 0);
      expect(restored.categoryManual, true);
      expect(restored.category, categoryId(household, 'other'));
    } finally {
      await unsubscribe?.call();
      await sync1.sync();
      await sync2.sync();
      await sync1.dispose();
      await sync2.dispose();
      await pb1.realtime.unsubscribe();
      await pb2.realtime.unsubscribe();
      await db1.close();
      await db2.close();
    }
  }, skip: _url.isEmpty ? 'Set SHOPBANDIT_TEST_URL for a disposable local PocketBase' : false);
}
