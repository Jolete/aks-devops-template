#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
export EXAMPLE_PORT=0 EXAMPLE_PROJECTION_PORT=0
export LAB_RETRY_ONCE=order-retry LAB_REDELIVER_ONCE=order-redelivery
project="outbox-smoke-$$-$RANDOM"
compose=(docker compose -p "$project")

cleanup() {
  local status=$?
  if (( status != 0 )); then
    "${compose[@]}" logs || true
  fi
  "${compose[@]}" down --volumes --rmi local || true
}
trap cleanup EXIT

"${compose[@]}" up -d --build --wait --wait-timeout 120
api_url="http://$("${compose[@]}" port api 8080)"
projection_url="http://$("${compose[@]}" port projection 8080)"

curl -fsS --max-time 5 -X PUT "$api_url/orders/order-success"
curl -fsS --max-time 5 -X PUT "$api_url/orders/order-success"
curl -fsS --max-time 5 -X PUT "$api_url/orders/order-compensation?fail=true"
curl -fsS --max-time 5 -X PUT "$api_url/orders/$LAB_RETRY_ONCE"
curl -fsS --max-time 5 -X PUT "$api_url/orders/$LAB_REDELIVER_ONCE"

python3 -E - "$api_url" "$projection_url" "$project" <<'PY'
import json
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import urlopen

api, projection, project = sys.argv[1:]
expected = {
    "order-success": "completed",
    "order-compensation": "compensated",
    "order-retry": "completed",
    "order-redelivery": "completed",
}


def read(base_url, order_id):
    try:
        with urlopen(f"{base_url}/orders/{order_id}", timeout=5) as response:
            return json.load(response)
    except HTTPError as error:
        if error.code != 404:
            raise
        return {}


deadline = time.monotonic() + 45
for order_id, status in expected.items():
    while True:
        projected = read(projection, order_id)
        accepted = read(api, order_id)
        if projected.get("status") == status and accepted.get("outbox_pending") is False:
            assert projected["order_id"] == order_id, projected
            assert projected["effect_count"] == 1, projected
            print(json.dumps(projected))
            break
        if time.monotonic() >= deadline:
            raise AssertionError((order_id, status, projected, accepted))
        time.sleep(0.25)

expected_actions = {
    ("order-retry", "retry"),
    ("order-retry", "applied"),
    ("order-redelivery", "disconnect_before_ack"),
    ("order-redelivery", "duplicate"),
}
while True:
    logs = subprocess.check_output(
        ["docker", "compose", "-p", project, "logs", "--no-color", "--no-log-prefix", "fulfillment"],
        text=True,
        timeout=5,
    )
    entries = [json.loads(line) for line in logs.splitlines() if line.startswith("{")]
    actions = {
        (entry["order_id"], entry["action"]): entry
        for entry in entries
        if entry.get("event") == "fulfillment.requested"
    }
    if expected_actions <= actions.keys():
        retry = actions["order-retry", "retry"]
        applied = actions["order-retry", "applied"]
        disconnected = actions["order-redelivery", "disconnect_before_ack"]
        duplicate = actions["order-redelivery", "duplicate"]
        assert retry["id"] == applied["id"], (retry, applied)
        assert disconnected["id"] == duplicate["id"] and duplicate["redelivered"] is True, duplicate
        for entry in (retry, applied, disconnected, duplicate):
            print(json.dumps(entry))
        break
    if time.monotonic() >= deadline:
        raise AssertionError(("missing fulfillment actions", expected_actions - actions.keys()))
    time.sleep(0.25)
PY

"${compose[@]}" exec -T fulfillment python - <<'PY'
import os
import time

import pika

malformed = b"{invalid JSON"
with pika.BlockingConnection(pika.URLParameters(os.environ["AMQP_URL"])) as connection:
    channel = connection.channel()
    channel.confirm_delivery()
    channel.basic_publish("", "lab.fulfillment", malformed, mandatory=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        delivery, _, body = channel.basic_get("lab.fulfillment.dead")
        if delivery:
            assert body == malformed, body
            channel.basic_ack(delivery.delivery_tag)
            print("Malformed message reached lab.fulfillment.dead")
            break
        connection.sleep(0.25)
    else:
        raise AssertionError("Malformed message missing from lab.fulfillment.dead")
PY
