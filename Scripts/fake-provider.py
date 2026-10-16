# A fake model provider over TLS (its own throwaway CA) for the network profiler, `make recipe-check` and VM proofs
# (617): xAI, the Gemini API, Anthropic's Messages API, OpenAI's Responses and Chat Completions APIs and the two gateways
# (OpenRouter, Vercel AI Gateway: both shapes under their base URLs), each answering DOZ_FAKE_OK (an agent
# that ends a task only through its `respond` tool, Dirac, gets that tool call with DOZ_FAKE_OK; one whose only tool is
# `bash`, mini-swe-agent, gets a bash call that submits DOZ_FAKE_OK) — and Google Stitch's MCP endpoint
# (stitch.googleapis.com/mcp, JSON-RPC over HTTP: initialize, tools/list, tools/call list_projects → one project titled
# DOZ_FAKE_OK; every other tool is refused, so nothing is ever generated). 618: and OpenCode Zen's free models
# (opencode.ai/zen/v1, what OpenCode 2 calls, and the docs' opencode.ai/inference/openai/v1: Chat Completions and
# Responses; its public model list) — KEY-LESS: a request that
# carries any credential but OpenCode's own "public" is refused (401), so a key that leaked there would show.
# Python 3.9+ stdlib only.
# Usage: python3 fake-provider.py LEAF.pem LEAF.key REQUESTS.log PORTFILE   (Scripts/fake-provider-up.sh makes the CA,
#        the leaf and starts it)
# Env: FAKE_XAI_KEY, FAKE_GOOGLE_KEY, FAKE_ANTHROPIC_KEY, FAKE_OPENAI_KEY, FAKE_OPENROUTER_KEY, FAKE_VERCEL_KEY, FAKE_STITCH_KEY — the (fake)
#      real keys the proxy must swap in;
#      anything else is answered in that provider's own refusal shape. FAKE_PORT — a fixed port (default: any).
# A request whose body holds DOZ_SLOW is answered after 6 s (so a status poller, a `doz exec` every ~1 s, sees `working`).
# Every request is one JSON line in REQUESTS.log: method, host, path, the auth headers' names and values, and whether
# the body carried the facts marker. Never a real key.
import http.server, json, os, ssl, sys, time

leaf, key, logf, portf = sys.argv[1:5]
XAI, GOOGLE = os.environ.get("FAKE_XAI_KEY", ""), os.environ.get("FAKE_GOOGLE_KEY", "")
ANTHROPIC, OPENAI = os.environ.get("FAKE_ANTHROPIC_KEY", ""), os.environ.get("FAKE_OPENAI_KEY", "")
STITCH = os.environ.get("FAKE_STITCH_KEY", "")
# 617 (models@1): the gateways — each serves the OpenAI shapes and Anthropic's Messages under its own base URLs, on its
# own key (gateways.json: openrouter.ai/api/v1 + /api, ai-gateway.vercel.sh/v1 + /).
GATEWAYS = {"openrouter.ai": ("/api", os.environ.get("FAKE_OPENROUTER_KEY", "")),
            "ai-gateway.vercel.sh": ("", os.environ.get("FAKE_VERCEL_KEY", ""))}
ANSWER = "DOZ_FAKE_OK"


def tool_call(names, after_tool):
    """618: an agent that ends its task only through a tool gets that call, once — never after a tool result (Dirac's
    `respond` with operation complete; mini-swe-agent, whose only tool is `bash`, a bash call that submits). In every
    API shape: Chat Completions, Responses, Anthropic Messages. None: the answer in words."""
    if after_tool:
        return None
    if "respond" in names:
        return "respond", {"operation": "complete", "text": ANSWER}
    if names == {"bash"}:
        return "bash", {"command": "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT && echo " + ANSWER}
    return None


def responses_call(req):
    names = {t.get("name") or (t.get("function") or {}).get("name") for t in req.get("tools") or []}
    items = req.get("input") if isinstance(req.get("input"), list) else []
    after = bool(items) and isinstance(items[-1], dict) and items[-1].get("type") == "function_call_output"
    return tool_call(names, after)


def anthropic_call(req):
    names = {t.get("name") for t in req.get("tools") or []}
    msgs = req.get("messages") or [{}]
    content = msgs[-1].get("content")
    after = isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content)
    return tool_call(names, after)


def responses_sse(model, text=ANSWER, call=None):
    """OpenAI's Responses API as a stream (xAI's /v1/responses and api.openai.com's)."""
    if call:
        item = {"id": "fc_1", "type": "function_call", "status": "completed", "call_id": "call_doz", "name": call[0],
                "arguments": json.dumps(call[1])}
    else:
        item = {"id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}]}
    done = {"id": "resp_1", "object": "response", "created_at": 0, "status": "completed", "model": model,
            "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                                        "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}}
    started = dict(done, status="in_progress", output=[], usage=None)
    if call:
        evs = [("response.created", {"response": started}),
               ("response.in_progress", {"response": started}),
               ("response.output_item.added", {"output_index": 0, "item": dict(item, status="in_progress", arguments="")}),
               ("response.function_call_arguments.delta", {"item_id": "fc_1", "output_index": 0, "delta": item["arguments"]}),
               ("response.function_call_arguments.done", {"item_id": "fc_1", "output_index": 0, "arguments": item["arguments"]}),
               ("response.output_item.done", {"output_index": 0, "item": item}),
               ("response.completed", {"response": done})]
        out = ""
        for i, (t, d) in enumerate(evs):
            out += "event: " + t + "\ndata: " + json.dumps(dict(d, type=t, sequence_number=i)) + "\n\n"
        return done, out.encode()
    open_item = dict(item, status="in_progress", content=[])
    part = {"type": "output_text", "text": "", "annotations": []}
    evs = [("response.created", {"response": started}),
           ("response.in_progress", {"response": started}),
           ("response.output_item.added", {"output_index": 0, "item": open_item}),
           ("response.content_part.added", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "part": part}),
           ("response.output_text.delta", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": text}),
           ("response.output_text.done", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "text": text}),
           ("response.content_part.done", {"item_id": "msg_1", "output_index": 0, "content_index": 0, "part": item["content"][0]}),
           ("response.output_item.done", {"output_index": 0, "item": item}),
           ("response.completed", {"response": done})]
    out = ""
    for i, (t, d) in enumerate(evs):
        out += "event: " + t + "\ndata: " + json.dumps(dict(d, type=t, sequence_number=i)) + "\n\n"
    return done, out.encode()


def anthropic_message(model, text=ANSWER, call=None):
    """Anthropic's Messages API: the whole message, and the same as a stream."""
    usage = {"input_tokens": 1, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
    if call:
        block = {"type": "tool_use", "id": "toolu_doz", "name": call[0], "input": call[1]}
        msg = {"id": "msg_fake", "type": "message", "role": "assistant", "model": model, "content": [block],
               "stop_reason": "tool_use", "stop_sequence": None, "usage": usage}
        evs = [("message_start", {"message": dict(msg, content=[], stop_reason=None)}),
               ("content_block_start", {"index": 0, "content_block": dict(block, input={})}),
               ("content_block_delta", {"index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps(call[1])}}),
               ("content_block_stop", {"index": 0}),
               ("message_delta", {"delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
               ("message_stop", {})]
        return msg, "".join("event: %s\ndata: %s\n\n" % (t, json.dumps(dict(d, type=t))) for t, d in evs).encode()
    msg = {"id": "msg_fake", "type": "message", "role": "assistant", "model": model,
           "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None, "usage": usage}
    start = dict(msg, content=[], stop_reason=None)
    evs = [("message_start", {"message": start}),
           ("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}}),
           ("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text}}),
           ("content_block_stop", {"index": 0}),
           ("message_delta", {"delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
           ("message_stop", {})]
    out = "".join("event: %s\ndata: %s\n\n" % (t, json.dumps(dict(d, type=t))) for t, d in evs)
    return msg, out.encode()


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def host(self):
        return (self.headers.get("host") or "").split(":")[0].lower()

    def record(self, body=b""):
        auth = {k.lower(): self.headers[k] for k in self.headers.keys() if k.lower() in ("authorization", "x-goog-api-key", "x-api-key")}
        with open(logf, "a") as f:
            f.write(json.dumps({"t": time.time(), "method": self.command, "path": self.path, "host": self.headers.get("host"), "auth": auth,
                                "upgrade": self.headers.get("upgrade", ""),
                                "facts_in_body": b"Dozer" in body or b"dozer" in body}) + "\n")
        return auth

    def send(self, code, obj, ctype="application/json"):
        b = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)

    def xai_ok(self, auth):
        return bool(XAI) and auth.get("authorization") == "Bearer " + XAI

    def google_ok(self, auth):
        # (the Gemini API's OpenAI-compatible endpoint takes the key as a Bearer token)
        return bool(GOOGLE) and (auth.get("x-goog-api-key") == GOOGLE or auth.get("authorization") == "Bearer " + GOOGLE)

    def anthropic_ok(self, auth):
        return bool(ANTHROPIC) and (auth.get("x-api-key") == ANTHROPIC or auth.get("authorization") == "Bearer " + ANTHROPIC)

    def openai_ok(self, auth):
        return bool(OPENAI) and auth.get("authorization") == "Bearer " + OPENAI

    # ── Anthropic (api.anthropic.com) ─────────────────────────────────────────
    def anthropic(self, auth, body):
        p = self.path.split("?")[0]
        if not self.anthropic_ok(auth):
            return self.send(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
        if self.command == "POST" and p == "/v1/messages/count_tokens":
            return self.send(200, {"input_tokens": 1})
        if self.command == "POST" and p == "/v1/messages":
            req = json.loads(body or b"{}")
            msg, stream = anthropic_message(req.get("model", "claude-fake"), call=anthropic_call(req))
            return self.send(200, stream, "text/event-stream") if req.get("stream") else self.send(200, msg)
        if p.startswith("/v1/models"):
            return self.send(200, {"data": [{"type": "model", "id": "claude-fake", "display_name": "Fake"}], "has_more": False})
        return self.send(404, {"type": "error", "error": {"type": "not_found_error", "message": "not here"}})

    # ── OpenAI (api.openai.com; chatgpt.com is not faked here) ────────────────
    def openai(self, auth, body):
        p = self.path.split("?")[0]
        if p.startswith("/v1/responses") and self.headers.get("upgrade", "").lower() == "websocket":
            return self.send(426, {"error": {"message": "use HTTP"}})
        if not self.openai_ok(auth):
            return self.send(401, {"error": {"message": "Incorrect API key provided", "type": "invalid_request_error", "code": "invalid_api_key"}})
        if p.startswith("/v1/models"):
            return self.send(200, {"object": "list", "data": [{"id": "gpt-fake", "object": "model", "owned_by": "openai"}], "models": []})
        if self.command == "POST" and p.startswith("/v1/responses"):
            req = json.loads(body or b"{}")
            done, stream = responses_sse(req.get("model", "gpt-fake"), call=responses_call(req))
            return self.send(200, stream, "text/event-stream") if req.get("stream") else self.send(200, done)
        if self.command == "POST" and p == "/v1/chat/completions":          # 617: a tool on the OpenAI API
            return self.chat(body)
        return self.send(200, {})

    # ── Google Stitch (stitch.googleapis.com/mcp): MCP's JSON-RPC over HTTP, the key in x-goog-api-key ─────────
    def stitch(self, auth, body):
        p = self.path.split("?")[0]
        if not STITCH or auth.get("x-goog-api-key") != STITCH:
            return self.send(401, {"error": {"code": 401, "message": "API key not valid. Please pass a valid API key.", "status": "UNAUTHENTICATED"}})
        if p != "/mcp":
            return self.send(404, {"error": {"code": 404, "message": "not here", "status": "NOT_FOUND"}})
        if self.command != "POST":                                          # no server-sent stream: the client then only POSTs
            return self.send(405, {"error": {"code": 405, "message": "no stream here", "status": "METHOD_NOT_ALLOWED"}})
        try:
            req = json.loads(body or b"{}")
        except ValueError:
            return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
        if isinstance(req, list) or "id" not in req:                        # a notification (or a batch of them)
            return self.send(202, b"")
        rid, method, params = req.get("id"), req.get("method"), req.get("params") or {}
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
                      "serverInfo": {"name": "doz-fake-stitch", "version": "0"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "list_projects", "description": "Lists projects (the stand-in has one).",
                                 "inputSchema": {"type": "object"}}]}
        elif method == "tools/call" and params.get("name") == "list_projects":
            projects = {"projects": [{"name": "projects/617", "title": ANSWER}]}
            result = {"content": [{"type": "text", "text": json.dumps(projects)}], "structuredContent": projects}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "not served by the stand-in"}], "isError": True}
        else:
            return self.send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})
        return self.send(200, {"jsonrpc": "2.0", "id": rid, "result": result})

    # ── a gateway (openrouter.ai, ai-gateway.vercel.sh): OpenAI shapes + Anthropic Messages, its own key ──────────
    def gateway(self, auth, body):
        prefix, k = GATEWAYS[self.host()]
        p = self.path.split("?")[0]
        if prefix and p.startswith(prefix):
            p = p[len(prefix):]
        if not k or not any(v in (k, "Bearer " + k) for v in auth.values()):
            return self.send(401, {"error": {"message": "No auth credentials found", "code": 401}})
        if p == "/v1/key":                                                  # OpenRouter's key check
            return self.send(200, {"data": {"label": "fake", "usage": 0, "limit": None, "is_free_tier": False}})
        if p.startswith("/v1/models"):
            return self.send(200, {"object": "list", "data": [{"id": "openai/gpt-5.4-mini", "object": "model"},
                                                              {"id": "anthropic/claude-sonnet-4.6", "object": "model"}]})
        if self.command == "POST" and p == "/v1/chat/completions":
            return self.chat(body)
        if self.command == "POST" and p.startswith("/v1/responses"):
            req = json.loads(body or b"{}")
            done, stream = responses_sse(req.get("model", "openai/gpt-fake"), call=responses_call(req))
            return self.send(200, stream, "text/event-stream") if req.get("stream") else self.send(200, done)
        if self.command == "POST" and p == "/v1/messages/count_tokens":
            return self.send(200, {"input_tokens": 1})
        if self.command == "POST" and p == "/v1/messages":
            req = json.loads(body or b"{}")
            msg, stream = anthropic_message(req.get("model", "anthropic/claude-fake"), call=anthropic_call(req))
            return self.send(200, stream, "text/event-stream") if req.get("stream") else self.send(200, msg)
        return self.send(404, {"error": {"message": "not here", "code": 404}})

    # ── 618: OpenCode Zen's free models (opencode.ai), no key ────────────────────────────────────────────────────────
    def zen(self, auth, body):
        p = self.path.split("?")[0]
        if any(v not in ("Bearer public", "public") for v in auth.values()):
            return self.send(401, {"error": {"message": "a key-less source got a credential", "code": 401}})
        if self.command == "GET" and p in ("/inference/v1/models", "/zen/v1/models"):
            return self.send(200, {"object": "list", "data": [{"id": "big-pickle", "object": "model", "created": 0, "owned_by": "opencode"}]})
        if self.command == "POST" and p in ("/inference/openai/v1/chat/completions", "/zen/v1/chat/completions"):
            return self.chat(body)
        if self.command == "POST" and p in ("/inference/openai/v1/responses", "/zen/v1/responses"):
            req = json.loads(body or b"{}")
            done, stream = responses_sse(req.get("model", "big-pickle"), call=responses_call(req))
            return self.send(200, stream, "text/event-stream") if req.get("stream") else self.send(200, done)
        return self.send(404, {"error": {"message": "not here", "code": 404}})

    def do_GET(self):
        auth = self.record()
        h = self.host()
        if h == "opencode.ai": return self.zen(auth, b"")
        if h == "api.anthropic.com": return self.anthropic(auth, b"")
        if h == "api.openai.com": return self.openai(auth, b"")
        if h in GATEWAYS: return self.gateway(auth, b"")
        if h == "stitch.googleapis.com": return self.stitch(auth, b"")
        p = self.path.split("?")[0]
        if p == "/v1/models":
            if not self.xai_ok(auth): return self.send(400, {"code": "invalid-argument", "error": "Incorrect API key provided"})
            return self.send(200, {"object": "list", "data": [{"id": "grok-4.6", "object": "model", "owned_by": "xai"}]})
        if p == "/v1/api-key":
            if not self.xai_ok(auth): return self.send(400, {"code": "invalid-argument", "error": "Incorrect API key provided"})
            return self.send(200, {"name": "fake", "api_key_id": "fake-id", "redacted_api_key": "xai-…", "team_id": "t",
                                   "acls": ["api-key:model:*", "api-key:endpoint:*"], "api_key_blocked": False, "api_key_disabled": False, "team_blocked": False})
        if p == "/v1beta/models":
            if not self.google_ok(auth): return self.send(400, {"error": {"code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"}})
            return self.send(200, {"models": [{"name": "models/gemini-fake"}]})
        self.send(404, {"error": "not here"})

    do_HEAD = do_GET

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        auth = self.record(body)
        if b"DOZ_SLOW" in body:
            time.sleep(6)
        h = self.host()
        if h == "opencode.ai": return self.zen(auth, body)
        if h == "api.anthropic.com": return self.anthropic(auth, body)
        if h == "api.openai.com": return self.openai(auth, body)
        if h in GATEWAYS: return self.gateway(auth, body)
        if h == "stitch.googleapis.com": return self.stitch(auth, body)
        p = self.path.split("?")[0]
        if p.endswith("/chat/completions"):
            # 617: the Gemini API's OpenAI-compatible endpoint (/v1beta/openai/…) on Google's host takes the Google key.
            ok = self.google_ok(auth) if h == "generativelanguage.googleapis.com" else self.xai_ok(auth)
            if not ok: return self.send(401, {"error": "the proxy did not swap the key"})
            return self.chat(body)
        if p == "/v1/responses":
            # OpenAI's Responses API (what Grok Build uses against the real api.x.ai).
            if not self.xai_ok(auth): return self.send(401, {"error": "the proxy did not swap the key"})
            req = json.loads(body or b"{}")
            done, stream = responses_sse(req.get("model", "grok-4.6"), call=responses_call(req))
            return self.send(200, stream, "text/event-stream") if req.get("stream") else self.send(200, done)
        return self.gemini(auth, body, p)

    def chat(self, body):
        """OpenAI's Chat Completions (xAI, OpenAI, the Gemini API's compatible endpoint, the gateways)."""
        req = json.loads(body or b"{}")
        # An agent that ends its task only through a tool (Dirac's `respond`, operation complete) gets that call,
        # once — never after a tool result. Every other request: the answer in words.
        names = {(t.get("function") or t).get("name") for t in req.get("tools") or []}
        last = (req.get("messages") or [{}])[-1].get("role")
        tc = tool_call(names, last == "tool")
        call = {"index": 0, "id": "call_doz", "type": "function",
                "function": {"name": tc[0], "arguments": json.dumps(tc[1])}} if tc else None
        if req.get("stream"):
            delta = {"role": "assistant", "content": None, "tool_calls": [call]} if call else {"role": "assistant", "content": ANSWER}
            c = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": "grok-4.6",
                 "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
            out = "data: " + json.dumps(c) + "\n\n"
            c["choices"][0]["delta"] = {}
            c["choices"][0]["finish_reason"] = "tool_calls" if call else "stop"
            c["usage"] = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
            out += "data: " + json.dumps(c) + "\n\ndata: [DONE]\n\n"
            return self.send(200, out.encode(), "text/event-stream")
        return self.send(200, {"id": "x", "object": "chat.completion", "created": 0, "model": "grok-4.6",
                               "choices": [{"index": 0, "message": {"role": "assistant", "content": None if call else ANSWER,
                                                                      **({"tool_calls": [call]} if call else {})},
                                            "finish_reason": "tool_calls" if call else "stop"}],
                               "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})

    def gemini(self, auth, body, p):
        if ":streamGenerateContent" in p or ":generateContent" in p:
            if not self.google_ok(auth): return self.send(400, {"error": {"code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"}})
            if ":streamGenerateContent" in p:
                ev = {"candidates": [{"content": {"role": "model", "parts": [{"text": ANSWER}]}, "finishReason": "STOP", "index": 0}],
                      "usageMetadata": {"promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2}}
                return self.send(200, ("data: " + json.dumps(ev) + "\r\n\r\n").encode(), "text/event-stream")
            # A request for JSON (Gemini CLI's model router) gets its JSON; any other an answer in words.
            gc = (json.loads(body or b"{}").get("generationConfig") or {})
            wants_json = gc.get("responseMimeType") == "application/json" or "responseSchema" in gc or "responseJsonSchema" in gc
            text = "{\"complexity_reasoning\":\"x\",\"complexity_score\":1}" if wants_json else ANSWER
            ev = {"candidates": [{"content": {"role": "model", "parts": [{"text": text}]}, "finishReason": "STOP", "index": 0}],
                  "usageMetadata": {"promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2}}
            return self.send(200, ev)
        self.send(404, {"error": "not here"})

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("FAKE_PORT") or 0)), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(leaf, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(portf, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
