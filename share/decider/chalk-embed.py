#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "sentence-transformers>=3",
# ]
# ///
"""chalk-embed: sentence embeddings for Chalk's semantic lesson recall.

Part of the local decider service that `chalk decider up` starts with
`uv run --script`. It serves, on 127.0.0.1 only:

    POST /v1/embeddings   OpenAI-compatible: {"input": str | [str], "model"?}
                          -> {"object": "list", "model": ..., "data":
                              [{"object": "embedding", "index": i,
                                "embedding": [384 floats, unit length]}]}
    GET  /health          {"status": "ok", "model", "revision",
                           "dimensions", "device"}

The model is BAAI/bge-small-en-v1.5 (MIT), 384 dimensions, which fixes
the `vector(384)` column of Chalk's lessons table. Chalk tracks the
model's latest revision and records the one it resolved, which /health
reports. With HF_HUB_OFFLINE=1, as during `chalk run`, nothing is
downloaded.

    chalk-embed.py --port 8472 [--pidfile FILE]   serve
    chalk-embed.py --download                     fetch the model, print its revision

CHALK_EMBED_FAKE=1 swaps the model for a deterministic stand-in that needs
no download, so tests can check the HTTP contract with any python3.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "BAAI/bge-small-en-v1.5"
DIMENSIONS = 384
# Inputs per request; Chalk sends at most 16.
MAX_INPUTS = 64


class FakeModel:
    """Unit vectors from a hash of the text: equal texts get equal vectors."""

    revision = "fake"
    device = "cpu"

    def encode(self, texts: list[str]) -> list[list[float]]:
        out = []
        for text in texts:
            seed = hashlib.sha256(text.encode("utf-8")).digest()
            raw = [((seed[i % len(seed)] + i) % 251) / 251.0 - 0.5 for i in range(DIMENSIONS)]
            norm = math.sqrt(sum(x * x for x in raw)) or 1.0
            out.append([x / norm for x in raw])
        return out


class RealModel:
    def __init__(self) -> None:
        from huggingface_hub import snapshot_download
        from sentence_transformers import SentenceTransformer

        path = snapshot_download(MODEL)
        # The snapshot directory is named after the commit it resolved.
        self.revision = os.path.basename(path.rstrip("/"))
        self.model = SentenceTransformer(path)
        self.device = str(self.model.device)
        # Renamed in sentence-transformers 5; the old name still works, with a warning.
        dimension = getattr(self.model, "get_embedding_dimension",
                            getattr(self.model, "get_sentence_embedding_dimension", None))()
        if dimension != DIMENSIONS:
            raise SystemExit(f"{MODEL} has {dimension} dimensions, not {DIMENSIONS}")

        # The server answers each request on a thread of its own, and two
        # encodes at once on Apple's GPU abort the process (measured on MPS:
        # four concurrent requests killed it on the first try). Requests take
        # turns; each takes milliseconds.
        self.lock = threading.Lock()

    def encode(self, texts: list[str]) -> list[list[float]]:
        with self.lock:
            vectors = self.model.encode(texts, normalize_embeddings=True, convert_to_numpy=True)
        return [[round(float(x), 6) for x in v] for v in vectors]


def load_model():
    if os.environ.get("CHALK_EMBED_FAKE") == "1":
        return FakeModel()
    return RealModel()


def make_handler(model):
    class Handler(BaseHTTPRequestHandler):
        server_version = "chalk-embed"

        def log_message(self, fmt, *args):  # noqa: D401 - quiet by default
            pass

        def reply(self, code: int, body: dict) -> None:
            data = json.dumps(body).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def error(self, code: int, message: str) -> None:
            self.reply(code, {"error": {"message": message, "type": "invalid_request_error"}})

        def do_GET(self):
            if self.path != "/health":
                return self.error(404, "not found")
            self.reply(200, {"status": "ok", "model": MODEL, "revision": model.revision,
                             "dimensions": DIMENSIONS, "device": model.device})

        def do_POST(self):
            if self.path != "/v1/embeddings":
                return self.error(404, "not found")
            try:
                length = int(self.headers.get("Content-Length") or 0)
                request = json.loads(self.rfile.read(length) or b"null")
            except (ValueError, json.JSONDecodeError):
                return self.error(400, "the body is not JSON")
            if not isinstance(request, dict):
                return self.error(400, "the body must be a JSON object")
            texts = request.get("input")
            if isinstance(texts, str):
                texts = [texts]
            if (not isinstance(texts, list) or not texts or len(texts) > MAX_INPUTS
                    or not all(isinstance(t, str) for t in texts)):
                return self.error(422, f"input must be a string or 1 to {MAX_INPUTS} strings")
            if request.get("model") not in (None, MODEL):
                return self.error(422, f"this service has only {MODEL}")
            vectors = model.encode(texts)
            self.reply(200, {
                "object": "list",
                "model": MODEL,
                "data": [{"object": "embedding", "index": i, "embedding": v}
                         for i, v in enumerate(vectors)],
                "usage": {"prompt_tokens": 0, "total_tokens": 0},
            })

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8472)
    parser.add_argument("--pidfile")
    parser.add_argument("--download", action="store_true",
                        help="download the model, print its revision, and exit")
    args = parser.parse_args()

    model = load_model()
    if args.download:
        print(f"{MODEL} {model.revision} {model.device}")
        return
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(model))
    if args.pidfile:
        with open(args.pidfile, "w", encoding="utf-8") as fh:
            fh.write(f"{os.getpid()}\n")
    print(f"chalk-embed: {MODEL}@{model.revision} on {model.device}, http://127.0.0.1:{args.port}",
          file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
