"""Generate isolated, explicitly MOCK dashboard data. Run python -m backend.seed."""
import base64
import json
import secrets
from datetime import datetime, timezone
from pathlib import Path
from PIL import Image, ImageDraw
from backend.db import Store, connect
from backend.models import Waypoint, Route, ObjectTrack, Patrol, ChangeEvent, MapSnapshot

MOCK_ROOT = Path('backend/mock')


def seed(root=MOCK_ROOT):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    media = root / 'media'
    media.mkdir(exist_ok=True)
    connection = connect(str(root / 'recall.sqlite3'))
    store = Store(connection)
    now = datetime.now(timezone.utc).isoformat()
    def put(family, model, body):
        validated = model.model_validate(body).model_dump(mode='json')
        store.put(family, validated.get('id', 'latest'), validated)
    def picture(label):
        id = secrets.token_hex(16)
        image = Image.new('RGB', (320, 200), '#eee4cf')
        ImageDraw.Draw(image).text((12, 75), 'MOCK - SAMPLE DATA\n' + label, fill='black')
        image.save(media / f'{id}.jpg', 'JPEG')
        return id
    try:
        store.put('metadata', 'mock', {'mock': True, 'label': 'SAMPLE DATA'})
        for i in range(6):
            put('waypoints', Waypoint, dict(id=f'mock-waypoint-{i}', name=f'MOCK room {i}', pose=dict(x=i, z=i%2, yaw_deg=0), created_at=now, media_id=None))
        for i in range(2):
            put('routes', Route, dict(id=f'mock-route-{i}', name=f'MOCK route {i}', waypoint_ids=[f'mock-waypoint-{j}' for j in range(i*3,i*3+3)], kind='patrol'))
        for i in range(15):
            put('objects', ObjectTrack, dict(id=f'mock-object-{i}', label=f'MOCK object {i}', label_source='user', description='SAMPLE DATA placeholder', position=dict(x=i%5,y=0,z=i//5), height_above_floor_m=0, first_seen=now,last_seen=now,sightings=1,persistence=0.5,media_id=picture(f'Object {i}'),history=[]))
        for i in range(4):
            put('patrols', Patrol, dict(id=f'mock-patrol-{i}',started_at=now,ended_at=now,route_id=f'mock-route-{i%2}',path=[dict(t=j,x=j,z=i) for j in range(3)],event_ids=[f'mock-event-{j}' for j in range(10) if j%4==i],summary='MOCK patrol - SAMPLE DATA',stats=dict(distance_m=2,keyframes=3,stops=0)))
        for i in range(10):
            put('events', ChangeEvent, dict(id=f'mock-event-{i}',patrol_id=f'mock-patrol-{i%4}',type='new_obstacle' if i%3==0 else 'moved',severity='hazard' if i%3==0 else 'info',label=f'MOCK change {i}',confidence=0.8,position=dict(x=i%5,y=0,z=i//5),previous_position=None,near_waypoint='MOCK room 0',on_route='mock-route-0',distance_to_route_m=0.3 if i%3==0 else 1.0,before_media_id=picture('Before'),after_media_id=picture('After'),spoken='MOCK: a sample object changed.',created_at=now))
        put('map', MapSnapshot, dict(resolution_m=1,origin=dict(x=0,z=0),width=6,height=6,cells_b64=base64.b64encode(bytes([1]*36)).decode(),updated_at=now))
        (root/'results.json').write_text(json.dumps({'sample':True,'label':'SAMPLE DATA','generated_at':now,'retrieval':[{'variant':'MOCK','n':10,'top1':6,'top3':9,'pos_err_cm_median':20}],'find_end_to_end':[{'variant':'MOCK','n':10,'success':7,'median_time_s':12,'near_misses':1}],'change_detection':[], 'memory':[], 'notes':'SAMPLE DATA: all values are fabricated fixtures, never measured results. Change detection and memory are unmeasured.'}))
    finally:
        connection.close()
    return root


if __name__ == '__main__':
    print(f'MOCK data created in {seed()}; see backend/README.md for isolated server configuration.')
