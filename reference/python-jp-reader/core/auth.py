"""Write-protection for tools exposed on a home LAN: reads are public,
writes need a password.

Comparison is done over fixed-length digests so neither the password nor
its length leaks through timing.

This module is the seam for a future account system: routers call
``write_guard.require`` and nothing else, so swapping password checks for
session checks means changing this module and each tool's config, not the
route handlers.
"""

import hashlib
import hmac

from app.config import settings


class WritePassword:
    """A named password that protects a tool's write endpoints.

    ``password_fn`` is read on every check — tests reconfigure settings
    after import, so the password must never be snapshotted.
    """

    def __init__(self, name: str, password_fn) -> None:
        self.name = name
        self._password_fn = password_fn

    def is_configured(self) -> bool:
        """True when a password has been set. Writes are refused otherwise."""
        return bool(self._password_fn())

    def check(self, supplied: str | None) -> bool:
        """Constant-time check of `supplied` against the configured password.

        Fails closed: with no password configured every write is refused.
        """
        expected = self._password_fn()
        if not expected or not supplied:
            return False
        return hmac.compare_digest(
            hashlib.sha256(supplied.encode()).digest(),
            hashlib.sha256(expected.encode()).digest(),
        )

    def require(self, supplied: str | None) -> None:
        """Raise unless `supplied` matches. The caller turns that into a 4xx."""
        if not self.is_configured():
            raise PermissionError(f"{self.name.upper()}_PASSWORD is not configured")
        if not self.check(supplied):
            raise PermissionError("Invalid password")


# One shared guard for every tool's write endpoints: uploads, saves and
# translations all spend a resource, so they all count as writes. Routers
# map PermissionError onto 401/503 responses.
app_write = WritePassword("app", lambda: settings.app.password)
