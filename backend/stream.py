"""Bounded live notifications; slow consumers disconnect and recover via GET."""
import asyncio
import json


class Broker:
    def __init__(self):
        self.clients = set()

    def subscribe(self):
        queue = asyncio.Queue(maxsize=64)
        self.clients.add(queue)
        return queue

    def publish(self, event, body):
        if event not in {'heartbeat', 'event', 'object', 'patrol', 'command'}:
            raise ValueError('Unsupported stream event')
        for queue in tuple(self.clients):
            if queue.full():
                self.clients.discard(queue)
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(None)
            else:
                queue.put_nowait((event, body))

    async def messages(self, queue, interval=15):
        try:
            yield ': connected\n\n'
            while True:
                try:
                    message = await asyncio.wait_for(queue.get(), timeout=interval)
                except asyncio.TimeoutError:
                    yield ': keep-alive\n\n'
                    continue
                if message is None:
                    return
                event, body = message
                yield f'event: {event}\ndata: {json.dumps(body, allow_nan=False)}\n\n'
        finally:
            self.clients.discard(queue)
