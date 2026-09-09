import asyncio
import random
import time
import uuid

# Patch ddtrace BEFORE importing FastAPI - enables automatic instrumentation
from ddtrace import patch, tracer
patch(fastapi=True)

import structlog
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

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


@app.middleware("http")
async def request_middleware(request: Request, call_next):
    request_id = str(uuid.uuid4())
    start = time.time()
    request.state.request_id = request_id

    response = await call_next(request)

    duration_ms = round((time.time() - start) * 1000, 2)

    # Get current trace context for log correlation
    span = tracer.current_span()
    if span:
        trace_id = span.trace_id & 0xFFFFFFFFFFFFFFFF  # Convert to 64-bit
        span_id = span.span_id
    else:
        trace_id = None
        span_id = None
    trace_id = span.trace_id if span else None
    span_id = span.span_id if span else None

    log.info(
        "request",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        duration_ms=duration_ms,
        request_id=request_id,
        **{"dd.trace_id": str(trace_id) if trace_id else None},
        **{"dd.span_id": str(span_id) if span_id else None},
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