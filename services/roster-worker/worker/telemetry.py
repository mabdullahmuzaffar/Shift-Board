"""Structured logging and OpenTelemetry wiring.

Logs are JSON on stdout so Container Insights / Log Analytics can index the
fields without regex parsing. Traces go to an OpenTelemetry Collector running
as a DaemonSet, which fans out to Azure Monitor and to Tempo if present.
"""

import logging
import sys

import structlog

_configured = False


def configure_logging(service_name: str, environment: str, level: str = "INFO") -> None:
    global _configured
    if _configured:
        return

    logging.basicConfig(format="%(message)s", stream=sys.stdout, level=level.upper())

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            logging.getLevelName(level.upper())
        ),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
    structlog.contextvars.bind_contextvars(service=service_name, env=environment)
    _configured = True


def get_logger(name: str = "roster-worker"):
    return structlog.get_logger(name)


def configure_tracing(engine, settings) -> None:
    """Best-effort tracing for the worker. SQLAlchemy spans only."""
    if not settings.otlp_endpoint:
        return
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
            OTLPSpanExporter,
        )
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        resource = Resource.create(
            {
                "service.name": settings.service_name,
                "deployment.environment": settings.environment,
            }
        )
        provider = TracerProvider(resource=resource)
        provider.add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter(endpoint=settings.otlp_endpoint, insecure=True))
        )
        trace.set_tracer_provider(provider)
    except Exception as exc:  # pragma: no cover
        get_logger().warning("tracing_setup_failed", error=str(exc))
