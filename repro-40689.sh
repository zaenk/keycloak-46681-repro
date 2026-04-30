#!/usr/bin/env bash
# Repro script for https://github.com/keycloak/keycloak/issues/40689
#
# With brute force protection + permanent lockout enabled on a realm,
# parallel GET /admin/realms/{realm}/users requests on a cold cache can return
# users with enabled=false even though all users are enabled.
#
# Usage:
#   ./repro-40689.sh
#   KC_IMAGE=quay.io/keycloak/keycloak:26.0.0 ./repro-40689.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/keycloak-benchmark"
KCB_REPO_URL="https://github.com/keycloak/keycloak-benchmark.git"
FAT_JAR="$VENDOR_DIR/benchmark/target/dist/keycloak-benchmark-999.0.0-SNAPSHOT/lib/keycloak-benchmark-999.0.0-SNAPSHOT.jar"
GATLING_RESULTS_DIR="$SCRIPT_DIR/results"
KC_URL="${KC_URL:-http://localhost:8080}"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

KC_IMAGE="${KC_IMAGE:-quay.io/keycloak/keycloak:26.6.1}"
KC_CPUS="${KC_CPUS:-4.0}"

# --- Step 1: Ensure vendor repo and inject scenarios ---
ensure_vendor_repo() {
  if [[ ! -d "$VENDOR_DIR/.git" ]]; then
    echo "==> Cloning keycloak-benchmark into vendor/..."
    mkdir -p "$SCRIPT_DIR/vendor"
    git clone --depth=1 "$KCB_REPO_URL" "$VENDOR_DIR"
  fi

  local target_dir="$VENDOR_DIR/benchmark/src/main/scala/keycloak/scenario/admin"
  local changed=false
  for src in "$SCENARIOS_DIR"/*.scala; do
    [[ -f "$src" ]] || continue
    local dest="$target_dir/$(basename "$src")"
    if ! diff -q "$src" "$dest" &>/dev/null 2>&1; then
      echo "==> Injecting custom scenario: $(basename "$src")"
      cp "$src" "$dest"
      changed=true
    fi
  done
  if $changed && [[ -f "$FAT_JAR" ]]; then
    echo "==> Custom scenario changed — removing stale JAR to trigger rebuild."
    rm -f "$FAT_JAR"
  fi
}

# --- Step 2: Build JAR if missing ---
ensure_jar() {
  if [[ -f "$FAT_JAR" ]]; then
    echo "==> Fat JAR already built, skipping Maven build."
    return
  fi
  echo "==> Building keycloak-benchmark..."
  mvn -f "$VENDOR_DIR/pom.xml" install -DskipTests -q \
    -Dmaven.compiler.source=17 -Dmaven.compiler.target=17 \
    -pl dataset,benchmark -am
  cp "$VENDOR_DIR/dataset/target/keycloak-benchmark-dataset-"*.jar "$SCRIPT_DIR/providers/"
  unzip -qo "$VENDOR_DIR/benchmark/target/keycloak-benchmark-999.0.0-SNAPSHOT.zip" \
    -d "$VENDOR_DIR/benchmark/target/dist"
  echo "==> Build complete."
}

# --- Step 3: Stack lifecycle ---
start_stack() {
  echo "==> Starting stack (image=$KC_IMAGE, cpus=$KC_CPUS)..."
  KC_IMAGE="$KC_IMAGE" KC_CPUS="$KC_CPUS" \
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
}

stop_stack() {
  echo "==> Tearing down stack..."
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
}

# --- Step 4: Admin token helper ---
admin_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&username=admin&password=admin&grant_type=password" \
    | jq -r .access_token
}

# --- Step 5: Enable brute force protection with permanent lockout ---
configure_brute_force() {
  echo "==> Configuring brute force protection with permanent lockout on test-realm..."
  local TOKEN
  TOKEN=$(admin_token)
  curl -sf -X PUT "$KC_URL/admin/realms/test-realm" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "bruteForceProtected": true,
      "permanentLockout": true,
      "maxFailureWaitSeconds": 900,
      "minimumQuickLoginWaitSeconds": 60,
      "waitIncrementSeconds": 60,
      "quickLoginCheckMilliSeconds": 1000,
      "maxDeltaTimeSeconds": 43200,
      "failureFactor": 3
    }'
  echo "   Brute force protection configured."
}

# --- Step 6: Run the Gatling scenario ---
run_repro() {
  local run_dir
  run_dir=$(mktemp -d "$GATLING_RESULTS_DIR/repro-40689-XXXXXX")
  echo "==> Running UserCrawlEnabledCheck (5 concurrent users, cold cache)..."
  java -Xmx1G \
    -Drealm-name=test-realm \
    -Dclient-secret=gatling-secret \
    -Dusers-per-realm=1000 \
    -Duser-page-size=100 \
    -Duser-number-of-pages=10 \
    -Dconcurrent-users=5 \
    -Dmeasurement=30 \
    -cp "$FAT_JAR" \
    io.gatling.app.Gatling \
    -s keycloak.scenario.admin.UserCrawlEnabledCheck \
    -rf "$run_dir" \
    2>&1 | tee "$run_dir/stdout.log"
  echo "$run_dir"
}

mkdir -p "$GATLING_RESULTS_DIR"

ensure_vendor_repo
ensure_jar

echo ""
echo "============================================================"
echo "  Repro: KC Issue #40689 — enabled=false under brute force"
echo "  Image: $KC_IMAGE"
echo "============================================================"

stop_stack
start_stack
KC_URL="$KC_URL" bash "$SCRIPT_DIR/setup.sh"
configure_brute_force

echo ""
echo "==> Cold cache run (cache NOT pre-warmed — this is intentional)..."
run_dir=$(run_repro)

echo ""
if grep -q "enabled=false" "$run_dir/stdout.log" 2>/dev/null || grep -q "KO=" "$run_dir/stdout.log" && ! grep -q "KO=0" "$run_dir/stdout.log"; then
  echo "============================================================"
  echo "  REPRODUCED: users with enabled=false detected"
  echo "  Results: $run_dir"
  echo "============================================================"
else
  echo "============================================================"
  echo "  NOT reproduced on this run (may need more users or concurrency)"
  echo "  Results: $run_dir"
  echo "============================================================"
fi
