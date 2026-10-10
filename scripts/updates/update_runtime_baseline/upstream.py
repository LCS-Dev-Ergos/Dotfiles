"""Bounded HTTPS access to the upstreams the resolvers read."""

import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Protocol

from .model import SourceError

RESPONSE_LIMIT = 16 * 1024 * 1024
TIMEOUT = 60
USER_AGENT = "dotfiles-update-runtime-baseline"
# Only this host receives GITHUB_TOKEN.
GITHUB_API = "api.github.com"
NETWORK_ERRORS = (urllib.error.URLError, TimeoutError, OSError)


class Source(Protocol):
    """What a resolver reads; the offline tests supply recorded responses."""

    def fetch(self, url: str, **kwargs: Any) -> bytes: ...
    def json(self, url: str, **kwargs: Any) -> Any: ...
    def text(self, url: str, **kwargs: Any) -> str: ...
    def github(self, path: str) -> Any: ...
    def yaml(self, url: str) -> Any: ...
    def exists(self, url: str) -> bool: ...
    def redirect(self, url: str) -> str | None: ...


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    """Follow redirects to HTTPS only."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise SourceError(f"{req.full_url} redirects to {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(HttpsRedirect)


class Upstream:
    """Bounded HTTPS reads, cached for the run."""

    def __init__(self, token: str | None = None):
        self.token = token
        self.cache: dict[tuple[str, int], bytes] = {}

    def request(self, url, *, method="GET", headers=None):
        if not url.startswith("https://"):
            raise SourceError(f"refusing a non-HTTPS source: {url}")
        request = urllib.request.Request(
            url,
            method=method,
            headers={"User-Agent": USER_AGENT} | (headers or {}),
        )
        # An unredirected header never follows a redirect to another host.
        if self.token and urllib.parse.urlsplit(url).hostname == GITHUB_API:
            request.add_unredirected_header(
                "Authorization", f"Bearer {self.token}"
            )
        return request

    def fetch(self, url, *, limit=RESPONSE_LIMIT, headers=None):
        key = (url, limit)
        if key not in self.cache:
            try:
                with OPENER.open(
                    self.request(url, headers=headers), timeout=TIMEOUT
                ) as response:
                    data = response.read(limit + 1)
            except NETWORK_ERRORS as error:
                raise SourceError(f"{url}: {error}") from error
            if len(data) > limit:
                raise SourceError(f"{url}: response exceeds {limit} bytes")
            self.cache[key] = data
        return self.cache[key]

    def json(self, url, **kwargs):
        try:
            return json.loads(self.fetch(url, **kwargs))
        except ValueError as error:
            raise SourceError(f"{url}: not JSON ({error})") from error

    def text(self, url, **kwargs):
        return self.fetch(url, **kwargs).decode("utf-8", errors="replace")

    def github(self, path):
        return self.json(
            f"https://{GITHUB_API}/{path}",
            headers={"Accept": "application/vnd.github+json"},
        )

    def yaml(self, url):
        import yaml

        # BaseLoader keeps every scalar a string, so 3.10 stays "3.10".
        return yaml.load(self.text(url), Loader=yaml.BaseLoader)

    def exists(self, url):
        try:
            with OPENER.open(
                self.request(url, method="HEAD"), timeout=TIMEOUT
            ) as response:
                return response.status == 200
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return False
            raise SourceError(f"{url}: {error}") from error
        except NETWORK_ERRORS as error:
            raise SourceError(f"{url}: {error}") from error

    def redirect(self, url):
        """Where a redirecting endpoint points, or None when it does not."""
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(self.request(url), timeout=TIMEOUT):
                return None
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308):
                return error.headers.get("Location")
            if error.code == 404:
                return None
            raise SourceError(f"{url}: {error}") from error
        except NETWORK_ERRORS as error:
            raise SourceError(f"{url}: {error}") from error

    def download(self, url, size):
        """The SHA-256 of a release asset, which must be exactly `size` bytes."""
        digest = hashlib.sha256()
        total = 0
        try:
            with OPENER.open(self.request(url), timeout=TIMEOUT) as response:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > size:
                        break
                    digest.update(chunk)
        except NETWORK_ERRORS as error:
            raise SourceError(f"{url}: {error}") from error
        if total != size:
            raise SourceError(f"{url}: expected {size} bytes, read {total}")
        return digest.hexdigest()


def github_releases(upstream: Source, repository: str) -> list[dict]:
    """Published, non-prerelease releases, newest first as GitHub lists them."""
    return [
        release
        for release in upstream.github(
            f"repos/{repository}/releases?per_page=100"
        )
        if not release.get("draft") and not release.get("prerelease")
    ]


def assets(release: dict) -> dict[str, dict]:
    return {asset["name"]: asset for asset in release.get("assets", [])}
