import asyncio
import random
import time
import uuid

import structlog
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, make_asgi_app, REGISTRY

# Structured logging
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)
log = structlog.get_logger()

app = FastAPI(title="SRE Demo API", version="1.0.0")

SERVICE_VERSION = "1.0.0"
SERVICE_ENV = "dev"

# ── Prometheus metrics ──────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)
ERROR_COUNT = Counter(
    "http_errors_total",
    "Total HTTP error responses (4xx + 5xx)",
    ["endpoint", "status_code"],
)

# Mount /metrics endpoint
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)
# ────────────────────────────────────────────────────────────────────


@app.middleware("http")
async def request_middleware(request: Request, call_next):
    request_id = str(uuid.uuid4())
    start = time.time()
    request.state.request_id = request_id

    response = await call_next(request)

    duration = time.time() - start
    duration_ms = round(duration * 1000, 2)
    path = request.url.path

    # Skip recording metrics for /metrics itself
    if path != "/metrics":
        REQUEST_COUNT.labels(request.method, path, response.status_code).inc()
        REQUEST_LATENCY.labels(path).observe(duration)
        if response.status_code >= 400:
            ERROR_COUNT.labels(path, response.status_code).inc()

    log.info(
        "request",
        method=request.method,
        path=path,
        status=response.status_code,
        duration_ms=duration_ms,
        request_id=request_id,
    )
    response.headers["X-Request-ID"] = request_id
    return response


@app.get("/api/health")
async def health():
    return {"status": "healthy", "version": SERVICE_VERSION, "env": SERVICE_ENV}


@app.get("/api/ready")
async def ready():
    return {"status": "ready"}


@app.get("/api/products")
async def products():
    return {
        "products": [
            {"id": 1, "name": "Widget A", "price": 9.99},
            {"id": 2, "name": "Widget B", "price": 19.99},
            {"id": 3, "name": "Widget C", "price": 4.99},
            {"id": 4, "name": "Widget D", "price": 7.99},
        ]
    }


@app.get("/api/orders")
async def orders():
    return {
        "orders": [
            {"id": 101, "product_id": 1, "status": "shipped"},
            {"id": 102, "product_id": 3, "status": "pending"},
            {"id": 103, "product_id": 4, "status": "shipped"},
        ]
    }


@app.get("/api/users")
async def users():
    return {
        "users": [
            {"id": 1, "name": "Ana"},
            {"id": 2, "name": "Bob"},
            {"id": 3, "name": "Machindra"},
        ]
    }


@app.get("/api/slow")
async def slow():
    delay = random.uniform(2.0, 5.0)
    await asyncio.sleep(delay)
    return {"message": "slow response", "delay_ms": round(delay * 1000)}


@app.get("/api/error")
async def error():
    error_type = random.choice(["client", "server", "server"])
    if error_type == "client":
        return JSONResponse(status_code=400, content={"error": "bad request", "type": "client"})
    else:
        return JSONResponse(status_code=500, content={"error": "internal server error", "type": "server"})

@app.exception_handler(Exception)
async def unhandled_exception(request: Request, exc: Exception):
    log.error("unhandled_exception", path=request.url.path, error=str(exc))
    return JSONResponse(status_code=500, content={"error": "unexpected error", "detail": str(exc)})


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)