"""MOCK robot: two-second heartbeat and scripted sample patrol, no hardware."""
import argparse
import json
import os
import time
from datetime import datetime, timezone
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:8000')
    parser.add_argument('--steps', type=int, default=10)
    args = parser.parse_args()
    token = os.environ['RECALL_TOKEN']
    def send(path, body, method='POST'):
        request = Request(args.url.rstrip('/')+path, data=json.dumps(body).encode(), method=method, headers={'Authorization':f'Bearer {token}','Content-Type':'application/json'})
        with urlopen(request, timeout=5) as response:
            response.read()
    metadata_request = Request(args.url.rstrip('/')+'/api/metadata', headers={'Authorization':f'Bearer {token}'})
    with urlopen(metadata_request, timeout=5) as response:
        if json.load(response).get('mock') is not True:
            raise SystemExit('Refusing to write: start the isolated seeded MOCK backend first.')
    def now():
        return datetime.now(timezone.utc).isoformat()
    started = now()
    for step in range(args.steps):
        send('/api/robot/heartbeat', dict(t=now(),state='patrolling',task='MOCK scripted patrol - SAMPLE DATA',tracking='normal',mapping_status='mapped',pose=dict(x=step,z=0,yaw_deg=0),front_cm=100,rear_cm=100,phone_battery=1,firmware_link=False))
        event_ids = []
        if step >= 2:
            event_ids = ['mock-live-event']
            send('/api/events/mock-live-event',dict(id='mock-live-event',patrol_id='mock-live-patrol',type='new_obstacle',severity='hazard',label='MOCK box',confidence=1,position=dict(x=2,y=0,z=0),previous_position=None,near_waypoint='MOCK hallway',on_route=None,distance_to_route_m=None,before_media_id=None,after_media_id=None,spoken='MOCK: sample box in hallway.',created_at=now()),'PUT')
        send('/api/patrols/mock-live-patrol',dict(id='mock-live-patrol',started_at=started,ended_at=now() if step==args.steps-1 else None,route_id='mock-route-0',path=[dict(t=i*2,x=i,z=0) for i in range(step+1)],event_ids=event_ids,summary='MOCK scripted patrol - SAMPLE DATA',stats=dict(distance_m=step,keyframes=step+1,stops=0)),'PUT')
        if step < args.steps-1:
            time.sleep(2)


if __name__ == '__main__':
    main()
