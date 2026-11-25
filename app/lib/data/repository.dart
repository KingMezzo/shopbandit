import 'package:drift/drift.dart';

import '../core/items.dart';
import '../core/categories.dart';
import 'db.dart';
import 'sync_service.dart';

/// Entry joined with its catalog item, as shown in the list.
typedef ListRow = ({ListEntry entry, CatalogItem item, String? addedByName});

/// All local writes. Each write updates the local DB first (UI reacts at
/// once) and queues the change for the server.
class ShopRepository {
  ShopRepository(this.db, this.sync, {required this.household, required this.userId, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase db;
  final SyncService sync;
  final String household;
  final String userId;
  final DateTime Function() _now;

  /// Safe on every start, including a v1 database upgraded while offline.
  Future<void> initializeCategories() => db.transaction(() async {
    for (var i = 0; i < defaultCategoryKeys.length; i++) {
      final key = defaultCategoryKeys[i];
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: categoryId(household, key),
              household: household,
              key: key,
              isDefault: const Value(true),
              sortOrder: Value(i * 10),
              icon: Value(defaultCategoryIcons[i]),
              color: Value(defaultCategoryColors[i]),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    final old = await (db.select(
      db.catalogItems,
    )..where((c) => c.household.equals(household) & c.categoryVersion.equals(0))).get();
    for (final item in old) {
      final id = item.categoryManual && item.category.isNotEmpty
          ? item.category
          : categoryId(household, categorizeProduct(item.name));
      await (db.update(db.catalogItems)..where((c) => c.id.equals(item.id))).write(
        CatalogItemsCompanion(category: Value(id), categoryVersion: const Value(1)),
      );
      await sync.enqueue('catalog_items', item.id, 'update', {
        'category': id,
        'category_manual': item.categoryManual,
        'category_version': 1,
      });
    }
  });

  Stream<List<Category>> watchCategories() =>
      (db.select(db.categories)
            ..where((c) => c.household.equals(household) & c.deleted.equals(false))
            ..orderBy([(c) => OrderingTerm.asc(c.sortOrder), (c) => OrderingTerm.asc(c.id)]))
          .watch();

  // ------------------------------------------------------------- queries --

  Stream<List<ListRow>> watchList() {
    final q =
        db.select(db.listEntries).join([
            innerJoin(db.catalogItems, db.catalogItems.id.equalsExp(db.listEntries.catalogItem)),
            leftOuterJoin(db.members, db.members.id.equalsExp(db.listEntries.addedBy)),
          ])
          ..where(
            db.listEntries.household.equals(household) &
                db.listEntries.deleted.equals(false) &
                db.listEntries.checked.equals(false),
          )
          ..orderBy([OrderingTerm.desc(db.listEntries.createdAt)]);
    return q.watch().map(
      (rows) => rows
          .map(
            (r) => (
              entry: r.readTable(db.listEntries),
              item: r.readTable(db.catalogItems),
              addedByName: r.readTableOrNull(db.members)?.name,
            ),
          )
          .toList(),
    );
  }

  Stream<List<CatalogItem>> watchCatalog() =>
      (db.select(db.catalogItems)
            ..where((c) => c.household.equals(household) & c.deleted.equals(false))
            ..orderBy([(c) => OrderingTerm.asc(c.nameNormalized)]))
          .watch();

  Stream<List<Member>> watchMembers() =>
      (db.select(db.members)
            ..where((m) => m.household.equals(household))
            ..orderBy([(m) => OrderingTerm.asc(m.name)]))
          .watch();

  /// Catalog items sorted by [frequencyScore], without those already listed.
  static List<CatalogItem> frequent(List<CatalogItem> catalog, Set<String> onList, DateTime now, {int limit = 12}) {
    final candidates = catalog.where((c) => c.purchaseCount > 0 && !onList.contains(c.id)).toList()
      ..sort(
        (a, b) => frequencyScore(
          b.purchaseCount,
          b.lastPurchased,
          now,
        ).compareTo(frequencyScore(a.purchaseCount, a.lastPurchased, now)),
      );
    return candidates.take(limit).toList();
  }

  // -------------------------------------------------------------- writes --

  /// Adds [rawName] to the list. Reuses (and if needed restores) the catalog
  /// item; if the item is already on the list only the quantity is updated.
  Future<void> addItem(String rawName, {String quantity = ''}) async {
    final name = cleanItemName(rawName);
    if (name.isEmpty) return;
    final normalized = normalizeItemName(name);
    final qty = quantity.trim();
    await initializeCategories();

    await db.transaction(() async {
      final existing = await (db.select(
        db.catalogItems,
      )..where((c) => c.household.equals(household) & c.nameNormalized.equals(normalized))).getSingleOrNull();
      final catalogId = existing?.id ?? catalogItemId(household, normalized);

      if (existing == null) {
        final category = categoryId(household, categorizeProduct(name));
        await db
            .into(db.catalogItems)
            .insert(
              CatalogItemsCompanion.insert(
                id: catalogId,
                household: household,
                name: name,
                nameNormalized: normalized,
                category: Value(category),
                categoryVersion: const Value(1),
              ),
            );
        await sync.enqueue('catalog_items', catalogId, 'create', {
          'id': catalogId,
          'household': household,
          'name': name,
          'name_normalized': normalized,
          'purchase_count': 0,
          'deleted': false,
          'category': category,
          'category_manual': false,
          'category_version': 1,
        });
      } else if (existing.deleted) {
        await (db.update(
          db.catalogItems,
        )..where((c) => c.id.equals(catalogId))).write(const CatalogItemsCompanion(deleted: Value(false)));
        await sync.enqueue('catalog_items', catalogId, 'update', {'deleted': false});
      }

      final onList =
          await (db.select(db.listEntries)
                ..where((e) => e.catalogItem.equals(catalogId) & e.deleted.equals(false) & e.checked.equals(false))
                ..limit(1))
              .getSingleOrNull();
      if (onList != null) {
        if (qty.isNotEmpty && qty != onList.quantity) await _setQuantity(onList.id, qty);
        return;
      }

      final id = newRecordId();
      await db
          .into(db.listEntries)
          .insert(
            ListEntriesCompanion.insert(
              id: id,
              household: household,
              catalogItem: catalogId,
              quantity: Value(qty),
              addedBy: Value(userId),
              createdAt: _now(),
            ),
          );
      await sync.enqueue('list_entries', id, 'create', {
        'id': id,
        'household': household,
        'catalog_item': catalogId,
        'quantity': qty,
        'added_by': userId,
        'checked': false,
        'deleted': false,
      });
    });
    _kick();
  }

  Future<void> updateQuantity(String entryId, String quantity) async {
    await db.transaction(() => _setQuantity(entryId, quantity.trim()));
    _kick();
  }

  Future<void> _setQuantity(String entryId, String qty) async {
    await (db.update(
      db.listEntries,
    )..where((e) => e.id.equals(entryId))).write(ListEntriesCompanion(quantity: Value(qty)));
    await sync.enqueue('list_entries', entryId, 'update', {'quantity': qty});
  }

  /// Bought: entry leaves the list, purchase counter goes up.
  Future<void> check(ListRow row, {bool undo = false}) async {
    final now = _now();
    await db.transaction(() async {
      await (db.update(db.listEntries)..where((e) => e.id.equals(row.entry.id))).write(
        ListEntriesCompanion(checked: Value(!undo), checkedAt: Value(undo ? null : now)),
      );
      await sync.enqueue('list_entries', row.entry.id, 'update', {
        'checked': !undo,
        'checked_at': undo ? '' : toPbDate(now),
      });

      final item = await (db.select(db.catalogItems)..where((c) => c.id.equals(row.item.id))).getSingle();
      final count = undo ? (item.purchaseCount > 0 ? item.purchaseCount - 1 : 0) : item.purchaseCount + 1;
      final last = undo ? row.item.lastPurchased : now;
      await (db.update(db.catalogItems)..where((c) => c.id.equals(item.id))).write(
        CatalogItemsCompanion(purchaseCount: Value(count), lastPurchased: Value(last)),
      );
      await sync.enqueue('catalog_items', item.id, 'update', {
        // relative change, so parallel purchases on two phones add up
        if (undo) 'purchase_count-': 1 else 'purchase_count+': 1,
        'last_purchased': last == null ? '' : toPbDate(last),
      });
    });
    _kick();
  }

  Future<void> deleteEntry(String entryId, {bool undo = false}) async {
    await db.transaction(() async {
      await (db.update(
        db.listEntries,
      )..where((e) => e.id.equals(entryId))).write(ListEntriesCompanion(deleted: Value(!undo)));
      await sync.enqueue('list_entries', entryId, 'update', {'deleted': !undo});
    });
    _kick();
  }

  /// Removes an item from the catalog (and from the list, if it is on it).
  Future<void> deleteCatalogItem(String catalogId) async {
    await db.transaction(() async {
      await (db.update(
        db.catalogItems,
      )..where((c) => c.id.equals(catalogId))).write(const CatalogItemsCompanion(deleted: Value(true)));
      await sync.enqueue('catalog_items', catalogId, 'update', {'deleted': true});
      final active = await (db.select(
        db.listEntries,
      )..where((e) => e.catalogItem.equals(catalogId) & e.deleted.equals(false) & e.checked.equals(false))).get();
      for (final e in active) {
        await (db.update(
          db.listEntries,
        )..where((x) => x.id.equals(e.id))).write(const ListEntriesCompanion(deleted: Value(true)));
        await sync.enqueue('list_entries', e.id, 'update', {'deleted': true});
      }
    });
    _kick();
  }

  Future<void> setCategory(String catalogId, String id) async {
    await db.transaction(() async {
      await _category(id);
      final item = await (db.select(
        db.catalogItems,
      )..where((c) => c.id.equals(catalogId) & c.household.equals(household))).getSingle();
      await (db.update(db.catalogItems)..where((c) => c.id.equals(item.id))).write(
        CatalogItemsCompanion(category: Value(id), categoryManual: const Value(true), categoryVersion: const Value(1)),
      );
      await sync.enqueue('catalog_items', item.id, 'update', {
        'category': id,
        'category_manual': true,
        'category_version': 1,
      });
    });
    _kick();
  }

  Future<Category> _category(String id) async {
    final c = await (db.select(
      db.categories,
    )..where((c) => c.id.equals(id) & c.household.equals(household) & c.deleted.equals(false))).getSingleOrNull();
    if (c == null) throw StateError('category_unavailable');
    return c;
  }

  Future<void> createCategory(String rawName) async {
    final name = cleanItemName(rawName);
    if (name.isEmpty || name.length > 80) throw ArgumentError('category_name_required');
    await initializeCategories();
    await db.transaction(() async {
      final id = newRecordId();
      final all = await (db.select(db.categories)..where((c) => c.household.equals(household))).get();
      final order = all.fold<int>(0, (v, c) => c.sortOrder > v ? c.sortOrder : v) + 10;
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: id,
              household: household,
              key: 'custom_$id',
              name: Value(name),
              sortOrder: Value(order),
            ),
          );
      await sync.enqueue('categories', id, 'create', {
        'id': id,
        'household': household,
        'key': 'custom_$id',
        'name': name,
        'is_default': false,
        'sort_order': order,
        'icon': 'category',
        'deleted': false,
      });
    });
    _kick();
  }

  Future<void> renameCategory(String id, String rawName) async {
    final name = cleanItemName(rawName);
    await db.transaction(() async {
      final c = await _category(id);
      if ((!c.isDefault && name.isEmpty) || name.length > 80) throw ArgumentError('category_name_required');
      await (db.update(db.categories)..where((c) => c.id.equals(id))).write(CategoriesCompanion(name: Value(name)));
      await sync.enqueue('categories', id, 'update', {'name': name});
    });
    _kick();
  }

  Future<void> reorderCategories(List<String> ids) async {
    await db.transaction(() async {
      final current = await watchCategories().first;
      if (ids.length != current.length ||
          ids.toSet().length != ids.length ||
          !ids.toSet().containsAll(current.map((c) => c.id))) {
        throw ArgumentError('category_order_invalid');
      }
      for (var i = 0; i < ids.length; i++) {
        if (current.firstWhere((c) => c.id == ids[i]).sortOrder == i * 10) continue;
        await (db.update(
          db.categories,
        )..where((c) => c.id.equals(ids[i]))).write(CategoriesCompanion(sortOrder: Value(i * 10)));
        await sync.enqueue('categories', ids[i], 'update', {'sort_order': i * 10});
      }
    });
    _kick();
  }

  Future<void> deleteCategory(String id) async {
    await db.transaction(() async {
      final c = await _category(id);
      if (c.isDefault) throw StateError('category_default_protected');
      // Queue only the tombstone: the server reassigns products atomically.
      // The local equivalent also repairs pending product payloads.
      await sync.applyRemote('categories', {
        'id': c.id,
        'household': household,
        'key': c.key,
        'name': c.name,
        'is_default': false,
        'sort_order': c.sortOrder,
        'icon': c.icon,
        'color': c.color,
        'deleted': true,
        'updated': c.updated,
      });
      await sync.enqueue('categories', id, 'update', {'deleted': true});
    });
    _kick();
  }

  void _kick() => sync.sync().ignore();
}
