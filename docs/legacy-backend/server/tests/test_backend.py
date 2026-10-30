import base64
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
_tmp = tempfile.TemporaryDirectory()
os.environ['DATABASE_PATH'] = _tmp.name + '/initial.sqlite3'
import app as api
from core import Store, clean_jpeg, editing_prompt, process_one, validate_advice


def jpeg():
    out = io.BytesIO()
    Image.new('RGB', (128, 96), (180, 130, 95)).save(out, 'JPEG', exif=Image.Exif())
    return out.getvalue()


ADVICE = dict(scene='户外人像', strengths=['自然'], issues=[], recommendations=[], edit_prompt='保持原片', preserve=['人物'])


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name + '/test.sqlite3')
        self.store_patch = patch.object(api, 'store', self.store)
        self.store_patch.start()
        self.client = TestClient(api.app)
        self.token = 'fixture-session-only'
        self.owner = 'owner-one'
        with self.store.db() as db:
            db.execute('INSERT INTO sessions VALUES (?,?,?)', (hashlib.sha256(self.token.encode()).hexdigest(), self.owner, time.time() + 1000))
        self.headers = {'Authorization': 'Bearer ' + self.token}
        self.job_id = str(uuid.uuid4())

    def tearDown(self):
        self.client.close()
        self.store_patch.stop()
        self.tmp.cleanup()

    def upload(self, kind='edit', instruction='适度提亮', job_id=None, raw=None, headers=None):
        return self.client.post('/v1/jobs', headers={**(headers or self.headers), 'Idempotency-Key': job_id or self.job_id},
                                data={'kind': kind, 'instruction': instruction}, files={'image': ('photo.jpg', raw or jpeg(), 'image/jpeg')})

    def test_auth_required(self):
        response = self.client.get('/v1/jobs/' + self.job_id)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.headers['cache-control'], 'no-store')

    def test_duplicate_same_id_is_one_job(self):
        self.assertEqual(self.upload().status_code, 202)
        self.assertEqual(self.upload().status_code, 202)
        with self.store.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT used FROM budgets WHERE owner=?', (self.owner,)).fetchone()[0], 1)

    def test_changed_prompt_conflicts(self):
        self.upload()
        self.assertEqual(self.upload(instruction='换天空').status_code, 409)

    def test_other_owner_cannot_query_or_download(self):
        self.upload()
        with self.store.db() as db:
            db.execute('UPDATE sessions SET owner=?', ('owner-two',))
        self.assertEqual(self.client.get('/v1/jobs/' + self.job_id, headers=self.headers).status_code, 404)
        self.assertEqual(self.client.get('/v1/jobs/' + self.job_id + '/result', headers=self.headers).status_code, 404)
        self.assertEqual(self.upload().status_code, 404)

    def test_invalid_image(self):
        self.assertEqual(self.upload(raw=b'not-an-image').status_code, 422)
        self.assertEqual(self.upload(kind='arbitrary-proxy').status_code, 422)

    def test_active_job_limit(self):
        self.upload()
        self.upload(job_id=str(uuid.uuid4()))
        self.assertEqual(self.upload(job_id=str(uuid.uuid4())).status_code, 429)

    def test_daily_limit_and_idempotent_retry(self):
        with patch.dict(os.environ, {'USER_DAILY_LIMIT': '1'}):
            self.assertEqual(self.upload().status_code, 202)
            self.assertEqual(self.upload().status_code, 202)
            self.assertEqual(self.upload(job_id=str(uuid.uuid4())).status_code, 429)

    def test_claim_atomic_and_recover_no_replay(self):
        self.upload()
        self.assertIsNotNone(self.store.claim())
        self.assertIsNone(self.store.claim())
        self.store.recover()
        self.assertEqual(self.store.get(self.owner, self.job_id)['state'], 'unknown')
        self.assertFalse(process_one(self.store))
        self.assertEqual(self.upload().json()['state'], 'unknown')

    def test_seedream_payload_and_authenticated_download(self):
        self.upload()
        calls = []
        def handler(request):
            calls.append(request)
            body = json.loads(request.content)
            self.assertEqual(request.url.host, 'ark.cn-beijing.volces.com')
            self.assertEqual(body['response_format'], 'b64_json')
            self.assertTrue(body['watermark'])
            self.assertIn('自然精修约束', body['prompt'])
            self.assertTrue(body['image'].startswith('data:image/jpeg;base64,'))
            return httpx.Response(200, json={'data': [{'b64_json': base64.b64encode(jpeg()).decode()}]})
        with patch.dict(os.environ, {'SEEDREAM_API_KEY': 'fixture-provider-secret'}), httpx.Client(transport=httpx.MockTransport(handler)) as client:
            self.assertTrue(process_one(self.store, client))
            self.assertFalse(process_one(self.store, client))
        result = self.client.get('/v1/jobs/' + self.job_id + '/result', headers=self.headers)
        self.assertEqual(result.content, jpeg())
        self.assertEqual(result.headers['content-type'], 'image/jpeg')
        self.assertEqual(len(calls), 1)
        public = self.client.get('/v1/jobs/' + self.job_id, headers=self.headers).text
        self.assertNotIn('fixture-provider-secret', public)
        self.assertNotIn('b64_json', public)

    def test_deepseek_does_not_call_seedream(self):
        self.upload(kind='advice')
        calls = []
        def handler(request):
            calls.append(request)
            self.assertEqual(request.url.host, 'api.deepseek.com')
            body = json.loads(request.content)
            self.assertIn('image_url', body['messages'][1]['content'][1])
            return httpx.Response(200, json={'choices': [{'message': {'content': json.dumps(ADVICE)}}]})
        with patch.dict(os.environ, {'DEEPSEEK_API_KEY': 'fixture'}), httpx.Client(transport=httpx.MockTransport(handler)) as client:
            process_one(self.store, client)
        status = self.client.get('/v1/jobs/' + self.job_id, headers=self.headers).json()
        self.assertEqual(status['advice']['issues'], [])
        self.assertEqual(len(calls), 1)

    def test_provider_error_is_sanitized_and_never_retried(self):
        self.upload()
        calls = []
        def handler(request):
            calls.append(request)
            return httpx.Response(429, text='fixture-secret-private-error')
        with patch.dict(os.environ, {'SEEDREAM_API_KEY': 'fixture-secret'}), httpx.Client(transport=httpx.MockTransport(handler)) as client:
            process_one(self.store, client)
            process_one(self.store, client)
        public = self.client.get('/v1/jobs/' + self.job_id, headers=self.headers)
        self.assertEqual(public.json()['state'], 'unknown')
        self.assertNotIn('fixture-secret', public.text)
        self.assertEqual(len(calls), 1)

    def test_remote_result_url_is_not_fetched(self):
        self.upload()
        with patch.dict(os.environ, {'SEEDREAM_API_KEY': 'fixture'}), httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(200, json={'data': [{'url': 'http://127.0.0.1/private'}]}))) as client:
            process_one(self.store, client)
        self.assertEqual(self.store.get(self.owner, self.job_id)['state'], 'unknown')

    def test_expiry_deletes_images_retains_idempotency(self):
        self.upload()
        self.store.complete(self.job_id, result=jpeg())
        with self.store.db() as db:
            db.execute('UPDATE jobs SET expires=?', (time.time() - 1,))
        self.store.cleanup()
        row = self.store.get(self.owner, self.job_id)
        self.assertIsNone(row['result'])
        self.assertIsNone(row['image'])
        self.assertEqual(self.upload().json()['state'], 'expired')
        self.assertEqual(self.client.get('/v1/jobs/' + self.job_id + '/result', headers=self.headers).status_code, 410)

    def test_apple_nonce_single_use_and_allowlist(self):
        challenge = self.client.post('/v1/auth/challenge').json()
        claims = {'sub': 'authorized-apple-id', 'nonce': challenge['nonce']}
        payload = {'challenge_id': challenge['id'], 'identity_token': 'mock-token-more-than-twenty-characters'}
        with patch.object(api, 'verify_apple', return_value=claims), patch.dict(os.environ, {'ALLOWED_APPLE_SUBS': 'authorized-apple-id'}):
            result = self.client.post('/v1/auth/apple', json=payload)
            self.assertEqual(result.status_code, 200)
            self.assertEqual(self.client.post('/v1/auth/apple', json=payload).status_code, 401)
        with patch.object(api, 'verify_apple', return_value=claims), patch.dict(os.environ, {'ALLOWED_APPLE_SUBS': ''}):
            next_challenge = self.client.post('/v1/auth/challenge').json()
            claims['nonce'] = next_challenge['nonce']
            payload['challenge_id'] = next_challenge['id']
            self.assertEqual(self.client.post('/v1/auth/apple', json=payload).status_code, 403)

    def test_bad_apple_nonce(self):
        challenge = self.client.post('/v1/auth/challenge').json()
        with patch.object(api, 'verify_apple', return_value={'sub': 'one', 'nonce': 'wrong'}):
            result = self.client.post('/v1/auth/apple', json={'challenge_id': challenge['id'], 'identity_token': 'mock-token-more-than-twenty-characters'})
            self.assertEqual(result.status_code, 401)

    def test_real_apple_signature_audience_issuer_and_expiry(self):
        import jwt
        from cryptography.hazmat.primitives.asymmetric import rsa
        from types import SimpleNamespace
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        claims = dict(sub='apple-user', nonce='hash', iss='https://appleid.apple.com', aud='com.example.test', iat=int(time.time()), exp=int(time.time()) + 300)
        with patch.dict(os.environ, {'APPLE_CLIENT_ID': 'com.example.test'}), patch.object(api.apple_keys, 'get_signing_key_from_jwt', return_value=SimpleNamespace(key=key.public_key())):
            valid = jwt.encode(claims, key, algorithm='RS256')
            self.assertEqual(api.verify_apple(valid)['sub'], 'apple-user')
            for changed in [dict(aud='wrong'), dict(iss='https://evil.invalid'), dict(exp=1)]:
                token = jwt.encode({**claims, **changed}, key, algorithm='RS256')
                with self.assertRaises(api.HTTPException):
                    api.verify_apple(token)
            wrong_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            with self.assertRaises(api.HTTPException):
                api.verify_apple(jwt.encode(claims, wrong_key, algorithm='RS256'))

    def test_size_limit_before_multipart_processing(self):
        response = self.client.post('/v1/auth/apple', content=b'x' * 65537, headers={'Content-Type': 'application/json'})
        self.assertEqual(response.status_code, 413)

    def test_logout_revokes_session(self):
        self.assertEqual(self.client.post('/v1/auth/logout', headers=self.headers).status_code, 204)
        self.assertEqual(self.client.get('/v1/me', headers=self.headers).status_code, 401)

    def test_policy_limits_and_idempotency(self):
        prompt = editing_prompt('提亮面部')
        self.assertEqual(editing_prompt(prompt), prompt)
        with self.assertRaises(ValueError):
            validate_advice({**ADVICE, 'issues': ['1', '2', '3', '4']})

    def test_upload_strips_location(self):
        image = Image.new('RGB', (200, 300))
        exif = Image.Exif()
        exif[270] = 'private camera metadata'
        buffer = io.BytesIO()
        image.save(buffer, 'JPEG', exif=exif)
        cleaned = Image.open(io.BytesIO(clean_jpeg(buffer.getvalue())))
        self.assertFalse(cleaned.getexif())

if __name__ == '__main__':
    unittest.main()
