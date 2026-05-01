# Repro: keycloak/keycloak#40689

Reproduces https://github.com/keycloak/keycloak/issues/40689 — with brute force
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
./repro-40689.sh
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
KC_IMAGE=quay.io/keycloak/keycloak:26.0.0 ./repro-40689.sh
```

To test a custom build from a specific commit (tag or hash):

```bash
./build-kc-commit.sh <commit-or-tag>
KC_IMAGE=keycloak-local:<short-hash> ./repro-40689.sh
```

`build-kc-commit.sh` shallow-clones the keycloak repo into `vendor/keycloak` on first
run, checks out the given ref, builds the Quarkus distribution, and tags a local Docker
image as `keycloak-local:<7-char-hash>`.

## Bisect

`bisect-run.sh` is a `git bisect run` driver. It builds whatever commit is currently
checked out in `vendor/keycloak`, runs the repro, and exits 0 (good) or 1 (bad).
Results are appended to `bisect-40689.csv`.

```bash
cd vendor/keycloak
git bisect start
git bisect bad <known-bad-ref>
git bisect good <known-good-ref>
git bisect run bash ../../bisect-run.sh
```

`bisect-40689.csv` records every tested commit/tag with its failure rate and verdict.

## How it works

`scenarios/UserCrawlEnabledCheck.scala` fetches pages of users with
`briefRepresentation=false` and asserts that every user in every response has
`enabled=true`. Any user returned with `enabled=false` marks the request as a failure.
