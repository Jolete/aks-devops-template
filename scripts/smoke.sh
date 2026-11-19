#!/usr/bin/env bash
set -euo pipefail

base_url="${1:-http://127.0.0.1:8080}"
expected_version="${2:-}"

health=$(curl --fail --silent --show-error --max-time 5 "$base_url/healthz")
service=$(curl --fail --silent --show-error --max-time 5 "$base_url/")
completed=$(curl --fail --silent --show-error --max-time 5 -X POST "$base_url/sagas")
compensated=$(curl --fail --silent --show-error --max-time 5 -X POST "$base_url/sagas?fail=true")

python3 - "$expected_version" "$health" "$service" "$completed" "$compensated" <<'PY'
import json
import sys
from uuid import UUID

expected_version = sys.argv[1]
health, service, completed, compensated = map(json.loads, sys.argv[2:])
assert health == {"status": "ok"}, health
assert service["service"] == "devops-demo", service
if expected_version:
    assert service["version"] == expected_version, (expected_version, service)
assert completed["status"] == "completed", completed
assert completed["reservation_active"] is True, completed
assert compensated["status"] == "compensated", compensated
assert compensated["reservation_active"] is False, compensated
assert UUID(completed["saga_id"]) != UUID(compensated["saga_id"])
print(f"Servicio operativo. Versión {service['version']}")
print(json.dumps(completed))
print(json.dumps(compensated))
PY
