import base64
import json

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from shared.control import ControlPlane, create_control_router
from shared.sse import (
    openai_text,
    openai_function_call,
    openai_reasoning_then_text,
    openai_error,
    stream_events,
)

app = FastAPI()
control = ControlPlane()
app.include_router(create_control_router(control))


def _extract_bearer_token(request: Request) -> str | None:
    auth = request.headers.get("authorization", "")
    if auth.startswith("Bearer "):
        return auth[7:]
    return None


def _unauthorized_response():
    return JSONResponse(
        status_code=401,
        content={
            "error": {
                "message": "Unauthorized",
                "type": "invalid_request_error",
                "code": "invalid_api_key",
            }
        },
    )


def _build_non_streaming_response(text: str, model: str = "test-model") -> dict:
    return {
        "id": "resp_test",
        "object": "response",
        "status": "completed",
        "output": [
            {
                "type": "message",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text}],
            }
        ],
        "model": model,
        "usage": {"input_tokens": 100, "output_tokens": len(text)},
    }


@app.post("/v1/responses")
async def responses(request: Request):
    token = _extract_bearer_token(request)
    if token is None or not control.validate_auth(token):
        return _unauthorized_response()

    body = await request.json()
    control.record_request(body)

    spec = control.dequeue()
    if spec is None:
        spec = control.echo_response(body)

    spec_type = spec.get("type", "text")
    model = body.get("model", "test-model")
    is_streaming = body.get("stream", True)

    if spec_type == "error":
        status_code = spec.get("status", 400)
        return JSONResponse(
            status_code=status_code,
            content={
                "error": {
                    "message": spec.get("message", "Unknown error"),
                    "type": spec.get("error_type", "server_error"),
                }
            },
        )

    if not is_streaming:
        if spec_type == "text":
            content = spec.get("content", "")
            return JSONResponse(content=_build_non_streaming_response(content, model))
        elif spec_type == "tool_call":
            call_id = spec.get("id", "call_test")
            name = spec.get("name", "unknown")
            arguments = spec.get("input", {})
            return JSONResponse(content={
                "id": "resp_test",
                "object": "response",
                "status": "completed",
                "output": [
                    {
                        "type": "function_call",
                        "call_id": call_id,
                        "name": name,
                        "arguments": json.dumps(arguments),
                    }
                ],
                "model": model,
                "usage": {"input_tokens": 100, "output_tokens": len(json.dumps(arguments))},
            })
        elif spec_type == "thinking_then_text":
            content = spec.get("content", "")
            return JSONResponse(content=_build_non_streaming_response(content, model))
        else:
            content = spec.get("content", "")
            return JSONResponse(content=_build_non_streaming_response(content, model))

    if spec_type == "text":
        events = openai_text(spec.get("content", ""), model)
    elif spec_type == "tool_call":
        events = openai_function_call(
            spec.get("id", "call_test"),
            spec.get("name", "unknown"),
            spec.get("input", {}),
        )
    elif spec_type == "thinking_then_text":
        events = openai_reasoning_then_text(
            spec.get("thinking", ""),
            spec.get("content", ""),
        )
    else:
        events = openai_text(spec.get("content", ""), model)

    return StreamingResponse(
        stream_events(events),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache"},
    )


@app.post("/oauth/token")
async def oauth_token(request: Request):
    form = await request.form()
    grant_type = form.get("grant_type", "")

    if grant_type not in ("authorization_code", "refresh_token"):
        return JSONResponse(
            status_code=400,
            content={"error": "unsupported_grant_type"},
        )

    header = base64.urlsafe_b64encode(json.dumps({"alg": "none"}).encode()).rstrip(b"=").decode()
    payload = base64.urlsafe_b64encode(json.dumps({
        "https://api.openai.com/auth": {
            "chatgpt_account_id": "twin-account-123",
        }
    }).encode()).rstrip(b"=").decode()
    fake_jwt = f"{header}.{payload}."

    return JSONResponse(content={
        "access_token": fake_jwt,
        "refresh_token": "twin-refresh-xxx",
        "expires_in": 3600,
        "token_type": "bearer",
    })
