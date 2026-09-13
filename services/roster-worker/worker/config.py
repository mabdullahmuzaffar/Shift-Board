"""roster-worker configuration.

Deliberately shares the SHIFTBOARD_ env prefix with shift-api so both
services read the same Helm-managed ConfigMap for shared values, while
each gets its own workload identity.
"""

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SHIFTBOARD_", extra="ignore")

    environment: Literal["local", "dev", "prod"] = "local"
    service_name: str = "roster-worker"
    log_level: str = "INFO"

    db_driver: str = "ODBC Driver 18 for SQL Server"
    db_host: str = "localhost"
    db_port: int = 1433
    db_name: str = "shiftboard"
    db_user: str = ""
    db_password: str = ""
    db_use_managed_identity: bool = False
    db_url_override: str = ""
    db_echo: bool = False

    servicebus_namespace: str = ""
    servicebus_queue: str = "roster-events"

    # Consumer tuning. max_delivery_count on the queue is 5; after that
    # Service Bus moves the message to the dead-letter queue, which has its
    # own alert rule so poison messages become visible instead of silent.
    prefetch_count: int = 20
    max_wait_seconds: int = 10
    max_message_batch: int = 10

    metrics_port: int = 9102
    otlp_endpoint: str = ""

    @property
    def sqlalchemy_url(self) -> str:
        if self.db_url_override:
            return self.db_url_override
        driver = self.db_driver.replace(" ", "+")
        if self.db_use_managed_identity:
            return (
                f"mssql+pyodbc://@{self.db_host}:{self.db_port}/{self.db_name}"
                f"?driver={driver}&Encrypt=yes&TrustServerCertificate=no"
            )
        return (
            f"mssql+pyodbc://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
            f"?driver={driver}&Encrypt=yes&TrustServerCertificate=no"
        )

    @property
    def servicebus_fqdn(self) -> str:
        return f"{self.servicebus_namespace}.servicebus.windows.net"


@lru_cache
def get_settings() -> Settings:
    return Settings()
