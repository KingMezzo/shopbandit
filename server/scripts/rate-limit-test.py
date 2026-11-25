#!/usr/bin/env python3
"""Verify production rate limits on a NEW disposable localhost test server.

Does not change settings or retry rejected writes. Run separately from the
functional suites, because all clients of one IP share each applicable bucket.
"""
import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('url')
args = parser.parse_args()
assert urllib.parse.urlparse(args.url).hostname in ('127.0.0.1', 'localhost'), 'Disposable localhost server required'

for _ in range(100):
    try:
        with urllib.request.urlopen(args.url + '/api/health', timeout=1) as response:
            if response.status == 200:
                break
    except OSError:
        time.sleep(0.2)
else:
    raise RuntimeError('Disposable server did not become healthy')


def post(path, body, token='', expected=200):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = token
    request = urllib.request.Request(args.url + '/api/' + path,
                                     json.dumps(body).encode(), headers, method='POST')
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    assert status == expected, (path, status, 'expected', expected)
    return json.loads(raw)


# Failed requests consume allowance too: no need to create extra user accounts.
start = time.monotonic()
for expected in (400, 400, 429):
    post('collections/users/records', {
        'email': uuid.uuid4().hex + '@example.com', 'password': 'weak', 'passwordConfirm': 'weak',
    }, expected=expected)
assert time.monotonic() - start < 4, 'Runner too slow to test the 5-second guest limit reliably'
print('ok  guest creation: two validation failures allowed, third request receives 429', flush=True)

start = time.monotonic()
for expected in (400, 400, 429):
    post('collections/users/auth-with-password', {
        'identity': uuid.uuid4().hex + '@example.com', 'password': 'InvalidTest123!',
    }, expected=expected)
assert time.monotonic() - start < 2, 'Runner too slow to test the 3-second auth limit reliably'
print('ok  authentication: two failures allowed, third request receives 429', flush=True)

# Wait for the actual production guest/auth windows, without resetting settings.
time.sleep(5.1)
tokens = []
for _ in range(2):
    email, password = uuid.uuid4().hex + '@example.com', 'RateLimitTest123!x'
    post('collections/users/records', {
        'email': email, 'password': password, 'passwordConfirm': password,
    })
    time.sleep(3.1)
    auth = post('collections/users/auth-with-password', {'identity': email, 'password': password})
    tokens.append(auth['token'])
print('ok  authentication and guest creation recover after their normal windows', flush=True)

start = time.monotonic()
for _ in range(9):
    invite = post('shopbandit/invites/create', {}, tokens[0])
# Different users still share the same client IP and prefix limit.
post('shopbandit/invites/create', {}, tokens[1])
post('shopbandit/invites/accept', {'token': invite['token']}, tokens[1], expected=429)
assert time.monotonic() - start < 59, 'Runner exceeded the 60-second invite window'
print('ok  invitations: ten requests allowed; eleventh (accept, second user) receives 429', flush=True)
print('ALL PRODUCTION RATE-LIMIT TESTS PASSED', flush=True)
