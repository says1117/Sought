"""SQLite JSON persistence; compound keys make phone retries idempotent."""
import json
import sqlite3
from pathlib import Path
from threading import RLock


class Store:
    def __init__(self, connection: sqlite3.Connection):
        self.connection = connection
        self.lock = RLock()
        connection.execute("CREATE TABLE IF NOT EXISTS records (family TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, received_at REAL, PRIMARY KEY (family, id))")
        connection.commit()

    def put(self, family: str, id: str, body: dict, received_at: float | None = None):
        with self.lock, self.connection:
            self.connection.execute(
                "INSERT INTO records (family,id,body,received_at) VALUES (?,?,?,?) ON CONFLICT(family,id) DO UPDATE SET body=excluded.body, received_at=excluded.received_at",
                (family, id, json.dumps(body, allow_nan=False), received_at),
            )
        return body

    def get(self, family: str, id: str):
        with self.lock:
            row = self.connection.execute("SELECT body,received_at FROM records WHERE family=? AND id=?", (family, id)).fetchone()
        return (json.loads(row["body"]), row["received_at"]) if row else None

    def all(self, family: str):
        with self.lock:
            rows = self.connection.execute("SELECT body FROM records WHERE family=? ORDER BY id", (family,)).fetchall()
        return [json.loads(row["body"]) for row in rows]


def connect(path: str) -> sqlite3.Connection:
    if path != ":memory:":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    return connection
