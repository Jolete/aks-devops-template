#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
commit=$(git rev-parse --verify HEAD)
if [[ -n "${GITHUB_ACTIONS:-}" && "$commit" != "${GITHUB_SHA:-}" ]]; then
  echo "The checked-out commit does not match the dispatched commit." >&2
  exit 1
fi

cluster=devops-cd
context=k3d-devops-cd
namespace=devops-lab
image="devops-demo:$commit"
workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT

k3d kubeconfig get "$cluster" > "$workdir/kubeconfig"
kube=(kubectl --kubeconfig "$workdir/kubeconfig" --context "$context" --namespace "$namespace")
"${kube[@]}" get --raw=/readyz >/dev/null

cp k8s/00-namespace.yaml k8s/demo.yaml "$workdir/"
cat > "$workdir/kustomization.yaml" <<KUSTOMIZATION
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - 00-namespace.yaml
  - demo.yaml
images:
  - name: devops-demo
    newTag: "$commit"
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: demo
        namespace: devops-lab
      spec:
        template:
          spec:
            containers:
              - name: demo
                env:
                  - name: APP_VERSION
                    value: "$commit"
KUSTOMIZATION

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build --tag "$image" .
fi
k3d image import "$image" --cluster "$cluster"

check_release() (
  local expected_version=$1
  local port='' forward_pid attempt
  "${kube[@]}" port-forward --address 127.0.0.1 service/demo :8080 > "$workdir/port-forward.log" 2>&1 &
  forward_pid=$!
  trap 'kill "$forward_pid" 2>/dev/null || true; wait "$forward_pid" 2>/dev/null || true' EXIT
  for ((attempt = 0; attempt < 10; attempt++)); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) -> 8080$/\1/p' "$workdir/port-forward.log")
    [[ -n "$port" ]] && break
    kill -0 "$forward_pid" 2>/dev/null || break
    sleep 1
  done
  if [[ -z "$port" ]]; then
    cat "$workdir/port-forward.log" >&2
    return 1
  fi
  ./scripts/smoke.sh "http://127.0.0.1:$port" "$expected_version"
)

previous_revision=$("${kube[@]}" get deployment/demo --ignore-not-found \
  -o 'jsonpath={.metadata.annotations.deployment\.kubernetes\.io/revision}')
previous_version=$("${kube[@]}" get deployment/demo --ignore-not-found \
  -o 'jsonpath={.spec.template.spec.containers[?(@.name=="demo")].env[?(@.name=="APP_VERSION")].value}')

if "${kube[@]}" apply -k "$workdir" &&
  "${kube[@]}" rollout status deployment/demo --timeout=120s &&
  check_release "$commit"; then
  exit 0
fi

echo "Deployment failed for $commit." >&2
"${kube[@]}" get pods -l app=demo >&2 || true
"${kube[@]}" get events --sort-by=.lastTimestamp >&2 || true

if [[ -n "$previous_revision" ]]; then
  echo "Restoring revision $previous_revision." >&2
  if "${kube[@]}" rollout undo deployment/demo --to-revision="$previous_revision" &&
    "${kube[@]}" rollout status deployment/demo --timeout=120s &&
    check_release "${previous_version:-local}"; then
    echo "Previous release restored and verified." >&2
  else
    echo "Rollback could not be verified." >&2
  fi
else
  echo "No previous revision is available for rollback." >&2
fi
exit 1
