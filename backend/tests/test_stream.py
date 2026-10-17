"""Synthetic notification and mock-data tests; no measured results."""
import asyncio
import json
import pytest
from fastapi.testclient import TestClient
from backend.app import create_app
from backend.seed import seed
from backend.stream import Broker
from backend.db import Store, connect
from backend.tests.test_endpoints import SAMPLES, HEARTBEAT


def test_broker_keepalive_cleanup_and_overflow():
    async def check():
        broker = Broker()
        queue = broker.subscribe()
        stream = broker.messages(queue, interval=0.001)
        assert await anext(stream) == ': connected\n\n'
        assert await anext(stream) == ': keep-alive\n\n'
        broker.publish('command', {'id':'sample'})
        assert 'event: command\n' in await anext(stream)
        await stream.aclose()
        assert not broker.clients
        queue = broker.subscribe()
        for _ in range(65):
            broker.publish('object', {})
        assert not broker.clients
        assert await queue.get() is None
    asyncio.run(check())


def test_notifications_and_evals(monkeypatch, tmp_path):
    monkeypatch.setenv('RECALL_TOKEN', 'sample-token')
    monkeypatch.setenv('RECALL_DB_PATH', str(tmp_path/'test.db'))
    monkeypatch.setenv('RECALL_MEDIA_DIR', str(tmp_path/'media'))
    monkeypatch.setenv('RECALL_EVALS_PATH', str(tmp_path/'results.json'))
    app = create_app()
    with TestClient(app, headers={'Authorization':'Bearer sample-token'}) as client:
        queue = app.state.broker.subscribe()
        for family,event in [('objects','object'),('patrols','patrol'),('events','event')]:
            sample = SAMPLES[family]
            assert client.put(f'/api/{family}/{sample["id"]}',json=sample).status_code == 200
            assert queue.get_nowait() == (event,sample)
            assert app.state.store.get(family,sample['id']) is not None
            assert client.put(f'/api/{family}/wrong',json=sample).status_code == 422
            assert queue.empty()
        assert client.post('/api/robot/heartbeat',json=HEARTBEAT).status_code == 200
        assert queue.get_nowait() == ('heartbeat',HEARTBEAT)
        assert client.get('/api/evals').json() == {}
        (tmp_path/'results.json').write_text('{bad')
        assert client.get('/api/evals').status_code == 503
        (tmp_path/'results.json').write_text('{"sample":NaN}')
        assert client.get('/api/evals').status_code == 503
        (tmp_path/'results.json').write_text('[]')
        assert client.get('/api/evals').status_code == 503
        (tmp_path/'results.json').write_text('{"sample":true}')
        assert client.get('/api/evals').json() == {'sample':True}
        assert client.get('/api/metadata').json() == {'mock':False}
        assert client.get('/api/stream', headers={'Authorization':''}).status_code == 401


def test_seed_isolated(tmp_path):
    root = seed(tmp_path/'mock')
    conn = connect(str(root/'recall.sqlite3'))
    store = Store(conn)
    for family,count in [('waypoints',6),('routes',2),('objects',15),('patrols',4),('events',10)]:
        assert len(store.all(family)) == count
    assert store.get('metadata','mock')[0]['mock'] is True
    assert all('MOCK' in item['label'] for item in store.all('objects'))
    assert len(list((root/'media').glob('*.jpg'))) == 35
    results = json.loads((root/'results.json').read_text())
    assert results['label'] == 'SAMPLE DATA'
    assert isinstance(results['generated_at'], str)
    assert isinstance(results['notes'], str)
    retrieval = results['retrieval'][0]
    assert retrieval['top1'] == 6 <= retrieval['top3'] == 9 <= retrieval['n'] == 10
    assert 'pos_err_cm_median' in retrieval
    find = results['find_end_to_end'][0]
    assert find['success'] == 7 <= find['n'] == 10
    assert {'median_time_s', 'near_misses'} <= find.keys()
    assert results['change_detection'] == results['memory'] == []
    conn.close()
