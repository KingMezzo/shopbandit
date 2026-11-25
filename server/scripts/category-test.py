#!/usr/bin/env python3
"""Real PocketBase category/API tests. Use ONLY a disposable local test server.

python server/scripts/category-test.py http://127.0.0.1:18090
--prepare-legacy FILE writes old-schema fixtures for the upgrade/copy test.
--verify-legacy FILE checks the same records after the additive migration.
"""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('url')
parser.add_argument('--prepare-legacy', type=pathlib.Path)
parser.add_argument('--verify-legacy', type=pathlib.Path)
parser.add_argument('--stale-snapshot-tests', action='store_true',
                    help='Requires the test-only stale_categories.pb.js fixture mounted in the disposable server')
parser.add_argument('--race-rounds', type=int, default=12)
args = parser.parse_args()
assert urllib.parse.urlparse(args.url).hostname in ('localhost', '127.0.0.1'), 'Disposable localhost server required'

for attempt in range(100):
    try:
        with urllib.request.urlopen(args.url + '/api/health', timeout=1) as response:
            if response.status == 200:
                break
    except OSError:
        time.sleep(0.2)
else:
    raise RuntimeError('Disposable test server did not become healthy')


def req(method, path, body=None, token='', expected=200):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = token
    request = urllib.request.Request(args.url + '/api/' + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    value = json.loads(raw) if raw else {}
    if isinstance(expected, int):
        assert status == expected, (method, path, status, value)
    else:
        assert status in expected, (method, path, status, value)
    return value


def signup():
    email = uuid.uuid4().hex + '@example.com'
    password = 'CategoryTest123!x'
    req('POST', 'collections/users/records', {'email': email, 'password': password, 'passwordConfirm': password, 'name': 'Category Test'})
    time.sleep(3.1)  # existing guest/auth rate limits
    auth = req('POST', 'collections/users/auth-with-password', {'identity': email, 'password': password})
    return auth['token'], auth['record']


def path(collection, id=''):
    return f'collections/{collection}/records' + (f'/{id}' if id else '?perPage=500')


def cid(h, key):
    return hashlib.sha256(f'{h}|category|{key}'.encode()).hexdigest()[:15]


def item(token, user, name='Milch', **extra):
    return req('POST', path('catalog_items').split('?')[0], {
        'id': uuid.uuid4().hex[:15], 'household': user['household'],
        'name': name, 'name_normalized': name.lower(), **extra,
    }, token)


def ok(label):
    print('ok  ' + label, flush=True)


if args.prepare_legacy:
    token, user = signup()
    milk = item(token, user, purchase_count=7, last_purchased='2026-10-24 10:00:00.000Z')
    mystery = item(token, user, 'Unbekanntes Produkt', deleted=True, purchase_count=3)
    entry = req('POST', 'collections/list_entries/records', {
        'id': uuid.uuid4().hex[:15], 'household': user['household'], 'catalog_item': milk['id'],
        'added_by': user['id'], 'quantity': '2 l',
    }, token)
    args.prepare_legacy.write_text(json.dumps({'token': token, 'user': user, 'items': [milk, mystery], 'entry': entry}), encoding='utf-8')
    ok('legacy household, catalog statistics, soft-delete and list fixture created')
    raise SystemExit()

if args.verify_legacy:
    fixture = json.loads(args.verify_legacy.read_text(encoding='utf-8'))
    token, user = fixture['token'], fixture['user']
    categories = req('GET', path('categories'), token=token)['items']
    assert len(categories) == 12
    for old, key in zip(fixture['items'], ['dairy_eggs', 'other']):
        new = req('GET', path('catalog_items', old['id']), token=token)
        for field in ('id', 'household', 'name', 'name_normalized', 'purchase_count', 'last_purchased', 'deleted'):
            assert new[field] == old[field], (field, new, old)
        assert new['category'] == cid(user['household'], key)
    new_entry = req('GET', path('list_entries', fixture['entry']['id']), token=token)
    for field in ('id', 'catalog_item', 'quantity', 'added_by', 'checked', 'deleted'):
        assert new_entry[field] == fixture['entry'][field]
    ok('filled legacy database copy migrated without data loss')
    raise SystemExit()

token, user = signup()
hid = user['household']
categories = req('GET', path('categories'), token=token)['items']
assert len(categories) == 12
assert {c['id'] for c in categories} == {cid(hid, c['key']) for c in categories}
ok('12 stable defaults for new household, regular member permissions')

milk = item(token, user)
assert milk['category'] == cid(hid, 'dairy_eggs') and not milk['category_manual']
req('PATCH', path('catalog_items', milk['id']), {'category': cid(hid, 'drinks')}, token)
new = req('PATCH', path('catalog_items', milk['id']), {'category': cid(hid, 'dairy_eggs'), 'category_manual': False, 'category_version': 0}, token)
assert new['category'] == cid(hid, 'drinks') and new['category_manual']
req('PATCH', path('catalog_items', milk['id']), {'purchase_count+': 1, 'deleted': True}, token)
new = req('PATCH', path('catalog_items', milk['id']), {'deleted': False}, token)
assert new['category'] == cid(hid, 'drinks') and new['purchase_count'] == 1
ok('automatic categorization, manual override, purchase count and restore')

for category in categories:
    req('PATCH', path('categories', category['id']), {'deleted': True}, token, expected=400)
    req('DELETE', path('categories', category['id']), token=token, expected=(400, 403))
req('PATCH', path('categories', cid(hid, 'drinks')), {'name': 'Unser Regal', 'sort_order': 1}, token)
req('PATCH', path('categories', cid(hid, 'drinks')), {'name': ''}, token)
req('PATCH', path('categories', cid(hid, 'drinks')), {'key': 'custom_invalid'}, token, expected=400)
ok('defaults protected, rename/reset/order, stable identity')

custom = req('POST', 'collections/categories/records', {
    'id': uuid.uuid4().hex[:15], 'household': hid, 'key': 'custom_' + uuid.uuid4().hex,
    'name': 'Unser Vorrat', 'sort_order': 200,
}, token)
req('PATCH', path('catalog_items', milk['id']), {'category': custom['id'], 'category_manual': True}, token)
req('PATCH', path('categories', custom['id']), {'deleted': True}, token)
new = req('GET', path('catalog_items', milk['id']), token=token)
assert new['category'] == cid(hid, 'other') and new['category_manual']
req('PATCH', path('categories', custom['id']), {'name': 'Stale rename'}, token)
req('PATCH', path('categories', custom['id']), {'deleted': False}, token, expected=400)
new = req('PATCH', path('catalog_items', milk['id']), {'category': custom['id'], 'category_manual': True}, token)
assert new['category'] == cid(hid, 'other')
ok('atomic delete/reassignment, stale rename and offline assignment cannot resurrect')

extra_categories = 0
if args.stale_snapshot_tests:
    for operation in ('rename', 'sort', 'restore'):
        race = req('POST', 'collections/categories/records', {
            'household': hid, 'key': 'stale_' + uuid.uuid4().hex, 'name': 'Snapshot',
        }, token)
        extra_categories += 1
        req('PATCH', path('catalog_items', milk['id']), {'category': race['id'], 'category_manual': True}, token)
        result = req('POST', 'shopbandit-test/stale-category', {'id': race['id'], 'operation': operation}, token)
        assert result['deleted'], ('stale snapshot resurrected category', operation, result)
        assert req('GET', path('categories', race['id']), token=token)['deleted']
        assert req('GET', path('catalog_items', milk['id']), token=token)['category'] == cid(hid, 'other')
    auto = item(token, user, 'Gouda')
    result = req('POST', 'shopbandit-test/stale-product', {'id': auto['id']}, token)
    assert result['category'] == cid(hid, 'drinks') and result['category_manual']
    assert result['purchase_count'] == 1
    merge = req('POST', 'collections/categories/records', {
        'household': hid, 'key': 'merge_' + uuid.uuid4().hex, 'name': 'Before merge',
    }, token)
    extra_categories += 1
    result = req('POST', 'shopbandit-test/stale-category', {'id': merge['id'], 'operation': 'merge'}, token)
    assert result['name'] == 'Delayed rename' and result['sort_order'] == 777, result
    assert result['icon'] == 'eco' and result['color'] == 'green' and not result['deleted']
    auto = item(token, user, 'Automatischer Testartikel', category=merge['id'], category_manual=False, category_version=1)
    result = req('POST', 'shopbandit-test/stale-product', {'id': auto['id'], 'operation': 'delete'}, token)
    assert result['category'] == cid(hid, 'other') and result['category_manual']
    assert result['purchase_count'] == 1
    ok('deterministic snapshots: rename/sort/restore, field merge, manual category and deletion during purchase')

assert 1 <= args.race_rounds <= 50
for round_number in range(args.race_rounds):
    # Respect the existing 300 requests/10s limit; never turn rate limiting off.
    if round_number and round_number % 4 == 0:
        time.sleep(10.1)
    race = req('POST', 'collections/categories/records', {
        'household': hid, 'key': 'race_' + uuid.uuid4().hex, 'name': 'Parallel',
    }, token)
    extra_categories += 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        actions = [
            (path('categories', race['id']), {'name': 'Parallel rename'}),
            (path('categories', race['id']), {'sort_order': round_number}),
            (path('categories', race['id']), {'deleted': True}),
            (path('catalog_items', milk['id']), {'category': race['id'], 'category_manual': True}),
        ]
        futures = [executor.submit(req, 'PATCH', endpoint, body, token) for endpoint, body in actions]
        for future in futures:
            future.result()
    result = req('GET', path('categories', race['id']), token=token)
    assert result['deleted'], ('concurrent update resurrected category', round_number, result)
    product = req('GET', path('catalog_items', milk['id']), token=token)
    assert product['category'] == cid(hid, 'other') and product['category_manual']
ok(f'{args.race_rounds} concurrent rename/sort/delete/assignment rounds remain atomic and orphan-free')

time.sleep(3.1)
other_token, other_user = signup()
other_hid = other_user['household']
assert req('GET', path('categories'), token=other_token)['totalItems'] == 12
req('GET', path('categories', categories[0]['id']), token=other_token, expected=404)
req('PATCH', path('catalog_items', milk['id']), {'category': cid(other_hid, 'other')}, token, expected=400)
req('PATCH', path('categories', categories[0]['id']), {'household': other_hid}, token, expected=(400, 404))
item(other_token, other_user, 'Banane')
assert req('GET', path('catalog_items'), token=other_token)['totalItems'] == 1
ok('cross-household read/write/relation isolation')

# Existing membership flow deletes an abandoned single-member household.
invite = req('POST', 'shopbandit/invites/create', {}, token)
req('POST', 'shopbandit/invites/accept', {'token': invite['token']}, other_token)
auth = req('POST', 'collections/users/auth-refresh', {}, other_token)
assert auth['record']['household'] == hid
assert req('GET', path('categories'), token=auth['token'])['totalItems'] == 13 + extra_categories
ok('household join/cascade and shared categories')
print('ALL CATEGORY API TESTS PASSED')
