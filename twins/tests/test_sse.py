import sys
import os
import json
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shared.sse import (
    anthropic_text,
    anthropic_text_chunked,
    anthropic_tool_call,
    anthropic_text_then_tool,
    anthropic_thinking_then_text,
    anthropic_error,
    anthropic_models_page,
    openai_text,
    openai_function_call,
    openai_reasoning_then_text,
    openai_error,
)


def parse_sse_events(lines: list[str]) -> list:
    events = []
    for line in lines:
        if line.startswith("data: "):
            data = line[6:]
            if data == "[DONE]":
                events.append("[DONE]")
            else:
                events.append(json.loads(data))
    return events


class TestAnthropicText:
    def test_event_sequence(self):
        events = parse_sse_events(anthropic_text("Hello world"))
        types = [e if isinstance(e, str) else e["type"] for e in events]
        assert types == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
            "[DONE]",
        ]

    def test_message_start_structure(self):
        events = parse_sse_events(anthropic_text("Hi"))
        msg_start = events[0]
        assert msg_start["type"] == "message_start"
        assert msg_start["message"]["role"] == "assistant"
        assert msg_start["message"]["content"] == []
        assert msg_start["message"]["stop_reason"] is None

    def test_content_block_start(self):
        events = parse_sse_events(anthropic_text("Hi"))
        block_start = events[1]
        assert block_start["index"] == 0
        assert block_start["content_block"]["type"] == "text"

    def test_text_delta(self):
        events = parse_sse_events(anthropic_text("Hello world"))
        delta = events[2]
        assert delta["delta"]["type"] == "text_delta"
        assert delta["delta"]["text"] == "Hello world"

    def test_message_delta_stop_reason(self):
        events = parse_sse_events(anthropic_text("test"))
        msg_delta = events[4]
        assert msg_delta["delta"]["stop_reason"] == "end_turn"

    def test_custom_model(self):
        events = parse_sse_events(anthropic_text("test", model="claude-test"))
        msg_start = events[0]
        assert msg_start["message"]["model"] == "claude-test"


class TestAnthropicTextChunked:
    def test_multiple_deltas(self):
        events = parse_sse_events(anthropic_text_chunked(["Hello", " ", "world"]))
        deltas = [e for e in events if isinstance(e, dict) and e.get("type") == "content_block_delta"]
        assert len(deltas) == 3
        assert deltas[0]["delta"]["text"] == "Hello"
        assert deltas[1]["delta"]["text"] == " "
        assert deltas[2]["delta"]["text"] == "world"


class TestAnthropicToolCall:
    def test_event_sequence(self):
        events = parse_sse_events(anthropic_tool_call("tool_1", "bash", {"command": "ls"}))
        types = [e if isinstance(e, str) else e["type"] for e in events]
        assert types == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
            "[DONE]",
        ]

    def test_tool_use_block_start(self):
        events = parse_sse_events(anthropic_tool_call("tool_1", "bash", {"command": "ls"}))
        block_start = events[1]
        assert block_start["content_block"]["type"] == "tool_use"
        assert block_start["content_block"]["id"] == "tool_1"
        assert block_start["content_block"]["name"] == "bash"

    def test_input_json_delta(self):
        events = parse_sse_events(anthropic_tool_call("tool_1", "bash", {"command": "ls"}))
        delta = events[2]
        assert delta["delta"]["type"] == "input_json_delta"
        parsed = json.loads(delta["delta"]["partial_json"])
        assert parsed == {"command": "ls"}

    def test_stop_reason_tool_use(self):
        events = parse_sse_events(anthropic_tool_call("tool_1", "bash", {}))
        msg_delta = events[4]
        assert msg_delta["delta"]["stop_reason"] == "tool_use"


class TestAnthropicTextThenTool:
    def test_two_content_blocks(self):
        events = parse_sse_events(
            anthropic_text_then_tool("thinking...", "tool_1", "bash", {"command": "ls"})
        )
        block_starts = [e for e in events if isinstance(e, dict) and e.get("type") == "content_block_start"]
        assert len(block_starts) == 2
        assert block_starts[0]["index"] == 0
        assert block_starts[0]["content_block"]["type"] == "text"
        assert block_starts[1]["index"] == 1
        assert block_starts[1]["content_block"]["type"] == "tool_use"


class TestAnthropicThinkingThenText:
    def test_event_sequence(self):
        events = parse_sse_events(anthropic_thinking_then_text("let me think", "answer"))
        types = [e if isinstance(e, str) else e["type"] for e in events]
        assert types == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
            "[DONE]",
        ]

    def test_thinking_block(self):
        events = parse_sse_events(anthropic_thinking_then_text("let me think", "answer"))
        block_start = events[1]
        assert block_start["content_block"]["type"] == "thinking"
        thinking_delta = events[2]
        assert thinking_delta["delta"]["type"] == "thinking_delta"
        assert thinking_delta["delta"]["thinking"] == "let me think"

    def test_signature_delta(self):
        events = parse_sse_events(anthropic_thinking_then_text("think", "answer"))
        sig_delta = events[3]
        assert sig_delta["delta"]["type"] == "signature_delta"
        assert "sig_test" in sig_delta["delta"]["signature"]

    def test_text_block_follows_thinking(self):
        events = parse_sse_events(anthropic_thinking_then_text("think", "the answer"))
        text_block_start = events[5]
        assert text_block_start["index"] == 1
        assert text_block_start["content_block"]["type"] == "text"
        text_delta = events[6]
        assert text_delta["delta"]["text"] == "the answer"


class TestAnthropicError:
    def test_error_event(self):
        events = parse_sse_events(anthropic_error("rate limit exceeded", "rate_limit_error"))
        assert len(events) == 2
        assert events[0]["type"] == "error"
        assert events[0]["error"]["type"] == "rate_limit_error"
        assert events[0]["error"]["message"] == "rate limit exceeded"
        assert events[1] == "[DONE]"


class TestAnthropicModelsPage:
    def test_structure(self):
        models = [{"id": "m1"}, {"id": "m2"}]
        page = anthropic_models_page(models)
        assert page["data"] == models
        assert page["has_more"] is False
        assert page["first_id"] == "m1"
        assert page["last_id"] == "m2"

    def test_has_more(self):
        models = [{"id": "m1"}]
        page = anthropic_models_page(models, has_more=True, last_id="m1")
        assert page["has_more"] is True


class TestOpenaiText:
    def test_event_sequence(self):
        events = parse_sse_events(openai_text("Hello world"))
        types = [e if isinstance(e, str) else e["type"] for e in events]
        assert types == [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.output_text.delta",
            "response.output_item.done",
            "response.completed",
            "[DONE]",
        ]

    def test_response_created_structure(self):
        events = parse_sse_events(openai_text("test"))
        created = events[0]
        assert created["type"] == "response.created"
        assert created["response"]["id"] == "resp_test"
        assert created["response"]["status"] == "in_progress"
        assert created["response"]["output"] == []

    def test_text_delta(self):
        events = parse_sse_events(openai_text("Hello world"))
        delta_event = events[3]
        assert delta_event["type"] == "response.output_text.delta"
        assert delta_event["delta"] == "Hello world"

    def test_output_item_done(self):
        events = parse_sse_events(openai_text("Hello world"))
        done = events[4]
        assert done["item"]["type"] == "message"
        assert done["item"]["content"][0]["type"] == "output_text"
        assert done["item"]["content"][0]["text"] == "Hello world"

    def test_response_completed(self):
        events = parse_sse_events(openai_text("test"))
        completed = events[5]
        assert completed["response"]["status"] == "completed"
        assert "usage" in completed["response"]


class TestOpenaiFunctionCall:
    def test_event_sequence(self):
        events = parse_sse_events(openai_function_call("call_1", "bash", {"command": "ls"}))
        types = [e if isinstance(e, str) else e["type"] for e in events]
        assert types == [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.function_call_arguments.delta",
            "response.output_item.done",
            "response.completed",
            "[DONE]",
        ]

    def test_function_call_added(self):
        events = parse_sse_events(openai_function_call("call_1", "bash", {"command": "ls"}))
        added = events[2]
        assert added["item"]["type"] == "function_call"
        assert added["item"]["call_id"] == "call_1"
        assert added["item"]["name"] == "bash"

    def test_arguments_delta(self):
        events = parse_sse_events(openai_function_call("call_1", "bash", {"command": "ls"}))
        delta = events[3]
        assert delta["type"] == "response.function_call_arguments.delta"
        parsed = json.loads(delta["delta"])
        assert parsed == {"command": "ls"}

    def test_output_item_done(self):
        events = parse_sse_events(openai_function_call("call_1", "bash", {"command": "ls"}))
        done = events[4]
        assert done["item"]["type"] == "function_call"
        assert done["item"]["call_id"] == "call_1"
        assert done["item"]["name"] == "bash"
        parsed_args = json.loads(done["item"]["arguments"])
        assert parsed_args == {"command": "ls"}


class TestOpenaiReasoningThenText:
    def test_event_sequence(self):
        events = parse_sse_events(openai_reasoning_then_text("thinking...", "answer"))
        types = [e if isinstance(e, str) else e["type"] for e in events]
        assert types == [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.reasoning_summary_text.delta",
            "response.output_item.done",
            "response.output_item.added",
            "response.output_text.delta",
            "response.output_item.done",
            "response.completed",
            "[DONE]",
        ]

    def test_reasoning_item(self):
        events = parse_sse_events(openai_reasoning_then_text("thinking...", "answer"))
        reasoning_added = events[2]
        assert reasoning_added["item"]["type"] == "reasoning"

    def test_reasoning_delta(self):
        events = parse_sse_events(openai_reasoning_then_text("thinking...", "answer"))
        reasoning_delta = events[3]
        assert reasoning_delta["type"] == "response.reasoning_summary_text.delta"
        assert reasoning_delta["delta"] == "thinking..."

    def test_text_follows_reasoning(self):
        events = parse_sse_events(openai_reasoning_then_text("thinking...", "the answer"))
        text_added = events[5]
        assert text_added["item"]["type"] == "message"
        text_delta = events[6]
        assert text_delta["delta"] == "the answer"


class TestOpenaiError:
    def test_error_event(self):
        events = parse_sse_events(openai_error("something went wrong"))
        assert len(events) == 2
        failed = events[0]
        assert failed["type"] == "response.failed"
        assert failed["response"]["status"] == "failed"
        assert failed["response"]["error"]["message"] == "something went wrong"
        assert events[1] == "[DONE]"
