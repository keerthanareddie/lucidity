"""
Production-grade Hello World microservice.
Exposes /health, /ready, /metrics and GET / returning Hello World.
"""
import os
import time
import logging
from fastapi import FastAPI, Response
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
)
logger = logging.getLogger(__name__)

# ── OpenTelemetry Tracing ─────────────────────────────────────────────────────
OTLP_ENDPOINT = os.getenv("OTLP_ENDPOINT", "http://tempo-distributor:4317")
provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

# ── Prometheus Metrics ────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "hello_world_requests_total",
    "Total number of requests",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "hello_world_request_duration_seconds",
    "Request latency in seconds",
    ["endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
)

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Hello World Service",
    version=os.getenv("APP_VERSION", "1.0.0"),
    docs_url="/docs",
)
FastAPIInstrumentor.instrument_app(app)

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
ENV         = os.getenv("ENV", "production")
START_TIME  = time.time()


@app.get("/")
async def hello_world():
    with tracer.start_as_current_span("hello-world-handler"):
        start = time.time()
        logger.info("GET / called")
        response = {
            "message": "Hello World",
            "version": APP_VERSION,
            "env": ENV,
        }
        REQUEST_COUNT.labels(method="GET", endpoint="/", status_code=200).inc()
        REQUEST_LATENCY.labels(endpoint="/").observe(time.time() - start)
        return response


@app.get("/health")
async def health():
    """Liveness probe — is the process alive?"""
    return {"status": "ok", "uptime_seconds": round(time.time() - START_TIME, 2)}


@app.get("/ready")
async def ready():
    """Readiness probe — is the app ready to serve traffic?"""
    return {"status": "ready"}


@app.get("/metrics")
async def metrics():
    """Prometheus scrape endpoint."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
