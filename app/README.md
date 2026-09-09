# SRE Demo API

FastAPI application for SRE observability testing.

## Endpoints

| Endpoint | Purpose |
|---|---|
| GET /api/health | Liveness probe |
| GET /api/ready | Readiness probe |
| GET /api/products | Normal business endpoint |
| GET /api/orders | Normal business endpoint |
| GET /api/users | Normal business endpoint |
| GET /api/slow | Simulates latency (2–5s) |
| GET /api/error | Simulates 4xx/5xx/exceptions |

## Local dev

```bash
docker compose up
```

## Tests

```bash
python -m pytest tests/ -v
```