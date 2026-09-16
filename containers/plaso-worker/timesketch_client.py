"""Minimal Timesketch REST client (spec 4.1 finalisation).

timesketch_api_client is NOT installed in the release image, so scripted
interaction is the REST API with a session cookie and a CSRF token.

Timesketch auth is local accounts, SSO_ENABLED (trusting a REMOTE_USER env var
set by a fronting web server), or GOOGLE_OIDC_*. There is no AWS IAM
integration, no SAML and no LDAP, so the worker cannot present a role and must
present a password like any other client -- as the dedicated `pipeline` account
created by cloud-init.

The session is injectable so the tests never open a socket.
"""

import os

import requests


class TimesketchError(Exception):
    """Timesketch did not do what was asked. The artifact stays in evidence."""


class TimesketchClient:
    def __init__(self, base_url, username, password, session=None, timeout=300):
        self.base_url = base_url.rstrip("/")
        self._username = username
        self._password = password
        self._session = session if session is not None else requests.Session()
        self._timeout = timeout
        self._csrf = None

    def _url(self, path):
        return f"{self.base_url}{path}"

    def _check(self, response, what):
        if not 200 <= response.status_code < 300:
            raise TimesketchError(f"{what}: HTTP {response.status_code}")
        return response

    def login(self):
        """Fetch the login form for its CSRF cookie, then post credentials."""
        form = self._session.get(self._url("/login/"), timeout=self._timeout)
        token = form.cookies.get("csrf_token")
        if not token:
            raise TimesketchError(
                "no CSRF token on the login form. Timesketch sets csrf_token as a "
                "cookie on GET /login/; its absence usually means the web container "
                "is up but not yet ready."
            )
        self._csrf = token

        self._check(
            self._session.post(
                self._url("/login/"),
                data={"username": self._username, "password": self._password},
                headers={"X-CSRFToken": token},
                timeout=self._timeout,
            ),
            "login",
        )

    def _headers(self):
        return {"X-CSRFToken": self._csrf} if self._csrf else {}

    def resolve_sketch(self, name):
        """A case is a data concept (D11): one sketch per case, reused."""
        listing = self._check(
            self._session.get(self._url("/api/v1/sketches/"), timeout=self._timeout),
            "list sketches",
        ).json()

        for sketch in _flatten(listing.get("objects", [])):
            if sketch.get("name") == name:
                return sketch["id"]

        created = self._check(
            self._session.post(
                self._url("/api/v1/sketches/"),
                json={"name": name, "description": name},
                headers=self._headers(),
                timeout=self._timeout,
            ),
            "create sketch",
        ).json()
        return _first(created)["id"]

    def upload(self, path, sketch_id, timeline_name):
        with open(path, "rb") as handle:
            response = self._session.post(
                self._url("/api/v1/upload/"),
                data={"name": timeline_name, "sketch_id": str(sketch_id)},
                files={"file": (os.path.basename(path), handle)},
                headers=self._headers(),
                timeout=self._timeout,
            )
        return _first(self._check(response, "upload").json())["id"]

    def event_count(self, sketch_id, timeline_id):
        record = _first(
            self._check(
                self._session.get(
                    self._url(f"/api/v1/sketches/{sketch_id}/timelines/{timeline_id}/"),
                    timeout=self._timeout,
                ),
                "read timeline",
            ).json()
        )
        # Zero is a legitimate answer -- spec 4.3 flags it for a responder rather
        # than failing the pipeline.
        return sum(ds.get("total_file_events", 0) for ds in record.get("datasources", []))


def _flatten(objects):
    """Timesketch wraps collections one level deeper than single records."""
    for entry in objects:
        if isinstance(entry, list):
            yield from entry
        else:
            yield entry


def _first(payload):
    objects = list(_flatten(payload.get("objects", [])))
    if not objects:
        raise TimesketchError(f"expected an object in the response, got {payload!r}")
    return objects[0]
