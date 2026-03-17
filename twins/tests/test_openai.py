import json
import base64

VALID_BODY = {
    "model": "gpt-5.1",
    "stream": True,
    "input": [
        {
            "role": "user",
            "content": [{"type": "input_text", "text": "Hello"}],
        }
    ],
}

AUTH_HEADER = {"Authorization": "Bearer test-key"}


def _make_body(stream: bool = True, text: str = "Hello") -> dict:
    return {
        "model": "gpt-5.1",
        "stream": stream,
        "input": [
            {
                "role": "user",
                "content": [{"type": "input_text", "text": text}],
            }
        ],
    }


def _parse_sse_events(raw: str) -> list[dict]:
    events = []
    for line in raw.split("\n"):
        line = line.strip()
        if line.startswith("data: "):
            data_str = line[6:]
            if data_str == "[DONE]":
                events.append({"_done": True})
            else:
                events.append(json.loads(data_str))
    return events


def test_health(openai_client):
    resp = openai_client.get("/__control/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_auth_valid_bearer(openai_client):
    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(),
        headers=AUTH_HEADER,
    )
    assert resp.status_code == 200


def test_auth_missing(openai_client):
    resp = openai_client.post("/v1/responses", json=_make_body())
    assert resp.status_code == 401
    body = resp.json()
    assert body["error"]["code"] == "invalid_api_key"


def test_auth_invalid(openai_client):
    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(),
        headers={"Authorization": "Bearer wrong-key"},
    )
    assert resp.status_code == 401
    body = resp.json()
    assert body["error"]["code"] == "invalid_api_key"


def test_responses_echo(openai_client):
    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(stream=True, text="ping"),
        headers=AUTH_HEADER,
    )
    assert resp.status_code == 200
    events = _parse_sse_events(resp.text)
    text_deltas = [e for e in events if e.get("type") == "response.output_text.delta"]
    assert len(text_deltas) == 1
    assert "[echo] ping" in text_deltas[0]["delta"]


def test_responses_streaming(openai_client):
    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(stream=True),
        headers=AUTH_HEADER,
    )
    assert resp.status_code == 200
    assert "text/event-stream" in resp.headers["content-type"]

    events = _parse_sse_events(resp.text)
    event_types = [e.get("type") for e in events if "type" in e]
    assert "response.created" in event_types
    assert "response.in_progress" in event_types
    assert "response.output_item.added" in event_types
    assert "response.output_text.delta" in event_types
    assert "response.output_item.done" in event_types
    assert "response.completed" in event_types
    assert events[-1].get("_done") is True


def test_responses_non_streaming(openai_client):
    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(stream=False, text="world"),
        headers=AUTH_HEADER,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["id"] == "resp_test"
    assert body["object"] == "response"
    assert body["status"] == "completed"
    assert len(body["output"]) > 0
    output_msg = body["output"][0]
    assert output_msg["type"] == "message"
    assert output_msg["content"][0]["type"] == "output_text"
    assert "[echo] world" in output_msg["content"][0]["text"]
    assert "usage" in body


def test_responses_dequeue(openai_client):
    enqueue_resp = openai_client.post(
        "/__control/enqueue",
        json={"type": "text", "content": "custom response"},
    )
    assert enqueue_resp.status_code == 200

    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(stream=True),
        headers=AUTH_HEADER,
    )
    assert resp.status_code == 200

    events = _parse_sse_events(resp.text)
    text_deltas = [e for e in events if e.get("type") == "response.output_text.delta"]
    assert len(text_deltas) == 1
    assert text_deltas[0]["delta"] == "custom response"


def test_responses_tool_call(openai_client):
    enqueue_resp = openai_client.post(
        "/__control/enqueue",
        json={
            "type": "tool_call",
            "id": "call_abc123",
            "name": "read_file",
            "input": {"path": "/tmp/test.txt"},
        },
    )
    assert enqueue_resp.status_code == 200

    resp = openai_client.post(
        "/v1/responses",
        json=_make_body(stream=True),
        headers=AUTH_HEADER,
    )
    assert resp.status_code == 200

    events = _parse_sse_events(resp.text)
    event_types = [e.get("type") for e in events if "type" in e]
    assert "response.output_item.added" in event_types
    assert "response.function_call_arguments.delta" in event_types
    assert "response.output_item.done" in event_types
    assert "response.completed" in event_types

    added = [e for e in events if e.get("type") == "response.output_item.added"][0]
    assert added["item"]["type"] == "function_call"
    assert added["item"]["name"] == "read_file"
    assert added["item"]["call_id"] == "call_abc123"

    done = [e for e in events if e.get("type") == "response.output_item.done"][0]
    assert done["item"]["type"] == "function_call"
    args = json.loads(done["item"]["arguments"])
    assert args["path"] == "/tmp/test.txt"


def test_oauth_token_exchange(openai_client):
    resp = openai_client.post(
        "/oauth/token",
        data={
            "grant_type": "authorization_code",
            "code": "test-code",
            "redirect_uri": "http://localhost/callback",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "access_token" in body
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 3600
    assert "refresh_token" in body

    jwt_parts = body["access_token"].split(".")
    assert len(jwt_parts) == 3
    payload_b64 = jwt_parts[1]
    padding = 4 - len(payload_b64) % 4
    if padding != 4:
        payload_b64 += "=" * padding
    payload = json.loads(base64.urlsafe_b64decode(payload_b64))
    assert "https://api.openai.com/auth" in payload
    assert payload["https://api.openai.com/auth"]["chatgpt_account_id"] == "twin-account-123"


def test_oauth_token_refresh(openai_client):
    resp = openai_client.post(
        "/oauth/token",
        data={
            "grant_type": "refresh_token",
            "refresh_token": "old-refresh-token",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "access_token" in body
    assert body["token_type"] == "bearer"
    assert body["refresh_token"] == "twin-refresh-xxx"


def test_oauth_invalid_grant_type(openai_client):
    resp = openai_client.post(
        "/oauth/token",
        data={"grant_type": "client_credentials"},
    )
    assert resp.status_code == 400


def test_control_enqueue_and_requests(openai_client):
    openai_client.post(
        "/__control/enqueue",
        json={"type": "text", "content": "tracked"},
    )

    openai_client.post(
        "/v1/responses",
        json=_make_body(stream=True, text="test message"),
        headers=AUTH_HEADER,
    )

    resp = openai_client.get("/__control/requests")
    assert resp.status_code == 200
    requests = resp.json()
    assert len(requests) == 1
    assert requests[0]["model"] == "gpt-5.1"


def test_control_reset(openai_client):
    openai_client.post(
        "/__control/enqueue",
        json={"type": "text", "content": "will be cleared"},
    )

    openai_client.post("/__control/reset")

    openai_client.post(
        "/v1/responses",
        json=_make_body(stream=True, text="after reset"),
        headers=AUTH_HEADER,
    )
    events = _parse_sse_events(
        openai_client.post(
            "/v1/responses",
            json=_make_body(stream=True, text="after reset"),
            headers=AUTH_HEADER,
        ).text
    )
    text_deltas = [e for e in events if e.get("type") == "response.output_text.delta"]
    assert "[echo] after reset" in text_deltas[0]["delta"]
