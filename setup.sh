#!/usr/bin/env bash
# Realm + user + client setup against a running Keycloak instance.
# Assumes Keycloak is already up at http://localhost:8080.
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"

wait_keycloak() {
  echo "==> Waiting for Keycloak to be ready..."
  until curl -s "$KC_URL/realms/master" 2>/dev/null | grep -q "master"; do
    echo "   not ready yet, sleeping 5s..."
    sleep 5
  done
  echo "   Keycloak is ready."
}

wait_dataset() {
  echo "==> Waiting for dataset provider..."
  until curl -sf "$KC_URL/realms/master/dataset/status" > /dev/null 2>&1; do
    echo "   dataset provider not loaded yet, sleeping 5s..."
    sleep 5
  done
  echo "   Dataset provider loaded."
}

admin_token() {
  local token
  until token=$(curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&username=admin&password=admin&grant_type=password" \
    | jq -r .access_token) && [[ -n "$token" && "$token" != "null" ]]; do
    echo "   waiting for admin token..."
    sleep 3
  done
  echo "$token"
}

echo "==> Waiting for stack..."
wait_keycloak

echo "==> Disabling SSL requirement on master realm..."
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin
docker exec keycloak /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=none

wait_dataset

echo "==> Creating test-realm..."
TOKEN=$(admin_token)
curl -sf -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm": "test-realm", "enabled": true, "sslRequired": "none"}' || echo "   (realm may already exist, continuing)"

echo "==> Seeding 1000 users..."
curl -sf "$KC_URL/realms/master/dataset/create-users?count=1000&realm-name=test-realm" > /dev/null
until curl -sf "$KC_URL/realms/master/dataset/status" | grep -q "No task in progress"; do
  echo "   still seeding..."
  sleep 3
done
echo "   Seeding complete."

echo "==> Setting up gatling client..."
TOKEN=$(admin_token)
curl -sf -X POST "$KC_URL/admin/realms/test-realm/clients" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "gatling",
    "enabled": true,
    "serviceAccountsEnabled": true,
    "publicClient": false,
    "secret": "gatling-secret",
    "redirectUris": ["http://localhost"]
  }' || echo "   (client may already exist, continuing)"

CLIENT_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/test-realm/clients?clientId=gatling" \
  | jq -r '.[0].id')
SA_USER_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/test-realm/clients/$CLIENT_ID/service-account-user" \
  | jq -r '.id')
RM_CLIENT_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/test-realm/clients?clientId=realm-management" \
  | jq -r '.[0].id')
VIEW_USERS_ROLE=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/test-realm/clients/$RM_CLIENT_ID/roles/view-users" \
  | jq '[{id: .id, name: .name}]')
curl -sf -X POST \
  "$KC_URL/admin/realms/test-realm/users/$SA_USER_ID/role-mappings/clients/$RM_CLIENT_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$VIEW_USERS_ROLE" || true
echo "   gatling client ready."

echo "==> Setup complete."
