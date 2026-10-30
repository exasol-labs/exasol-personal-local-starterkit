"""A stand-in for the model endpoint the notebooks' text step talks to: the two OpenAI routes the ``openai`` client
uses, answered from the standard library, no network beyond this machine and no model behind it.

    python3 tests/lib/stub_model_server.py --port 0          # prints the port it chose, serves until killed
    python3 tests/lib/stub_model_server.py --port 8765 --label positive

Routes (the OpenAI shapes, enough for ``client.chat.completions.create`` and ``client.models.list``):

- ``POST /v1/chat/completions`` answers one choice. With ``--label`` the content is always that word; without it the
  content is one of a fixed list of themes, picked by the SHA-256 of the messages, so the same prompt always gets
  the same answer and two runs of a notebook compare equal. ``usage`` carries token counts (the lengths), so a
  tracing client has numbers to record.
- ``GET /v1/models`` lists one model, ``stub``; any model name in a request is accepted and echoed back.
- anything else is 404 with a JSON error in the OpenAI shape.

Used by ``tools/notebooks.py --run`` (through ``tests/notebooks-run.sh``) and by tests: start it, point
``EXAKIT_PROVIDER_BASE_URL`` at ``http://127.0.0.1:<port>/v1`` with any ``EXAKIT_PROVIDER_API_KEY`` and ``EXAKIT_MODEL_ID``, run,
kill it. ``--port 0`` lets the OS choose; the first line on stdout is ``port=<n>`` and is flushed before the server
answers anything, so a caller reads one line and goes on. Logs one line per request to stderr (method, path, status;
never the prompt).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

THEMES = ("trial enrollment", "adverse events", "billing dispute", "loan servicing", "study results",
          "account access", "dosage schedule", "payment delay")


def _answer(messages: list, label: str | None) -> str:
    """What the model says: the fixed label, or a theme chosen by the hash of the messages."""
    if label:
        return label
    digest = hashlib.sha256(json.dumps(messages, sort_keys=True, ensure_ascii=False).encode("utf-8")).digest()
    return THEMES[digest[0] % len(THEMES)]


def completion(request: dict, label: str | None) -> dict:
    """The response body for one chat completion request."""
    messages = request.get("messages") or []
    content = _answer(messages, label)
    prompt_tokens = sum(len(str(m.get("content", "")).split()) for m in messages if isinstance(m, dict))
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.get("model") or "stub",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": len(content.split()),
                  "total_tokens": prompt_tokens + len(content.split())},
    }


def models() -> dict:
    return {"object": "list", "data": [{"id": "stub", "object": "model", "created": 0, "owned_by": "exasol-starter-kit"}]}


def _error(message: str, kind: str = "invalid_request_error") -> dict:
    return {"error": {"message": message, "type": kind, "param": None, "code": None}}


class Handler(BaseHTTPRequestHandler):
    label: str | None = None
    quiet = False

    def _send(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _path(self) -> str:
        return self.path.split("?", 1)[0].rstrip("/")

    def do_GET(self) -> None:  # noqa: N802 - http.server's name
        if self._path() in ("/v1/models", "/models"):
            self._send(200, models())
        else:
            self._send(404, _error(f"no route {self.path}", "not_found_error"))

    def do_POST(self) -> None:  # noqa: N802
        if self._path() not in ("/v1/chat/completions", "/chat/completions"):
            self._send(404, _error(f"no route {self.path}", "not_found_error"))
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            request = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(request, dict):
                raise ValueError("the body is not an object")
        except ValueError as problem:
            self._send(400, _error(f"the request body is not JSON: {problem}"))
            return
        self._send(200, completion(request, self.label))

    def log_message(self, fmt: str, *args) -> None:  # one line per request on stderr, never the prompt
        if not self.quiet:
            sys.stderr.write(f"stub-model-server: {self.command} {self._path()} {args[1] if len(args) > 1 else ''}\n")


def serve(port: int, label: str | None, host: str = "127.0.0.1", quiet: bool = False) -> None:
    Handler.label, Handler.quiet = label, quiet
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"port={server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="A stub OpenAI-compatible model endpoint for the kit's tests.")
    parser.add_argument("--port", type=int, default=0, help="the port to listen on; 0 (the default) lets the OS choose")
    parser.add_argument("--host", default="127.0.0.1", help="the address to bind (default 127.0.0.1)")
    parser.add_argument("--label", default=None, help="answer every completion with this word instead of a hashed theme")
    parser.add_argument("--quiet", action="store_true", help="no request log on stderr")
    args = parser.parse_args(argv)
    serve(args.port, args.label, args.host, args.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
