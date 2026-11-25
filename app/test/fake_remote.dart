import 'package:shopbandit/data/remote.dart';
import 'package:shopbandit/core/categories.dart';

/// In-memory server: applies creates/updates like PocketBase incl. the
/// `field+` / `field-` modifiers and keeps an `updated` timestamp.
class FakeRemote implements SyncRemote {
  final records = <String, Map<String, Map<String, dynamic>>>{
    'catalog_items': {},
    'list_entries': {},
    'categories': {},
  };
  final users = <Map<String, dynamic>>[];
  bool online = true;
  int _tick = 0;
  final calls = <String>[];

  String _stamp() =>
      DateTime.utc(2026, 10, 24).add(Duration(milliseconds: _tick++)).toIso8601String().replaceFirst('T', ' ');

  void seedCategories(String household) {
    for (var i = 0; i < defaultCategoryKeys.length; i++) {
      final key = defaultCategoryKeys[i];
      final id = categoryId(household, key);
      records['categories']!.putIfAbsent(
        id,
        () => {
          'id': id,
          'household': household,
          'key': key,
          'name': '',
          'is_default': true,
          'sort_order': i * 10,
          'deleted': false,
          'icon': defaultCategoryIcons[i],
          'color': defaultCategoryColors[i],
          'updated': _stamp(),
        },
      );
    }
  }

  void _check() {
    if (!online) throw RemoteUnreachable('offline');
  }

  @override
  Future<void> create(String collection, Map<String, dynamic> body) async {
    _check();
    calls.add('create $collection ${body['id']}');
    final id = body['id'] as String;
    if (records[collection]!.containsKey(id)) throw RemoteRejected(400, {'id': 'exists'});
    final now = _stamp();
    records[collection]![id] = {...body, 'created': now, 'updated': now};
    if (collection == 'catalog_items') seedCategories(body['household'] as String);
  }

  @override
  Future<void> update(String collection, String id, Map<String, dynamic> body) async {
    _check();
    calls.add('update $collection $id');
    final r = records[collection]![id];
    if (r == null) throw RemoteRejected(404);
    if (collection == 'categories') {
      if (r['is_default'] == true && body['deleted'] == true) throw RemoteRejected(400);
      if (r['deleted'] == true && body['deleted'] == false) throw RemoteRejected(400);
    }
    body = Map.of(body);
    if (collection == 'catalog_items') {
      if (r['category_manual'] == true && body['category_manual'] == false) {
        body.remove('category');
        body.remove('category_manual');
      }
      final category = records['categories']![body['category']];
      if (category?['deleted'] == true) body['category'] = categoryId(r['household'] as String, 'other');
    }
    body.forEach((k, v) {
      if (k.endsWith('+')) {
        final f = k.substring(0, k.length - 1);
        r[f] = ((r[f] as num?) ?? 0) + (v as num);
      } else if (k.endsWith('-')) {
        final f = k.substring(0, k.length - 1);
        r[f] = ((r[f] as num?) ?? 0) - (v as num);
      } else {
        r[k] = v;
      }
    });
    r['updated'] = _stamp();
    if (collection == 'categories' && r['deleted'] == true) {
      for (final item in records['catalog_items']!.values.where((i) => i['category'] == id)) {
        item['category'] = categoryId(r['household'] as String, 'other');
        item['category_manual'] = true;
        item['updated'] = _stamp();
      }
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listSince(String collection, String since) async {
    _check();
    final all = records[collection]!.values.where((r) => (r['updated'] as String).compareTo(since) >= 0).toList()
      ..sort((a, b) => (a['updated'] as String).compareTo(b['updated'] as String));
    return all.map((r) => Map<String, dynamic>.of(r)).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> members() async {
    _check();
    return users;
  }
}
