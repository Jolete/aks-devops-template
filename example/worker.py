import argparse
import json
import os
import sqlite3
import threading
import time
from http.server import ThreadingHTTPServer

import pika

from api import Projection
from db import emit, initialize, set_status, transaction

EVENTS = "lab.events"
COMMANDS = "lab.commands"
MAX_ATTEMPTS = 3

BINDINGS = {
    "saga": {
        EVENTS: ("order.placed", "fulfillment.completed", "fulfillment.rejected", "fulfillment.released"),
    },
    "fulfillment": {
        COMMANDS: ("fulfillment.requested", "fulfillment.release_requested"),
    },
    "projection": {EVENTS: ("saga.*",)},
}
COMMAND_TOPICS = {"fulfillment.requested", "fulfillment.release_requested"}


def declare_topology(channel):
    for exchange in (EVENTS, COMMANDS):
        channel.exchange_declare(exchange, exchange_type="topic", durable=True)
    for role, bindings in BINDINGS.items():
        queue = f"lab.{role}"
        channel.queue_declare(queue, durable=True)
        channel.queue_declare(
            queue + ".retry",
            durable=True,
            arguments={
                "x-message-ttl": 500,
                "x-dead-letter-exchange": "",
                "x-dead-letter-routing-key": queue,
            },
        )
        channel.queue_declare(queue + ".dead", durable=True)
        for exchange, patterns in bindings.items():
            for pattern in patterns:
                channel.queue_bind(queue, exchange, routing_key=pattern)


def publish(channel, exchange, topic, body, headers=None):
    channel.basic_publish(
        exchange,
        routing_key=topic,
        body=body,
        properties=pika.BasicProperties(
            content_type="application/json", delivery_mode=2, headers=headers,
        ),
        mandatory=True,
    )


def drain_outbox(channel, role):
    with transaction() as db:
        rows = db.execute(
            "SELECT id, body FROM outbox WHERE published = 0 ORDER BY rowid LIMIT 10"
        ).fetchall()
    for row in rows:
        message = json.loads(row["body"])
        topic = message["event"]
        exchange = COMMANDS if topic in COMMAND_TOPICS else EVENTS
        publish(channel, exchange, topic, row["body"])
        # Once confirmed, update local state. A crash in between can publish the same ID again.
        with transaction() as db:
            db.execute("UPDATE outbox SET published = 1 WHERE id = ?", (row["id"],))
        log(role, "published", message)


def saga(db, message):
    order_id = message["order_id"]
    topic = message["event"]
    if topic == "order.placed":
        set_status(db, order_id, "fulfillment_pending")
        emit(db, "fulfillment.requested", order_id, fail=message["fail"])
    elif topic == "fulfillment.rejected":
        set_status(db, order_id, "compensating")
        emit(db, "fulfillment.release_requested", order_id)
    elif topic == "fulfillment.released":
        set_status(db, order_id, "compensated")
        emit(db, "saga.compensated", order_id)
    elif topic == "fulfillment.completed":
        set_status(db, order_id, "completed")
        emit(db, "saga.completed", order_id)
    else:
        raise ValueError(f"Evento inesperado: {topic}")


def fulfillment(db, message):
    order_id = message["order_id"]
    topic = message["event"]
    if topic == "fulfillment.release_requested":
        set_status(db, order_id, "released")
        emit(db, "fulfillment.released", order_id)
    elif topic == "fulfillment.requested":
        if message["fail"]:
            set_status(db, order_id, "reserved")
            emit(db, "fulfillment.rejected", order_id)
        else:
            set_status(db, order_id, "fulfilled")
            emit(db, "fulfillment.completed", order_id)
    else:
        raise ValueError(f"Comando inesperado: {topic}")


def projection(db, message):
    status = {"saga.completed": "completed", "saga.compensated": "compensated"}[message["event"]]
    db.execute(
        """
        INSERT INTO projection(order_id, status, effect_count) VALUES (?, ?, 1)
        ON CONFLICT(order_id) DO UPDATE
        SET status = excluded.status, effect_count = projection.effect_count + 1
        """,
        (message["order_id"], status),
    )


HANDLERS = {"saga": saga, "fulfillment": fulfillment, "projection": projection}


def apply_effect(role, message):
    with transaction() as db:
        inserted = db.execute(
            "INSERT INTO inbox VALUES (?) ON CONFLICT(id) DO NOTHING", (message["id"],)
        ).rowcount
        if inserted:
            HANDLERS[role](db, message)
    return bool(inserted)


def log(role, action, message, **details):
    print(json.dumps({**message, "role": role, "action": action, **details}), flush=True)


def receive(channel, role, queue, delivery, properties, body):
    headers = properties.headers or {}
    attempt = headers.get("attempt", 0)
    message = {}
    try:
        if type(attempt) is not int or attempt < 0:
            attempt = 0
            raise ValueError("Contador de intentos inválido")
        parsed = json.loads(body)
        if not isinstance(parsed, dict) or any(
            not isinstance(parsed.get(key), str) for key in ("id", "event", "order_id")
        ):
            raise ValueError("Mensaje sin identificador, evento o pedido válido")
        message = parsed
        if message["event"] in ("order.placed", "fulfillment.requested") and not isinstance(
            message.get("fail"), bool
        ):
            raise ValueError("Indicador de fallo inválido")
        if (
            role == "fulfillment"
            and message["event"] == "fulfillment.requested"
            and message["order_id"] == os.getenv("LAB_RETRY_ONCE")
            and attempt == 0
        ):
            raise sqlite3.OperationalError("Fallo transitorio simulado")
        applied = apply_effect(role, message)
    except (ValueError, KeyError, TypeError, sqlite3.Error) as exc:
        retry = isinstance(exc, sqlite3.OperationalError) and attempt + 1 < MAX_ATTEMPTS
        destination = queue + (".retry" if retry else ".dead")
        publish(channel, "", destination, body, {"attempt": attempt + 1})
        log(role, "retry" if retry else "dead", message, attempt=attempt + 1, error=str(exc))
    else:
        if (
            applied
            and role == "fulfillment"
            and message["event"] == "fulfillment.requested"
            and message["order_id"] == os.getenv("LAB_REDELIVER_ONCE")
        ):
            log(role, "disconnect_before_ack", message)
            channel.close()
            return
        log(role, "applied" if applied else "duplicate", message, redelivered=delivery.redelivered)
    channel.basic_ack(delivery.delivery_tag)


def run_session(role):
    url = os.getenv("AMQP_URL", "amqp://guest:guest@rabbitmq:5672/%2F")
    with pika.BlockingConnection(pika.URLParameters(url)) as connection:
        channel = connection.channel()
        declare_topology(channel)
        channel.confirm_delivery()
        queue = f"lab.{role}"
        while channel.is_open:
            drain_outbox(channel, role)
            if role != "publisher":
                delivery, properties, body = channel.basic_get(queue, auto_ack=False)
                if delivery:
                    receive(channel, role, queue, delivery, properties, body)
                    continue
            connection.process_data_events(time_limit=0.2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("role", choices=("publisher", *HANDLERS))
    options = parser.parse_args()
    initialize()
    if options.role == "projection":
        http = ThreadingHTTPServer(("0.0.0.0", 8080), Projection)
        threading.Thread(target=http.serve_forever, daemon=True).start()
    while True:
        try:
            run_session(options.role)
        except (pika.exceptions.AMQPError, OSError, sqlite3.OperationalError) as exc:
            log(options.role, "reconnect", {}, error=str(exc))
            time.sleep(1)


if __name__ == "__main__":
    main()
