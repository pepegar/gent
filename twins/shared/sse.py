import json


def _sse_event(data) -> str:
    return f"data: {json.dumps(data)}"


def _base_response(model: str, status: str = "in_progress", output=None, usage=None, error=None):
    resp = {
        "id": "resp_test",
        "object": "response",
        "status": status,
        "output": output or [],
        "model": model,
    }
    if usage:
        resp["usage"] = usage
    if error:
        resp["error"] = error
    return resp


def openai_text(text: str, model: str = "test-model") -> list[str]:
    events = []
    resp_base = _base_response(model, "in_progress")
    events.append(_sse_event({"type": "response.created", "response": resp_base}))
    events.append(_sse_event({"type": "response.in_progress", "response": resp_base}))
    events.append(_sse_event({
        "type": "response.output_item.added",
        "output_index": 0,
        "item": {
            "type": "message",
            "role": "assistant",
            "content": [],
            "status": "in_progress",
            "id": "msg_test",
        },
    }))
    events.append(_sse_event({
        "type": "response.output_text.delta",
        "output_index": 0,
        "content_index": 0,
        "delta": text,
    }))
    events.append(_sse_event({
        "type": "response.output_item.done",
        "output_index": 0,
        "item": {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text}],
            "status": "completed",
            "id": "msg_test",
        },
    }))
    output_items = [{
        "type": "message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text}],
        "status": "completed",
        "id": "msg_test",
    }]
    usage = {"input_tokens": 100, "output_tokens": len(text)}
    events.append(_sse_event({
        "type": "response.completed",
        "response": _base_response(model, "completed", output=output_items, usage=usage),
    }))
    events.append("data: [DONE]")
    return events


def openai_function_call(call_id: str, name: str, arguments_dict: dict) -> list[str]:
    events = []
    model = "test-model"
    resp_base = _base_response(model, "in_progress")
    events.append(_sse_event({"type": "response.created", "response": resp_base}))
    events.append(_sse_event({"type": "response.in_progress", "response": resp_base}))
    json_str = json.dumps(arguments_dict)
    events.append(_sse_event({
        "type": "response.output_item.added",
        "output_index": 0,
        "item": {
            "type": "function_call",
            "call_id": call_id,
            "name": name,
            "arguments": "",
            "status": "in_progress",
            "id": "fc_test",
        },
    }))
    events.append(_sse_event({
        "type": "response.function_call_arguments.delta",
        "output_index": 0,
        "delta": json_str,
    }))
    events.append(_sse_event({
        "type": "response.output_item.done",
        "output_index": 0,
        "item": {
            "type": "function_call",
            "call_id": call_id,
            "name": name,
            "arguments": json_str,
            "status": "completed",
            "id": "fc_test",
        },
    }))
    output_items = [{
        "type": "function_call",
        "call_id": call_id,
        "name": name,
        "arguments": json_str,
        "status": "completed",
        "id": "fc_test",
    }]
    usage = {"input_tokens": 100, "output_tokens": len(json_str)}
    events.append(_sse_event({
        "type": "response.completed",
        "response": _base_response(model, "completed", output=output_items, usage=usage),
    }))
    events.append("data: [DONE]")
    return events


def openai_reasoning_then_text(reasoning: str, text: str) -> list[str]:
    events = []
    model = "test-model"
    resp_base = _base_response(model, "in_progress")
    events.append(_sse_event({"type": "response.created", "response": resp_base}))
    events.append(_sse_event({"type": "response.in_progress", "response": resp_base}))
    events.append(_sse_event({
        "type": "response.output_item.added",
        "output_index": 0,
        "item": {
            "type": "reasoning",
            "id": "rs_test",
            "summary": [],
            "status": "in_progress",
        },
    }))
    events.append(_sse_event({
        "type": "response.reasoning_summary_text.delta",
        "output_index": 0,
        "summary_index": 0,
        "delta": reasoning,
    }))
    events.append(_sse_event({
        "type": "response.output_item.done",
        "output_index": 0,
        "item": {
            "type": "reasoning",
            "id": "rs_test",
            "summary": [{"type": "summary_text", "text": reasoning}],
            "status": "completed",
        },
    }))
    events.append(_sse_event({
        "type": "response.output_item.added",
        "output_index": 1,
        "item": {
            "type": "message",
            "role": "assistant",
            "content": [],
            "status": "in_progress",
            "id": "msg_test",
        },
    }))
    events.append(_sse_event({
        "type": "response.output_text.delta",
        "output_index": 1,
        "content_index": 0,
        "delta": text,
    }))
    events.append(_sse_event({
        "type": "response.output_item.done",
        "output_index": 1,
        "item": {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text}],
            "status": "completed",
            "id": "msg_test",
        },
    }))
    output_items = [
        {
            "type": "reasoning",
            "id": "rs_test",
            "summary": [{"type": "summary_text", "text": reasoning}],
            "status": "completed",
        },
        {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text}],
            "status": "completed",
            "id": "msg_test",
        },
    ]
    usage = {"input_tokens": 100, "output_tokens": len(text) + len(reasoning)}
    events.append(_sse_event({
        "type": "response.completed",
        "response": _base_response(model, "completed", output=output_items, usage=usage),
    }))
    events.append("data: [DONE]")
    return events


def openai_error(message: str) -> list[str]:
    events = []
    events.append(_sse_event({
        "type": "response.failed",
        "response": {
            "id": "resp_test",
            "object": "response",
            "status": "failed",
            "error": {
                "message": message,
                "type": "server_error",
            },
        },
    }))
    events.append("data: [DONE]")
    return events


def anthropic_text(text: str, model: str = "test-model") -> list[str]:
    events = []
    events.append(f"event: message_start\ndata: {json.dumps({'type': 'message_start', 'message': {'id': 'msg_test', 'type': 'message', 'role': 'assistant', 'content': [], 'model': model, 'stop_reason': None, 'usage': {'input_tokens': 100, 'output_tokens': 0}}})}")
    events.append(f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})}")
    events.append(f"event: content_block_delta\ndata: {json.dumps({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}})}")
    events.append(f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': 0})}")
    events.append(f"event: message_delta\ndata: {json.dumps({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': len(text)}})}")
    events.append(f"event: message_stop\ndata: {json.dumps({'type': 'message_stop'})}")
    return events


def anthropic_error(message: str, error_type: str = "api_error") -> list[str]:
    events = []
    events.append(f"event: error\ndata: {json.dumps({'type': 'error', 'error': {'type': error_type, 'message': message}})}")
    return events


async def stream_events(events: list[str]):
    for event in events:
        yield f"{event}\n\n"
