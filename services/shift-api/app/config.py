"""Runtime configuration for shift-api.

Every value is supplied by the environment. Nothing is hardcoded and no
secret is ever read from a file baked into the image: the database password
and Service Bus connection details arrive as environment variables that
External Secrets Operator projects from Azure Key Vault, or -- in Azure --
are replaced entirely by a managed identity token.
"""

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SHIFTBOARD_", extra="ignore")

    environment: Literal["local", "dev", "prod"] = "local"
    service_name: str = "shift-api"
    log_level: str = "INFO"

    # --- Database -------------------------------------------------------
    # In Azure we connect to Azure SQL over a private endpoint using the
    # pod's federated workload identity, so no password exists at all.
    db_driver: str = "ODBC Driver 18 for SQL Server"
    db_host: str = "localhost"
    db_port: int = 1433
    db_name: str = "shiftboard"
    db_user: str = ""
    db_password: str = ""
    db_use_managed_identity: bool = False
    db_echo: bool = False

    # SQLite escape hatch for unit tests and local dev without a SQL Server.
    db_url_override: str = ""

    # --- Messaging ------------------------------------------------------
    servicebus_namespace: str = ""
    servicebus_queue: str = "roster-events"
    servicebus_enabled: bool = True

    # --- Identity -------------------------------------------------------
    # Entra ID application registration used to validate bearer tokens.
    entra_tenant_id: str = ""
    entra_audience: str = ""
    auth_enabled: bool = False

    # --- Telemetry ------------------------------------------------------
    otlp_endpoint: str = ""
    metrics_enabled: bool = True

    @property
    def sqlalchemy_url(self) -> str:
        if self.db_url_override:
            return self.db_url_override
        driver = self.db_driver.replace(" ", "+")
        if self.db_use_managed_identity:
            # azure-identity supplies the access token via a connect event hook
            # registered in db.py; no credentials appear in the URL.
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
