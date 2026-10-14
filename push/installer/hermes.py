"""Hermes lifecycle adapter; the sender owns encryption, redaction and routing."""

from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import threading
import uuid

_INTERACTIVE = {"cli", "tui", "desktop", "acp"}
_LIMIT = 256
_turns = OrderedDict()
_seen = OrderedDict()
_lock = threading.RLock()
_delivery = ThreadPoolExecutor(max_workers=1, thread_name_prefix="rootshell-push")


def _bounded_put(table, key, value):
    table[key] = value
    table.move_to_end(key)
    while len(table) > _LIMIT:
        table.popitem(last=False)


def _session(kwargs):
    return str(kwargs.get("session_id") or kwargs.get("session_key") or "")


def _turn(kwargs, new=False):
    session = _session(kwargs)
    if not session:
        return None
    # Hermes can reuse task_id across many turns (CLI uses the session ID).
    # Without a real turn_id, pre_llm_call supplies a fresh local occurrence.
    turn_id = str(kwargs.get("turn_id") or "")
    with _lock:
        state = _turns.get(session)
        if new or state is None or (turn_id and turn_id != state["event_id"]):
            state = {
                "event_id": turn_id or uuid.uuid4().hex,
                "platform": kwargs.get("platform") or "",
                "cwd": os.getcwd(),
                "text": "",
            }
            _bounded_put(_turns, session, state)
        elif kwargs.get("platform"):
            state["platform"] = kwargs["platform"]
        return dict(state)


def _deliver(payload, env):
    try:
        subprocess.run(
            ["rootshell-notify", "hook", "--agent", "hermes"],
            input=json.dumps(payload), text=True, env=env, timeout=30,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def _send(event, session, event_id, cwd, **extra):
    if not session or not event_id:
        return
    key = (event, session, event_id)
    with _lock:
        if key in _seen:
            return
        _bounded_put(_seen, key, True)
    payload = {
        "hook_event_name": event, "session_id": session,
        "event_id": event_id, "cwd": cwd, **extra,
    }
    # Callbacks must return promptly, but normal one-shot Python exit must
    # drain notifications. The executor provides both without detached jobs.
    env = dict(os.environ)
    try:
        _delivery.submit(_deliver, payload, env)
    except RuntimeError:
        _deliver(payload, env)


def on_pre_llm_call(**kwargs):
    _turn(kwargs, new=True)


def on_post_llm_call(assistant_response="", **kwargs):
    state = _turn(kwargs)
    if state is not None:
        with _lock:
            current = _turns.get(_session(kwargs))
            if current and current["event_id"] == state["event_id"]:
                current["text"] = str(assistant_response or "")[:4096]


def on_session_end(completed=None, failed=False, interrupted=False, **kwargs):
    state = _turn(kwargs)
    if state is None:
        return
    if interrupted or (completed is None and not failed):
        with _lock:
            _turns.pop(_session(kwargs), None)
        return
    if state["platform"] not in _INTERACTIVE:
        return
    _send(
        "agent_end", _session(kwargs), state["event_id"], state["cwd"],
        stop_reason="error" if failed or not completed else "stop",
        last_assistant_message=state["text"] or (
            "Hermes task failed." if failed or not completed else "Hermes task completed."
        ),
    )


def on_human_input_request(request_id="", prompt="", **kwargs):
    state = _turn(kwargs)
    if state is None or state["platform"] not in _INTERACTIVE:
        return
    _send(
        "input_required", _session(kwargs), str(request_id or uuid.uuid4().hex),
        state["cwd"], message=str(prompt or "Hermes is waiting for your input.")[:4096],
    )


def on_pre_approval_request(surface="", command="", description="", **kwargs):
    # Smart approval is an automated decision, not a human blocker.
    if surface not in _INTERACTIVE:
        return
    on_human_input_request(
        prompt=description or command or "Hermes needs permission.",
        **{**kwargs, "platform": surface},
    )


def register(ctx):
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_hook("on_session_end", on_session_end)
    # Newer Hermes versions provide a single observer for actual human waits.
    # Older versions expose a human approval observer but no authoritative
    # observer for clarify questions; guessing from pre-tool calls is unsafe.
    from hermes_cli.plugins import VALID_HOOKS
    if "on_human_input_request" in VALID_HOOKS:
        ctx.register_hook("on_human_input_request", on_human_input_request)
    else:
        ctx.register_hook("pre_approval_request", on_pre_approval_request)
