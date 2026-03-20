import sys
import os
import json
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from fastapi.testclient import TestClient
from anthropic.main import app, control

VALID_HEADERS = {
    "x-api-key": "test-key",
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
}

MINIMAL_BODY = {
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello"}],
}


@pytest.fixture
def client():
    control.reset()
    c = TestClient(app)
    yield c
    control.reset()


def test_health(client):
    resp = client.get("/__control/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_auth_valid_api_key(client):
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200


def test_auth_valid_bearer(client):
    headers = {
        "authorization": "Bearer test-key",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    resp = client.post(
        "/v1/messages",
        headers=headers,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200


def test_auth_missing(client):
    headers = {
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    resp = client.post(
        "/v1/messages",
        headers=headers,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 401
    body = resp.json()
    assert body["type"] == "error"
    assert body["error"]["type"] == "authentication_error"


def test_auth_invalid(client):
    headers = {
        "x-api-key": "wrong-key",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    resp = client.post(
        "/v1/messages",
        headers=headers,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 401
    body = resp.json()
    assert body["error"]["type"] == "authentication_error"


def test_missing_anthropic_version(client):
    headers = {
        "x-api-key": "test-key",
        "content-type": "application/json",
    }
    resp = client.post(
        "/v1/messages",
        headers=headers,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 400
    body = resp.json()
    assert body["type"] == "error"
    assert body["error"]["type"] == "invalid_request_error"


def test_messages_echo(client):
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["type"] == "message"
    assert body["role"] == "assistant"
    assert len(body["content"]) == 1
    assert body["content"][0]["type"] == "text"
    assert "[echo] Hello" in body["content"][0]["text"]


def test_messages_streaming(client):
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": True},
    )
    assert resp.status_code == 200
    assert "text/event-stream" in resp.headers["content-type"]
    text = resp.text
    assert "message_start" in text
    assert "content_block_start" in text
    assert "content_block_delta" in text
    assert "message_stop" in text
    assert "[DONE]" in text


def test_messages_non_streaming(client):
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["type"] == "message"
    assert body["role"] == "assistant"
    assert "stop_reason" in body


def test_messages_dequeue(client):
    control.enqueue({"type": "text", "content": "custom response"})
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["content"][0]["text"] == "custom response"


def test_messages_dequeue_streaming(client):
    control.enqueue({"type": "text", "content": "streamed custom"})
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": True},
    )
    assert resp.status_code == 200
    text = resp.text
    assert "streamed custom" in text


def test_messages_dequeue_tool_call(client):
    control.enqueue({
        "type": "tool_call",
        "tool_id": "tool_abc",
        "name": "read_file",
        "input": {"path": "/tmp/test.txt"},
    })
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["content"][0]["type"] == "tool_use"
    assert body["content"][0]["name"] == "read_file"
    assert body["content"][0]["id"] == "tool_abc"


def test_messages_error_status(client):
    control.enqueue({
        "type": "error",
        "status": 429,
        "message": "rate limited",
        "error_type": "rate_limit_error",
    })
    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 429


def test_models_list(client):
    resp = client.get(
        "/v1/models",
        headers={"x-api-key": "test-key"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "data" in body
    assert len(body["data"]) == 3
    ids = [m["id"] for m in body["data"]]
    assert "claude-sonnet-4-20250514" in ids
    assert "claude-opus-4-20250514" in ids
    assert "claude-haiku-4-20250514" in ids
    assert body["has_more"] is False


def test_models_pagination(client):
    resp = client.get(
        "/v1/models",
        headers={"x-api-key": "test-key"},
        params={"limit": 1},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["data"]) == 1
    assert body["has_more"] is True
    first_id = body["data"][0]["id"]
    assert body["first_id"] == first_id
    assert body["last_id"] == first_id

    resp2 = client.get(
        "/v1/models",
        headers={"x-api-key": "test-key"},
        params={"limit": 1, "after_id": first_id},
    )
    assert resp2.status_code == 200
    body2 = resp2.json()
    assert len(body2["data"]) == 1
    assert body2["data"][0]["id"] != first_id
    assert body2["has_more"] is True

    resp3 = client.get(
        "/v1/models",
        headers={"x-api-key": "test-key"},
        params={"after_id": body2["data"][0]["id"]},
    )
    assert resp3.status_code == 200
    body3 = resp3.json()
    assert len(body3["data"]) == 1
    assert body3["has_more"] is False


def test_models_auth_required(client):
    resp = client.get("/v1/models")
    assert resp.status_code == 401


def test_oauth_token_exchange(client):
    resp = client.post(
        "/v1/oauth/token",
        json={
            "grant_type": "authorization_code",
            "client_id": "test-client",
            "code": "test-code",
            "redirect_uri": "https://example.com/callback",
            "code_verifier": "test-verifier",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"].startswith("twin-access-")
    assert body["refresh_token"].startswith("twin-refresh-")
    assert body["expires_in"] == 3600
    assert body["token_type"] == "bearer"


def test_oauth_token_refresh(client):
    resp = client.post(
        "/v1/oauth/token",
        json={
            "grant_type": "refresh_token",
            "client_id": "test-client",
            "refresh_token": "some-refresh-token",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"].startswith("twin-access-")
    assert body["refresh_token"].startswith("twin-refresh-")
    assert body["expires_in"] == 3600


def test_oauth_invalid_grant_type(client):
    resp = client.post(
        "/v1/oauth/token",
        json={"grant_type": "client_credentials"},
    )
    assert resp.status_code == 400


def test_control_enqueue_and_requests(client):
    client.post(
        "/__control/enqueue",
        json={"type": "text", "content": "queued response"},
    )

    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["content"][0]["text"] == "queued response"

    requests_resp = client.get("/__control/requests")
    assert requests_resp.status_code == 200
    requests_list = requests_resp.json()
    assert len(requests_list) == 1
    assert requests_list[0]["body"]["messages"][0]["content"] == "Hello"


def test_control_reset(client):
    client.post(
        "/__control/enqueue",
        json={"type": "text", "content": "will be cleared"},
    )
    client.post("/__control/reset")

    resp = client.post(
        "/v1/messages",
        headers=VALID_HEADERS,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "[echo]" in body["content"][0]["text"]


def test_oauth_token_exchange(client):
    resp = client.post(
        "/v1/oauth/token",
        json={
            "grant_type": "authorization_code",
            "client_id": "test-client",
            "code": "test-code",
            "redirect_uri": "https://example.com/callback",
            "code_verifier": "test-verifier",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"].startswith("twin-access-")
    assert body["refresh_token"].startswith("twin-refresh-")
    assert body["expires_in"] == 3600
    assert body["token_type"] == "bearer"


def test_oauth_token_exchange_records_request(client):
    """Verify the token exchange request is captured in the control plane."""
    client.post(
        "/v1/oauth/token",
        json={
            "grant_type": "authorization_code",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "code": "auth-code-xyz",
            "redirect_uri": "https://console.anthropic.com/oauth/code/callback",
            "code_verifier": "pkce-verifier-abc",
        },
    )
    requests_resp = client.get("/__control/requests")
    requests_list = requests_resp.json()
    oauth_reqs = [r for r in requests_list if r.get("endpoint") == "oauth_token"]
    assert len(oauth_reqs) == 1
    assert oauth_reqs[0]["body"]["grant_type"] == "authorization_code"
    assert oauth_reqs[0]["body"]["code"] == "auth-code-xyz"
    assert oauth_reqs[0]["body"]["code_verifier"] == "pkce-verifier-abc"


def test_oauth_token_refresh(client):
    resp = client.post(
        "/v1/oauth/token",
        json={
            "grant_type": "refresh_token",
            "client_id": "test-client",
            "refresh_token": "some-refresh-token",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"].startswith("twin-access-")
    assert body["refresh_token"].startswith("twin-refresh-")
    assert body["expires_in"] == 3600


def test_oauth_invalid_grant_type(client):
    resp = client.post(
        "/v1/oauth/token",
        json={"grant_type": "client_credentials"},
    )
    assert resp.status_code == 400


def test_oauth_token_accepted_for_api_calls(client):
    """Verify that twin-access-* tokens are accepted for API calls (Bearer auth)."""
    headers = {
        "authorization": "Bearer twin-access-test-uuid-12345",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    resp = client.post(
        "/v1/messages",
        headers=headers,
        json={**MINIMAL_BODY, "stream": False},
    )
    assert resp.status_code == 200
