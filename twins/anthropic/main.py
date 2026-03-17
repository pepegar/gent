import json
import uuid
from typing import Optional
from fastapi import FastAPI, Request, Query
from fastapi.responses import JSONResponse, StreamingResponse

from shared.sse import (
    anthropic_text,
    anthropic_text_chunked,
    anthropic_tool_call,
    anthropic_text_then_tool,
    anthropic_thinking_then_text,
    anthropic_error,
    anthropic_models_page,
    stream_events,
)
from shared.control import ControlPlane, create_control_router

app = FastAPI()
control = ControlPlane()
app.include_router(create_control_router(control))

DEFAULT_MODELS = [
    {
        "id": "claude-sonnet-4-20250514",
        "display_name": "Claude Sonnet 4",
        "created_at": "2025-05-14T00:00:00Z",
    },
    {
        "id": "claude-opus-4-20250514",
        "display_name": "Claude Opus 4",
        "created_at": "2025-05-14T00:00:00Z",
    },
    {
        "id": "claude-haiku-4-20250514",
        "display_name": "Claude Haiku 4",
        "created_at": "2025-05-14T00:00:00Z",
    },
]


def extract_auth_key(request: Request) -> Optional[str]:
    api_key = request.headers.get("x-api-key")
    if api_key:
        return api_key
    auth_header = request.headers.get("authorization")
    if auth_header and auth_header.startswith("Bearer "):
        return auth_header[7:]
    return None


def build_streaming_events(spec: dict) -> list[str]:
    spec_type = spec.get("type", "text")
    model = spec.get("model", "test-model")

    if spec_type == "text":
        content = spec.get("content", "")
        chunks = spec.get("chunks")
        if chunks:
            return anthropic_text_chunked(chunks, model=model)
        return anthropic_text(content, model=model)
    elif spec_type == "tool_call":
        return anthropic_tool_call(
            tool_id=spec.get("tool_id", "tool_001"),
            name=spec.get("name", "unknown"),
            input_dict=spec.get("input", {}),
            model=model,
        )
    elif spec_type == "text_then_tool":
        return anthropic_text_then_tool(
            text=spec.get("text", ""),
            tool_id=spec.get("tool_id", "tool_001"),
            name=spec.get("name", "unknown"),
            input_dict=spec.get("input", {}),
            model=model,
        )
    elif spec_type == "thinking_then_text":
        return anthropic_thinking_then_text(
            thinking=spec.get("thinking", ""),
            text=spec.get("text", ""),
            model=model,
        )
    elif spec_type == "error":
        return anthropic_error(
            message=spec.get("message", "unknown error"),
            error_type=spec.get("error_type", "api_error"),
        )
    else:
        return anthropic_text(spec.get("content", ""), model=model)


def build_non_streaming_response(spec: dict) -> dict:
    spec_type = spec.get("type", "text")

    if spec_type == "text":
        content = spec.get("content", "")
        return {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": content}],
            "model": spec.get("model", "test-model"),
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5},
        }
    elif spec_type == "tool_call":
        return {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": spec.get("tool_id", "tool_001"),
                    "name": spec.get("name", "unknown"),
                    "input": spec.get("input", {}),
                }
            ],
            "model": spec.get("model", "test-model"),
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 10, "output_tokens": 15},
        }
    elif spec_type == "text_then_tool":
        return {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": spec.get("text", "")},
                {
                    "type": "tool_use",
                    "id": spec.get("tool_id", "tool_001"),
                    "name": spec.get("name", "unknown"),
                    "input": spec.get("input", {}),
                },
            ],
            "model": spec.get("model", "test-model"),
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 10, "output_tokens": 20},
        }
    elif spec_type == "thinking_then_text":
        return {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": spec.get("thinking", "")},
                {"type": "text", "text": spec.get("text", "")},
            ],
            "model": spec.get("model", "test-model"),
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 25},
        }
    else:
        return {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": spec.get("content", "")}],
            "model": spec.get("model", "test-model"),
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5},
        }


@app.post("/v1/messages")
async def messages(request: Request):
    anthropic_version = request.headers.get("anthropic-version")
    if anthropic_version != "2023-06-01":
        return JSONResponse(
            status_code=400,
            content={
                "type": "error",
                "error": {
                    "type": "invalid_request_error",
                    "message": "missing or invalid anthropic-version header",
                },
            },
        )

    auth_key = extract_auth_key(request)
    if not auth_key or not control.validate_auth(auth_key):
        return JSONResponse(
            status_code=401,
            content={
                "type": "error",
                "error": {
                    "type": "authentication_error",
                    "message": "invalid x-api-key",
                },
            },
        )

    body = await request.json()
    control.record_request({"headers": dict(request.headers), "body": body})

    spec = control.dequeue()
    if spec is None:
        spec = control.echo_response(body)

    spec_status = spec.get("status", 200)
    if spec_status != 200:
        error_events = anthropic_error(
            message=spec.get("message", "error"),
            error_type=spec.get("error_type", "api_error"),
        )
        if body.get("stream"):
            return StreamingResponse(
                stream_events(error_events),
                media_type="text/event-stream",
                headers={"Cache-Control": "no-cache"},
                status_code=spec_status,
            )
        return JSONResponse(
            status_code=spec_status,
            content={
                "type": "error",
                "error": {
                    "type": spec.get("error_type", "api_error"),
                    "message": spec.get("message", "error"),
                },
            },
        )

    if body.get("stream"):
        events = build_streaming_events(spec)
        return StreamingResponse(
            stream_events(events),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache"},
        )
    else:
        response = build_non_streaming_response(spec)
        return JSONResponse(content=response)


@app.get("/v1/models")
async def list_models(
    request: Request,
    limit: int = Query(default=100),
    after_id: Optional[str] = Query(default=None),
):
    auth_key = extract_auth_key(request)
    if not auth_key or not control.validate_auth(auth_key):
        return JSONResponse(
            status_code=401,
            content={
                "type": "error",
                "error": {
                    "type": "authentication_error",
                    "message": "invalid x-api-key",
                },
            },
        )

    models = DEFAULT_MODELS
    if after_id:
        found_index = None
        for i, m in enumerate(models):
            if m["id"] == after_id:
                found_index = i
                break
        if found_index is not None:
            models = models[found_index + 1 :]
        else:
            models = []

    truncated = models[:limit]
    has_more = len(models) > limit

    first_id = truncated[0]["id"] if truncated else None
    last_id = truncated[-1]["id"] if truncated else None

    return JSONResponse(
        content={
            "data": truncated,
            "has_more": has_more,
            "first_id": first_id,
            "last_id": last_id,
        }
    )


@app.post("/v1/oauth/token")
async def oauth_token(request: Request):
    body = await request.json()
    grant_type = body.get("grant_type")

    if grant_type == "authorization_code":
        token_uuid = str(uuid.uuid4())
        return JSONResponse(
            content={
                "access_token": f"twin-access-{token_uuid}",
                "refresh_token": f"twin-refresh-{token_uuid}",
                "expires_in": 3600,
                "token_type": "bearer",
            }
        )
    elif grant_type == "refresh_token":
        token_uuid = str(uuid.uuid4())
        return JSONResponse(
            content={
                "access_token": f"twin-access-{token_uuid}",
                "refresh_token": f"twin-refresh-{token_uuid}",
                "expires_in": 3600,
                "token_type": "bearer",
            }
        )
    else:
        return JSONResponse(
            status_code=400,
            content={
                "error": "unsupported_grant_type",
                "error_description": f"grant_type '{grant_type}' is not supported",
            },
        )
