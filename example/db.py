import json
import os
import sqlite3
from contextlib import closing, contextmanager
from uuid import uuid4


@contextmanager
def transaction():
    with closing(sqlite3.connect(os.getenv("DB_PATH", "example.sqlite3"))) as db, db:
        db.row_factory = sqlite3.Row
        yield db


def initialize():
    with transaction() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS orders (
                id TEXT PRIMARY KEY,
                status TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS inbox (
                id TEXT PRIMARY KEY
            );
            CREATE TABLE IF NOT EXISTS outbox (
                id TEXT PRIMARY KEY,
                body TEXT NOT NULL,
                published INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS projection (
                order_id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                effect_count INTEGER NOT NULL
            );
            """
        )


def emit(db, topic, order_id, **details):
    message = {"id": uuid4().hex, "event": topic, "order_id": order_id, **details}
    db.execute("INSERT INTO outbox(id, body) VALUES (?, ?)", (message["id"], json.dumps(message)))


def set_status(db, order_id, status):
    db.execute(
        """
        INSERT INTO orders(id, status) VALUES (?, ?)
        ON CONFLICT(id) DO UPDATE SET status = excluded.status
        """,
        (order_id, status),
    )
