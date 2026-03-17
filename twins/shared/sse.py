from __future__ import annotations

import json
from typing import AsyncGenerator


def anthropic_text(text: str, model: str = "test-model") -> list[str]:
    return [
        f'data: {json.dumps({"type": "message_start", "message": {"id": "msg_test", "type": "message", "role": "assistant", "content": [], "model": model, "stop_reason": None}})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})}',
        f'data: {json.dumps({"type": "content_block_stop", "index": 0})}',
        f'data: {json.dumps({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 10}})}',
        f'data: {json.dumps({"type": "message_stop"})}',
        "data: [DONE]",
    ]


def anthropic_text_chunked(chunks: list[str], model: str = "test-model") -> list[str]:
    lines = [
        f'data: {json.dumps({"type": "message_start", "message": {"id": "msg_test", "type": "message", "role": "assistant", "content": [], "model": model, "stop_reason": None}})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})}',
    ]
    for chunk in chunks:
        lines.append(
            f'data: {json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": chunk}})}'
        )
    lines.extend([
        f'data: {json.dumps({"type": "content_block_stop", "index": 0})}',
        f'data: {json.dumps({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 10}})}',
        f'data: {json.dumps({"type": "message_stop"})}',
        "data: [DONE]",
    ])
    return lines


def anthropic_tool_call(tool_id: str, name: str, input_dict: dict, model: str = "test-model") -> list[str]:
    input_json = json.dumps(input_dict)
    return [
        f'data: {json.dumps({"type": "message_start", "message": {"id": "msg_test", "type": "message", "role": "assistant", "content": [], "model": model, "stop_reason": None}})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": tool_id, "name": name, "input": {}}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": input_json}})}',
        f'data: {json.dumps({"type": "content_block_stop", "index": 0})}',
        f'data: {json.dumps({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 15}})}',
        f'data: {json.dumps({"type": "message_stop"})}',
        "data: [DONE]",
    ]


def anthropic_text_then_tool(text: str, tool_id: str, name: str, input_dict: dict, model: str = "test-model") -> list[str]:
    input_json = json.dumps(input_dict)
    return [
        f'data: {json.dumps({"type": "message_start", "message": {"id": "msg_test", "type": "message", "role": "assistant", "content": [], "model": model, "stop_reason": None}})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})}',
        f'data: {json.dumps({"type": "content_block_stop", "index": 0})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": tool_id, "name": name, "input": {}}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": input_json}})}',
        f'data: {json.dumps({"type": "content_block_stop", "index": 1})}',
        f'data: {json.dumps({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 20}})}',
        f'data: {json.dumps({"type": "message_stop"})}',
        "data: [DONE]",
    ]


def anthropic_thinking_then_text(thinking: str, text: str, model: str = "test-model") -> list[str]:
    return [
        f'data: {json.dumps({"type": "message_start", "message": {"id": "msg_test", "type": "message", "role": "assistant", "content": [], "model": model, "stop_reason": None}})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": thinking}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig_test_abc123"}})}',
        f'data: {json.dumps({"type": "content_block_stop", "index": 0})}',
        f'data: {json.dumps({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}})}',
        f'data: {json.dumps({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": text}})}',
        f'data: {json.dumps({"type": "content_block_stop", "index": 1})}',
        f'data: {json.dumps({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 25}})}',
        f'data: {json.dumps({"type": "message_stop"})}',
        "data: [DONE]",
    ]


def anthropic_error(message: str, error_type: str = "api_error") -> list[str]:
    return [
        f'data: {json.dumps({"type": "error", "error": {"type": error_type, "message": message}})}',
        "data: [DONE]",
    ]


def anthropic_models_page(models: list[dict], has_more: bool = False, last_id: str | None = None) -> dict:
    first_id = models[0]["id"] if models else None
    effective_last_id = last_id if last_id else (models[-1]["id"] if models else None)
    return {
        "data": models,
        "has_more": has_more,
        "first_id": first_id,
        "last_id": effective_last_id,
    }


def openai_text(text: str, model: str = "test-model") -> list[str]:
    response_obj = {
        "id": "resp_test",
        "object": "response",
        "status": "in_progress",
        "output": [],
        "model": model,
    }
    return [
        f'data: {json.dumps({"type": "response.created", "response": response_obj})}',
        f'data: {json.dumps({"type": "response.in_progress", "response": response_obj})}',
        f'data: {json.dumps({"type": "response.output_item.added", "output_index": 0, "item": {"type": "message", "role": "assistant", "content": [], "id": "msg_test", "status": "in_progress"}})}',
        f'data: {json.dumps({"type": "response.output_text.delta", "output_index": 0, "content_index": 0, "delta": text})}',
        f'data: {json.dumps({"type": "response.output_item.done", "output_index": 0, "item": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}], "id": "msg_test", "status": "completed"}})}',
        f'data: {json.dumps({"type": "response.completed", "response": {"id": "resp_test", "object": "response", "status": "completed", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}], "model": model, "usage": {"input_tokens": 10, "output_tokens": 5}}})}',
        "data: [DONE]",
    ]


def openai_function_call(call_id: str, name: str, arguments_dict: dict, model: str = "test-model") -> list[str]:
    args_json = json.dumps(arguments_dict)
    response_obj = {
        "id": "resp_test",
        "object": "response",
        "status": "in_progress",
        "output": [],
        "model": model,
    }
    return [
        f'data: {json.dumps({"type": "response.created", "response": response_obj})}',
        f'data: {json.dumps({"type": "response.in_progress", "response": response_obj})}',
        f'data: {json.dumps({"type": "response.output_item.added", "output_index": 0, "item": {"type": "function_call", "call_id": call_id, "name": name, "arguments": "", "id": "fc_test", "status": "in_progress"}})}',
        f'data: {json.dumps({"type": "response.function_call_arguments.delta", "output_index": 0, "delta": args_json})}',
        f'data: {json.dumps({"type": "response.output_item.done", "output_index": 0, "item": {"type": "function_call", "call_id": call_id, "name": name, "arguments": args_json, "id": "fc_test", "status": "completed"}})}',
        f'data: {json.dumps({"type": "response.completed", "response": {"id": "resp_test", "object": "response", "status": "completed", "output": [{"type": "function_call", "call_id": call_id, "name": name, "arguments": args_json}], "model": model, "usage": {"input_tokens": 10, "output_tokens": 8}}})}',
        "data: [DONE]",
    ]


def openai_reasoning_then_text(reasoning: str, text: str, model: str = "test-model") -> list[str]:
    response_obj = {
        "id": "resp_test",
        "object": "response",
        "status": "in_progress",
        "output": [],
        "model": model,
    }
    return [
        f'data: {json.dumps({"type": "response.created", "response": response_obj})}',
        f'data: {json.dumps({"type": "response.in_progress", "response": response_obj})}',
        f'data: {json.dumps({"type": "response.output_item.added", "output_index": 0, "item": {"type": "reasoning", "id": "rs_test", "summary": []}})}',
        f'data: {json.dumps({"type": "response.reasoning_summary_text.delta", "output_index": 0, "delta": reasoning})}',
        f'data: {json.dumps({"type": "response.output_item.done", "output_index": 0, "item": {"type": "reasoning", "id": "rs_test", "summary": [{"type": "summary_text", "text": reasoning}]}})}',
        f'data: {json.dumps({"type": "response.output_item.added", "output_index": 1, "item": {"type": "message", "role": "assistant", "content": [], "id": "msg_test", "status": "in_progress"}})}',
        f'data: {json.dumps({"type": "response.output_text.delta", "output_index": 1, "content_index": 0, "delta": text})}',
        f'data: {json.dumps({"type": "response.output_item.done", "output_index": 1, "item": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}], "id": "msg_test", "status": "completed"}})}',
        f'data: {json.dumps({"type": "response.completed", "response": {"id": "resp_test", "object": "response", "status": "completed", "output": [{"type": "reasoning", "id": "rs_test", "summary": [{"type": "summary_text", "text": reasoning}]}, {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}], "model": model, "usage": {"input_tokens": 10, "output_tokens": 15}}})}',
        "data: [DONE]",
    ]


def openai_error(message: str, model: str = "test-model") -> list[str]:
    return [
        f'data: {json.dumps({"type": "response.failed", "response": {"id": "resp_test", "object": "response", "status": "failed", "error": {"type": "server_error", "message": message}, "output": [], "model": model}})}',
        "data: [DONE]",
    ]


async def stream_events(events: list[str]) -> AsyncGenerator[str, None]:
    for event in events:
        yield f"{event}\n\n"
