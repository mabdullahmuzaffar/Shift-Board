"""Bearer token validation against Microsoft Entra ID.

Tokens are validated against the tenant's published JWKS. Authorisation is
role-based: the Entra app registration defines two app roles, `Scheduler`
(can create and cancel shifts) and `Worker` (can claim shifts and read).

Auth is toggleable via SHIFTBOARD_AUTH_ENABLED so local dev and smoke tests
do not need a tenant, but it is forced on in prod by the Helm values.
"""

from __future__ import annotations

import time
from typing import Any

import httpx
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import jwt
from jose.exceptions import JWTError

from app.config import Settings, get_settings
from app.telemetry import get_logger

log = get_logger(__name__)
_bearer = HTTPBearer(auto_error=False)

ROLE_SCHEDULER = "Scheduler"
ROLE_WORKER = "Worker"

_jwks_cache: dict[str, Any] = {"keys": None, "fetched_at": 0.0}
_JWKS_TTL_SECONDS = 3600


def _jwks_uri(tenant_id: str) -> str:
    return f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"


def _get_jwks(tenant_id: str) -> dict[str, Any]:
    now = time.time()
    if _jwks_cache["keys"] and now - _jwks_cache["fetched_at"] < _JWKS_TTL_SECONDS:
        return _jwks_cache["keys"]
    resp = httpx.get(_jwks_uri(tenant_id), timeout=5.0)
    resp.raise_for_status()
    _jwks_cache["keys"] = resp.json()
    _jwks_cache["fetched_at"] = now
    return _jwks_cache["keys"]


class Principal:
    def __init__(self, subject: str, roles: list[str], name: str = "") -> None:
        self.subject = subject
        self.roles = roles
        self.name = name

    def has_role(self, role: str) -> bool:
        return role in self.roles


ANONYMOUS = Principal(subject="anonymous", roles=[ROLE_SCHEDULER, ROLE_WORKER], name="local")


def current_principal(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
    settings: Settings = Depends(get_settings),
) -> Principal:
    if not settings.auth_enabled:
        return ANONYMOUS

    if creds is None or not creds.credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="missing bearer token"
        )

    try:
        jwks = _get_jwks(settings.entra_tenant_id)
        claims = jwt.decode(
            creds.credentials,
            jwks,
            algorithms=["RS256"],
            audience=settings.entra_audience,
            issuer=f"https://login.microsoftonline.com/{settings.entra_tenant_id}/v2.0",
        )
    except (JWTError, httpx.HTTPError) as exc:
        log.warning("token_rejected", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid token"
        ) from exc

    return Principal(
        subject=claims.get("sub", ""),
        roles=claims.get("roles", []),
        name=claims.get("name", ""),
    )


def require_role(role: str):
    def _guard(principal: Principal = Depends(current_principal)) -> Principal:
        if not principal.has_role(role):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"role '{role}' required",
            )
        return principal

    return _guard
