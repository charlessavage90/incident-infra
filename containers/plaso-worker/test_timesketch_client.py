"""No network, no live Timesketch. The session is injected.

This mirrors the discipline botocore.Stubber gives the AWS paths: assert the
exact calls made, not merely that nothing raised.
"""

import pytest

from timesketch_client import TimesketchClient, TimesketchError


class FakeResponse:
    def __init__(self, status_code=200, json_data=None, cookies=None, text=""):
        self.status_code = status_code
        self._json = json_data if json_data is not None else {}
        self.cookies = cookies or {}
        self.text = text

    def json(self):
        return self._json


class FakeSession:
    """Records every call and returns queued responses in order."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []
        self.cookies = {}
        self.headers = {}

    def _next(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        if not self._responses:
            raise AssertionError(f"unexpected {method} {url}: no response queued")
        return self._responses.pop(0)

    def get(self, url, **kwargs):
        return self._next("GET", url, **kwargs)

    def post(self, url, **kwargs):
        return self._next("POST", url, **kwargs)


# The shape of GET /login/ on the pinned Timesketch release, captured from the
# appliance during Phase 3 acceptance. The token is in the HTML -- a hidden form
# field and a meta tag -- and the only cookie is `session`. An earlier version
# read a csrf_token COOKIE, which this release never sets (defect 8).
LOGIN_PAGE = (
    '<html><head><meta name="csrf-token" content="meta-tok"/></head><body>'
    '<form><input id="csrf_token" name="csrf_token" type="hidden" value="form-tok">'
    "</form></body></html>"
)


def test_login_sends_the_token_from_the_login_form():
    session = FakeSession([
        FakeResponse(cookies={"session": "s"}, text=LOGIN_PAGE),
        FakeResponse(200),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    client.login()

    method, url, kwargs = session.calls[1]
    assert method == "POST"
    assert url == "http://ts:5000/login/"
    assert kwargs["data"]["username"] == "pipeline"
    assert kwargs["data"]["csrf_token"] == "form-tok"
    assert kwargs["headers"]["X-CSRFToken"] == "form-tok"


def test_login_falls_back_to_the_meta_tag():
    page = '<html><head><meta name="csrf-token" content="meta-tok"/></head></html>'
    session = FakeSession([FakeResponse(text=page), FakeResponse(200)])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    client.login()

    assert session.calls[1][2]["headers"]["X-CSRFToken"] == "meta-tok"


def test_login_without_a_csrf_token_fails_loudly():
    session = FakeSession([FakeResponse(cookies={"session": "s"}, text="<html></html>")])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="CSRF"):
        client.login()


def test_resolve_sketch_reuses_an_existing_sketch():
    session = FakeSession([
        FakeResponse(json_data={"objects": [[{"id": 7, "name": "CASE-1"}]]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.resolve_sketch("CASE-1") == 7
    assert len(session.calls) == 1, "a sketch that exists must not be created again"


def test_resolve_sketch_creates_one_when_absent():
    session = FakeSession([
        FakeResponse(json_data={"objects": [[]]}),
        FakeResponse(json_data={"objects": [{"id": 9}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.resolve_sketch("CASE-2") == 9
    assert session.calls[1][0] == "POST"


def test_upload_returns_the_timeline_id():
    session = FakeSession([
        FakeResponse(json_data={"objects": [{"id": 42}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    timeline_id = client.upload(__file__, sketch_id=7, timeline_name="triage")

    assert timeline_id == 42


def test_upload_rejects_a_non_2xx_without_inventing_a_timeline():
    session = FakeSession([FakeResponse(status_code=500)])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="500"):
        client.upload(__file__, sketch_id=7, timeline_name="triage")


def test_event_count_reads_the_timeline_record():
    session = FakeSession([
        FakeResponse(json_data={"objects": [{"id": 42, "datasources": [{"total_file_events": 1337}]}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.event_count(sketch_id=7, timeline_id=42) == 1337


def test_event_count_of_a_timeline_with_no_datasources_is_zero():
    """Zero is a real answer, not an error.

    Spec 4.3 falls back and flags for a responder when plaso produced nothing.
    Raising here would turn a routing outcome into a pipeline failure, and the
    artifact would be reported as broken rather than as empty.
    """
    session = FakeSession([
        FakeResponse(json_data={"objects": [{"id": 42, "datasources": []}]}),
    ])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    assert client.event_count(sketch_id=7, timeline_id=42) == 0


# --- Phase 3 acceptance, defects 9 and 10 ---
#
# Both shapes below were captured from the pinned release on the appliance.


def test_upload_declares_the_file_size():
    # The server reads total_file_size from the form, defaults it to 0, and
    # rejects 0 as "Unable to upload file. File is empty" -- whatever was sent.
    session = FakeSession([FakeResponse(json_data={"objects": [{"id": 42}]})])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    client.upload(__file__, sketch_id=7, timeline_name="triage")

    import os
    data = session.calls[0][2]["data"]
    assert data["total_file_size"] == str(os.path.getsize(__file__))
    assert data["sketch_id"] == "7"


def test_errors_carry_the_server_message():
    body = '{"message": "Unable to upload file. File is empty"}'
    session = FakeSession([FakeResponse(status_code=400, text=body)])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="File is empty"):
        client.upload(__file__, sketch_id=7, timeline_name="triage")


def _timeline(status, events=0, error=""):
    return FakeResponse(json_data={"objects": [{
        "status": [{"status": status}],
        "datasources": [{
            "status": [{"status": status}],
            "total_file_events": events,
            "error_message": error,
        }],
    }]})


def test_wait_until_indexed_polls_past_queueing_and_processing():
    # Upload returns while the datasource is still "queueing" with
    # total_file_events 0. Counting then would flag every artifact as empty.
    session = FakeSession([_timeline("queueing"), _timeline("processing"), _timeline("ready", 7)])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)
    sleeps = []

    client.wait_until_indexed(sketch_id=7, timeline_id=42, sleep=sleeps.append)

    assert len(session.calls) == 3
    assert len(sleeps) == 2


def test_wait_until_indexed_raises_on_fail_with_the_reason():
    session = FakeSession([_timeline("fail", error="bad header")])
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="bad header"):
        client.wait_until_indexed(sketch_id=7, timeline_id=42, sleep=lambda _: None)


def test_wait_until_indexed_gives_up_rather_than_hanging():
    session = FakeSession([_timeline("processing")] * 3)
    client = TimesketchClient("http://ts:5000", "pipeline", "pw", session=session)

    with pytest.raises(TimesketchError, match="not indexed"):
        client.wait_until_indexed(
            sketch_id=7, timeline_id=42, sleep=lambda _: None, attempts=3
        )
