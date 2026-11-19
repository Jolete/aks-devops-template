"""Run a request-scoped saga with an observable compensation path."""

import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4


def log_event(saga_id, event):
    print(
        json.dumps(
            {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "saga_id": saga_id,
                "event": event,
            }
        ),
        flush=True,
    )


def run_saga(fail):
    saga_id = uuid4().hex
    reservation_active = True
    log_event(saga_id, "inventory_reserved")

    if fail:
        log_event(saga_id, "payment_rejected")
        reservation_active = False
        log_event(saga_id, "inventory_released")
        status = "compensated"
    else:
        log_event(saga_id, "payment_confirmed")
        status = "completed"

    return {
        "saga_id": saga_id,
        "status": status,
        "reservation_active": reservation_active,
    }


class Handler(BaseHTTPRequestHandler):
    def reply(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply({"status": "ok"})
        elif self.path == "/":
            self.reply({"service": "devops-demo", "version": os.getenv("APP_VERSION", "local")})
        else:
            self.reply({"error": "not found"}, 404)

    def do_POST(self):
        request = urlsplit(self.path)
        if request.path != "/sagas":
            self.reply({"error": "not found"}, 404)
            return

        fail = parse_qs(request.query, keep_blank_values=True).pop("fail", ["false"])
        if fail not in (["false"], ["true"]):
            self.reply({"error": "fail must be true or false"}, 400)
            return

        self.reply(run_saga(fail=fail == ["true"]))

    def log_message(self, _format, *_args):
        # Keep probe traffic and request details out of the saga event stream.
        pass


if __name__ == "__main__":
    with ThreadingHTTPServer(("0.0.0.0", 8080), Handler) as server:
        server.serve_forever()
