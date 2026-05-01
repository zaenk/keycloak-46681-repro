#!/usr/bin/env bash
# Build a custom Keycloak image from a specific commit.
# Usage: ./build-kc-commit.sh <commit-hash>
set -euo pipefail

COMMIT="${1:?Usage: $0 <commit-hash>}"
SHORT="${COMMIT:0:7}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC_REPO="$SCRIPT_DIR/vendor/keycloak"
IMAGE_TAG="keycloak-local:${SHORT}"

# --- Ensure repo ---
if [[ ! -d "$KC_REPO/.git" ]]; then
  echo "==> Shallow-cloning keycloak into vendor/keycloak..."
  mkdir -p "$SCRIPT_DIR/vendor"
  git clone --filter=blob:none --no-checkout https://github.com/keycloak/keycloak.git "$KC_REPO"
fi

echo "==> Checking out ${SHORT}..."
# Tags can be fetched directly; arbitrary commits require fetching the containing branch
if ! git -C "$KC_REPO" fetch --filter=blob:none origin "$COMMIT" 2>/dev/null; then
  echo "==> Direct fetch failed, fetching main branch to reach commit..."
  git -C "$KC_REPO" fetch --filter=blob:none origin main
fi
git -C "$KC_REPO" checkout "$COMMIT"

echo "==> Building Keycloak (skipping tests)..."
(cd "$KC_REPO" && ./mvnw -pl quarkus/deployment,quarkus/dist -am \
  -DskipTests -DskipProtoLock=true clean install -q)

echo "==> Building Docker image ${IMAGE_TAG}..."
DIST_TAR=$(ls "$KC_REPO/quarkus/dist/target/keycloak-"*.tar.gz | head -1)
DIST_BASENAME=$(basename "$DIST_TAR")
cp "$DIST_TAR" "$KC_REPO/quarkus/container/"
docker build \
  --build-arg "KEYCLOAK_DIST=${DIST_BASENAME}" \
  -t "$IMAGE_TAG" \
  "$KC_REPO/quarkus/container"

echo "==> Done: ${IMAGE_TAG}"
