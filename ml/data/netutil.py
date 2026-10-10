"""HTTPS helper shared by the data scripts.

The python.org macOS installer does not use the system certificate store, so
HTTPS requests fail verification unless a CA bundle is supplied. Use certifi's
bundle when it is installed (see ml/requirements.txt); verification stays on.
"""

from __future__ import annotations

import ssl
import urllib.request
from http.client import HTTPResponse

USER_AGENT = "lecture-assistant-research/0.1"


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi
    except ImportError:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=certifi.where())


_CONTEXT = _ssl_context()


def urlopen(url: str, timeout: float = 60) -> HTTPResponse:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=timeout, context=_CONTEXT)
