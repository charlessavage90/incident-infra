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
import re
import time

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
            # The body carries Timesketch's reason. Without it, Phase 3
            # acceptance's defect 9 logged only "upload: HTTP 400" and had to be
            # diagnosed by replaying the request by hand on the appliance.
            detail = (getattr(response, "text", "") or "").strip()[:500]
            raise TimesketchError(f"{what}: HTTP {response.status_code} {detail}".rstrip())
        return response

    def login(self):
        """Fetch the login form for its CSRF token, then post credentials.

        The token is in the page, not in a cookie: the pinned release renders it
        as a hidden `csrf_token` form field and a `csrf-token` meta tag, and sets
        only a `session` cookie. Reading a cookie failed every login in Phase 3
        acceptance (defect 8). Upstream's timesketch_api_client reads the form
        field the same way.
        """
        form = self._session.get(self._url("/login/"), timeout=self._timeout)
        token = _csrf_from_page(form.text)
        if not token:
            raise TimesketchError(
                "no CSRF token on the login form: neither the csrf_token form field "
                f"nor the csrf-token meta tag was present (HTTP {form.status_code}). "
                "If the page is not Timesketch's login form, the web container may "
                "not be ready yet."
            )
        self._csrf = token

        self._check(
            self._session.post(
                self._url("/login/"),
                data={
                    "username": self._username,
                    "password": self._password,
                    "csrf_token": token,
                },
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
                # total_file_size is not optional: the server defaults it to 0
                # and rejects 0 as "File is empty" whatever the file holds
                # (Phase 3 acceptance, defect 9).
                data={
                    "name": timeline_name,
                    "sketch_id": str(sketch_id),
                    "total_file_size": str(os.path.getsize(path)),
                },
                files={"file": (os.path.basename(path), handle)},
                headers=self._headers(),
                timeout=self._timeout,
            )
        return _first(self._check(response, "upload").json())["id"]

    def wait_until_indexed(self, sketch_id, timeline_id, sleep=time.sleep, interval=10, attempts=2160):
        """Block until Timesketch has finished indexing the timeline.

        Upload returns as soon as the file is queued: the datasource reads
        "queueing" with total_file_events 0, and indexing runs in the
        timesketch-worker container afterwards. Counting at that point reported
        zero for every artifact and flagged each one for triage (Phase 3
        acceptance, defect 10).

        The default bound is six hours, half the Batch job's twelve-hour
        attempt_duration_seconds, leaving room for the download and upload
        around it.
        """
        for attempt in range(attempts):
            record = self._timeline(sketch_id, timeline_id)
            states = [_latest_status(record)] + [
                _latest_status(ds) for ds in record.get("datasources", [])
            ]
            if "fail" in states:
                reasons = "; ".join(
                    ds.get("error_message", "") for ds in record.get("datasources", [])
                    if ds.get("error_message")
                )
                raise TimesketchError(
                    f"timeline {timeline_id} failed to index: {reasons or 'no reason given'}"
                )
            if states and all(state == "ready" for state in states):
                return
            if attempt < attempts - 1:
                sleep(interval)
        raise TimesketchError(
            f"timeline {timeline_id} not indexed after {attempts} checks; last states {states}"
        )

    def _timeline(self, sketch_id, timeline_id):
        return _first(
            self._check(
                self._session.get(
                    self._url(f"/api/v1/sketches/{sketch_id}/timelines/{timeline_id}/"),
                    timeout=self._timeout,
                ),
                "read timeline",
            ).json()
        )

    def event_count(self, sketch_id, timeline_id):
        record = self._timeline(sketch_id, timeline_id)
        # Zero is a legitimate answer -- spec 4.3 flags it for a responder rather
        # than failing the pipeline.
        return sum(ds.get("total_file_events", 0) for ds in record.get("datasources", []))


_FORM_TOKEN = re.compile(r'<input[^>]*name="csrf_token"[^>]*value="([^"]+)"')
_META_TOKEN = re.compile(r'<meta[^>]*name="csrf-token"[^>]*content="([^"]+)"')


def _latest_status(record):
    """Timesketch keeps a status history; the last entry is the current one."""
    history = record.get("status") or []
    return history[-1].get("status") if history else None


def _csrf_from_page(html):
    """The form field first, as upstream's client does; the meta tag otherwise."""
    for pattern in (_FORM_TOKEN, _META_TOKEN):
        match = pattern.search(html or "")
        if match:
            return match.group(1)
    return None


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
