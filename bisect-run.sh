#!/usr/bin/env bash
# Called by `git bisect run` — builds current keycloak checkout, runs repro, reports good/bad.
# Exit 0 = good, exit 1 = bad, exit 125 = skip (build failure).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC_REPO="$SCRIPT_DIR/vendor/keycloak"
COMMIT=$(git -C "$KC_REPO" rev-parse --short HEAD)
IMAGE_TAG="keycloak-local:${COMMIT}"

# --- Build image if not already built ---
if ! docker image inspect "$IMAGE_TAG" &>/dev/null; then
  echo "==> Building $IMAGE_TAG..."
  if ! (cd "$KC_REPO" && ./mvnw -pl quarkus/deployment,quarkus/dist -am \
      -DskipTests -DskipProtoLock=true clean install -q); then
    echo "==> Build failed, skipping this commit."
    exit 125
  fi
  DIST_TAR=$(ls "$KC_REPO/quarkus/dist/target/keycloak-"*.tar.gz | head -1)
  DIST_BASENAME=$(basename "$DIST_TAR")
  cp "$DIST_TAR" "$KC_REPO/quarkus/container/"
  if ! docker build --build-arg "KEYCLOAK_DIST=${DIST_BASENAME}" \
      -t "$IMAGE_TAG" "$KC_REPO/quarkus/container"; then
    echo "==> Docker build failed, skipping."
    exit 125
  fi
fi

# --- Run repro ---
echo "==> Running repro for $IMAGE_TAG..."
RUN_OUTPUT=$(mktemp)
KC_IMAGE="$IMAGE_TAG" bash "$SCRIPT_DIR/repro-40689.sh" 2>&1 | tee "$RUN_OUTPUT"

# --- Parse failure rate ---
FAILURE_RATE=$(grep "percentage of failed events" "$RUN_OUTPUT" | tail -1 | grep -oE 'actual : [0-9.]+' | grep -oE '[0-9.]+' || echo "0")

# --- Append to CSV ---
if echo "$FAILURE_RATE" | awk '{exit ($1 > 0) ? 0 : 1}'; then
  RESULT="bad"
  EXIT=1
else
  RESULT="good"
  EXIT=0
fi

echo "${COMMIT},commit,${FAILURE_RATE},${RESULT}," >> "$SCRIPT_DIR/bisect-40689.csv"
echo "==> $COMMIT: $RESULT (failure_rate=${FAILURE_RATE}%)"
rm -f "$RUN_OUTPUT"
exit $EXIT
