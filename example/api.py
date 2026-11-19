import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from db import emit, initialize, transaction

ORDER_PATH = re.compile(r"/orders/([a-z0-9][a-z0-9-]{0,63})")


class OrderReader(BaseHTTPRequestHandler):
    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"status": "ok"})
            return
        match = ORDER_PATH.fullmatch(self.path)
        if match:
            with transaction() as db:
                order = self.order_state(db, match[1])
            if order:
                self.reply(200, order)
                return
        self.reply(404, {"error": "Recurso no encontrado"})


class Orders(OrderReader):
    def order_state(self, db, order_id):
        row = db.execute(
            "SELECT status FROM orders WHERE id = ?", (order_id,)
        ).fetchone()
        if row:
            pending = db.execute(
                """
                SELECT 1 FROM outbox
                WHERE published = 0 AND json_extract(body, '$.order_id') = ?
                """,
                (order_id,),
            ).fetchone()
            return {"order_id": order_id, "status": row["status"], "outbox_pending": bool(pending)}
        return None

    def do_PUT(self):
        request = urlsplit(self.path)
        match = ORDER_PATH.fullmatch(request.path)
        if match is None:
            self.reply(404, {"error": "Recurso no encontrado"})
            return
        fail = parse_qs(request.query, keep_blank_values=True).get("fail", ["false"])
        if fail not in (["true"], ["false"]):
            self.reply(400, {"error": "fail debe ser true o false"})
            return
        order_id = match[1]
        with transaction() as db:
            created = db.execute(
                "INSERT INTO orders VALUES (?, 'accepted') ON CONFLICT(id) DO NOTHING",
                (order_id,),
            ).rowcount
            if created:
                emit(db, "order.placed", order_id, fail=fail == ["true"])
            state = self.order_state(db, order_id)
        self.reply(201 if created else 200, state)


class Projection(OrderReader):
    def order_state(self, db, order_id):
        row = db.execute("SELECT * FROM projection WHERE order_id = ?", (order_id,)).fetchone()
        if row:
            return dict(row)
        return None


if __name__ == "__main__":
    initialize()
    with ThreadingHTTPServer(("0.0.0.0", 8080), Orders) as server:
        server.serve_forever()
