import hashlib
import json
import os
import secrets
import time
import uuid

import jwt
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from core import MAX_UPLOAD, Store, clean_jpeg

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
store = Store()
apple_keys = jwt.PyJWKClient('https://appleid.apple.com/auth/keys', cache_jwk_set=True, lifespan=3600, timeout=10)


class BodyLimit:
    """Apply before multipart/JSON parsing, including chunked transfer requests."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        maximum = MAX_UPLOAD + 65536 if scope['path'] == '/v1/jobs' else 65536
        total = 0
        async def limited_receive():
            nonlocal total
            event = await receive()
            total += len(event.get('body', b''))
            if total > maximum:
                raise HTTPException(413, '请求过大')
            return event
        await self.app(scope, limited_receive, send)


app.add_middleware(BodyLimit)


@app.middleware('http')
async def private_response(request, call_next):
    response = await call_next(request)
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    return response


def authenticate(authorization: str = Header(default='')):
    if not authorization.startswith('Bearer '):
        raise HTTPException(401, '请先登录')
    digest = hashlib.sha256(authorization[7:].encode()).hexdigest()
    with store.db() as db:
        session = db.execute('SELECT * FROM sessions WHERE digest=? AND expires>?', (digest, time.time())).fetchone()
    if not session:
        raise HTTPException(401, '登录已过期，请重新登录')
    return session['owner']


@app.get('/health')
def health():
    return {'status': 'ok'}


@app.post('/v1/auth/challenge')
def challenge():
    nonce, challenge_id = secrets.token_urlsafe(32), str(uuid.uuid4())
    with store.db() as db:
        db.execute('DELETE FROM challenges WHERE expires<?', (time.time(),))
        if db.execute('SELECT count(*) FROM challenges').fetchone()[0] >= 1000:
            raise HTTPException(429, '请稍后再试')
        db.execute('INSERT INTO challenges VALUES (?,?,?)', (challenge_id, nonce, time.time() + 300))
    return {'id': challenge_id, 'nonce': hashlib.sha256(nonce.encode()).hexdigest()}


class AppleLogin(BaseModel):
    challenge_id: uuid.UUID
    identity_token: str = Field(min_length=20, max_length=16384)


def verify_apple(token):
    audience = os.environ.get('APPLE_CLIENT_ID', '')
    if not audience:
        raise HTTPException(503, '登录服务尚未配置')
    try:
        key = apple_keys.get_signing_key_from_jwt(token).key
        return jwt.decode(token, key, algorithms=['RS256'], audience=audience, issuer='https://appleid.apple.com',
                          options={'require': ['exp', 'iat', 'sub', 'iss', 'aud', 'nonce']})
    except Exception:
        raise HTTPException(401, 'Apple身份验证失败') from None


@app.post('/v1/auth/apple')
def apple_login(payload: AppleLogin):
    claims = verify_apple(payload.identity_token)
    with store.db() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT * FROM challenges WHERE id=? AND expires>?', (str(payload.challenge_id), time.time())).fetchone()
        if not row or not secrets.compare_digest(str(claims.get('nonce', '')), hashlib.sha256(row['nonce'].encode()).hexdigest()):
            raise HTTPException(401, '登录请求无效或已过期')
        allowed = {s.strip() for s in os.environ.get('ALLOWED_APPLE_SUBS', '').split(',') if s.strip()}
        # Fail closed. Operator authorizes accounts; a public extracted client cannot spend freely.
        if claims['sub'] not in allowed:
            raise HTTPException(403, '此账号尚未获准使用云端服务')
        db.execute('DELETE FROM challenges WHERE id=?', (str(payload.challenge_id),))
        token = secrets.token_urlsafe(48)
        owner = hashlib.sha256(('apple:' + claims['sub']).encode()).hexdigest()
        db.execute('INSERT INTO sessions VALUES (?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), owner, time.time() + 86400))
    return {'access_token': token, 'expires_in': 86400}


@app.post('/v1/auth/logout', status_code=204)
def logout(owner=Depends(authenticate), authorization: str = Header(default='')):
    with store.db() as db:
        db.execute('DELETE FROM sessions WHERE digest=?', (hashlib.sha256(authorization[7:].encode()).hexdigest(),))
    return Response(status_code=204)


@app.get('/v1/me')
def me(owner=Depends(authenticate)):
    return {'authenticated': True}


def public_job(row):
    state = 'expired' if row['expires'] <= time.time() else row['state']
    return {'id': row['id'], 'kind': row['kind'], 'state': state, 'model': row['model'],
            'error': row['error'], 'advice': json.loads(row['advice']) if state == 'completed' and row['advice'] else None}


@app.post('/v1/jobs', status_code=202)
async def create_job(idempotency_key: str = Header(alias='Idempotency-Key'), kind: str = Form(),
                     instruction: str = Form(max_length=5000), image: UploadFile = File(), owner=Depends(authenticate)):
    try:
        job_id = str(uuid.UUID(idempotency_key))
    except ValueError:
        raise HTTPException(422, '任务编号无效') from None
    if kind not in ('advice', 'edit') or not instruction.strip():
        raise HTTPException(422, '任务要求无效')
    raw = await image.read(MAX_UPLOAD + 1)
    await image.close()
    if len(raw) > MAX_UPLOAD:
        raise HTTPException(413, '图片过大')
    try:
        prepared = await run_in_threadpool(clean_jpeg, raw, 1280 if kind == 'advice' else 3072)
    except Exception:
        raise HTTPException(422, '图片格式或尺寸不支持') from None
    try:
        row = await run_in_threadpool(store.enqueue, owner, job_id, kind, instruction, prepared)
    except PermissionError:
        raise HTTPException(404, '任务不存在') from None
    except ValueError:
        raise HTTPException(409, '同一任务编号不能更换照片或要求') from None
    except OverflowError:
        raise HTTPException(429, '已达任务或每日额度上限') from None
    return public_job(row)


@app.get('/v1/jobs/{job_id}')
def job_status(job_id: uuid.UUID, owner=Depends(authenticate)):
    row = store.get(owner, str(job_id))
    if not row:
        raise HTTPException(404, '任务不存在')
    return public_job(row)


@app.get('/v1/jobs/{job_id}/result')
def job_result(job_id: uuid.UUID, owner=Depends(authenticate)):
    row = store.get(owner, str(job_id))
    if not row:
        raise HTTPException(404, '任务不存在')
    if row['expires'] <= time.time() or row['state'] == 'expired':
        raise HTTPException(410, '云端副本已过期；本机原片不受影响')
    if row['state'] != 'completed' or row['kind'] != 'edit' or not row['result']:
        raise HTTPException(409, '结果尚不可用，请查询原任务')
    data = row['result']
    return Response(data, media_type='image/jpeg', headers={'ETag': '"' + hashlib.sha256(data).hexdigest() + '"'})
