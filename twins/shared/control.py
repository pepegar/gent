from __future__ import annotations

import json
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse


class ControlPlane:
    def __init__(self):
        self.queue: list[dict] = []
        self.requests: list[dict] = []
        self.auth_keys: list[str] = ["test-key"]
        self.latency_ms: int = 0

    def enqueue(self, spec: dict):
        self.queue.append(spec)

    def dequeue(self) -> dict | None:
        if self.queue:
            return self.queue.pop(0)
        return None

    def record_request(self, req: dict):
        self.requests.append(req)

    def reset(self):
        self.queue.clear()
        self.requests.clear()

    def validate_auth(self, key: str) -> bool:
        if key.startswith("twin-access-"):
            return True
        return key in self.auth_keys

    def echo_response(self, body: dict) -> dict:
        messages = body.get("messages", body.get("input", []))
        last_text = ""
        for msg in reversed(messages):
            if isinstance(msg, dict):
                content = msg.get("content", "")
                if isinstance(content, str) and msg.get("role") == "user":
                    last_text = content
                    break
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict):
                            if block.get("type") == "input_text":
                                last_text = block.get("text", "")
                                break
                            if block.get("type") == "text":
                                last_text = block.get("text", "")
                                break
                    if last_text:
                        break
        return {"type": "text", "content": f"[echo] {last_text}"}


def create_control_router(control: ControlPlane) -> APIRouter:
    router = APIRouter(prefix="/__control")

    @router.post("/enqueue")
    async def enqueue(request: Request):
        body = await request.json()
        control.enqueue(body)
        return {"status": "ok"}

    @router.post("/reset")
    async def reset():
        control.reset()
        return {"status": "ok"}

    @router.get("/requests")
    async def get_requests():
        return control.requests

    @router.get("/health")
    async def health():
        return {"status": "ok"}

    return router
