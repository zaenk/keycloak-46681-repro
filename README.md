# Repro: keycloak/keycloak#46681

Reproduces https://github.com/keycloak/keycloak/issues/46681 — with brute force
protection and permanent lockout enabled on a realm, parallel cold-cache requests to
`GET /admin/realms/{realm}/users` can return users with `enabled=false` even though
all users are enabled.

## Prerequisites

- Docker + Docker Compose
- Java 17+
- Maven 3.x
- `jq`

## Run

```bash
./repro-46681.sh
```

The script will:
1. Pull and start Keycloak + Postgres via Docker Compose
2. Clone and build [keycloak-benchmark](https://github.com/keycloak/keycloak-benchmark) (first run only)
3. Create `test-realm` with brute force protection + permanent lockout enabled
4. Seed 1000 users
5. Run the `UserCrawlEnabledCheck` Gatling scenario with 5 concurrent users against a cold cache
6. Report whether any user was returned with `enabled=false`

To test a specific Keycloak version:

```bash
KC_IMAGE=quay.io/keycloak/keycloak:26.0.0 ./repro-46681.sh
```

## How it works

`scenarios/UserCrawlEnabledCheck.scala` fetches pages of users with
`briefRepresentation=false` and asserts that every user in every response has
`enabled=true`. Any user returned with `enabled=false` marks the request as a failure.
