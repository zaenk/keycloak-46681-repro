# CLAUDE.md

## Goal

This repo reproduces and bisects https://github.com/keycloak/keycloak/issues/40689.

**The bug:** with brute force protection + permanent lockout enabled, parallel cold-cache
requests to `GET /admin/realms/{realm}/users` return users with `enabled=false` even
though all users are enabled and no login attempts have occurred.

**Root cause (bisected):** commit `828f9f7916` ("Mark user as disabled if reaching max
login failures and permanent lockout is enabled", Jun 2025) introduced the regression by
writing `enabled=false` onto the `UserModel` itself rather than keeping it in the brute
force cache. Under concurrent cold-cache rehydration this bleeds across requests.

**First bad commit:** `828f9f7916c8d32d1ea7b6bc48fe63468bfa9ab9`  
**Last good commit/tag:** `881c2114ea` / `26.2.x` series  
**First bad release:** `26.3.0`

## Key files

| File | Purpose |
|------|---------|
| `repro-40689.sh` | Main repro: starts stack, seeds data, runs Gatling test |
| `build-kc-commit.sh` | Builds a custom KC image from a commit or tag in `vendor/keycloak` |
| `bisect-run.sh` | `git bisect run` driver — builds, tests, appends to CSV, exits 0/1 |
| `bisect-40689.csv` | Log of all tested commits with failure rates and verdicts |
| `docker-compose.yml` | Keycloak + Postgres stack (`pull_policy: if_not_present`) |
| `scenarios/UserCrawlEnabledCheck.scala` | Gatling scenario asserting `enabled=true` on every user |
| `setup.sh` | Realm + user seeding via dataset provider |

## How to run

```bash
# Default (latest published image)
./repro-40689.sh

# Specific published tag
KC_IMAGE=quay.io/keycloak/keycloak:26.3.0 ./repro-40689.sh

# Custom build from commit or tag
./build-kc-commit.sh 828f9f7916
KC_IMAGE=keycloak-local:828f9f79 ./repro-40689.sh
```

## How to bisect

```bash
cd vendor/keycloak
git bisect start
git bisect bad <known-bad>
git bisect good <known-good>
git bisect run bash ../../bisect-run.sh
```

## Test verdict

A run is **good** if `failure_rate=0.0%` (no users returned with `enabled=false`).  
A run is **bad** if `failure_rate>0` — typically 12–14% under this test configuration.

## Environment

- `vendor/keycloak` — shallow clone of https://github.com/keycloak/keycloak (created by `build-kc-commit.sh`)
- `vendor/keycloak-benchmark` — shallow clone of keycloak-benchmark (created by `repro-40689.sh`)
- `providers/` — dataset provider JAR (built from keycloak-benchmark)
- `results/` — Gatling run output directories
