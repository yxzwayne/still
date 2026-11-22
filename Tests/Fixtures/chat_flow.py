"""Run with an empty fixture directory. Prints STILL_DATA_DIR and serves local SSE."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import time
import uuid


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"fixture"}]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        pieces = [
            {"choices": [{"delta": {"reasoning_content": "Compare the examples."}}]},
            {"choices": [{"delta": {"content": "A sample reply."}}]},
        ]
        if "fail" in body["messages"][-1]["content"].lower():
            pieces.append({"error": {"message": "Fixture failure"}})
        else:
            pieces.append({"choices": [{"delta": {}, "finish_reason": "stop"}]})
        try:
            for piece in pieces:
                time.sleep(1)
                self.wfile.write(("data: " + json.dumps(piece) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


def identifier():
    return str(uuid.uuid4())


def chat(title, route, prompt):
    messages = []
    for role, text in [("user", prompt), ("assistant", SAMPLE)]:
        messages.append(dict(id=identifier(), role=role, text=text, date=0,
                             status="complete", model="Fixture author"))
    return dict(id=identifier(), title=title, messages=messages, draft="", updatedAt=0,
                route=route)


SAMPLE = """# Notes
A **sample** and another sample.

> First quoted line
> Second quoted line

- Start here
  - Read the nested item

| Name | Example |
| --- | --- |
| First | Sample |

```swift
""" + "let example = " + '"lengthy line" + ' * 20 + '""\n```'

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--broken", action="store_true")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    if any(args.directory.iterdir()):
        parser.error("Use an empty fixture directory.")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    chats = [chat("Server example", "compatible", "Answer briefly"),
             chat("Gemma example", "gemma", "Compare examples"),
             chat("Failure example", "compatible", "Fail this attempt")]
    settings = dict(mode="inkling", baseURL=f"http://127.0.0.1:{server.server_port}/v1",
                    model="fixture", displayName="Long compatible server model name for narrow windows",
                    systemPrompt="Answer briefly.")
    state = dict(version=2, settings=settings, conversations=chats, selectedID=chats[0]["id"])
    (args.directory / "chats.json").write_text("broken" if args.broken else json.dumps(state))
    print(f"STILL_DATA_DIR={args.directory.resolve()}", flush=True)
    server.serve_forever()
