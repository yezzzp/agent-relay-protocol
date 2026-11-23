"""Static fixture server that logs every write request, so a test can prove none happened."""
import http.server
import os
import sys

LOG = os.environ["WRITE_LOG"]


class Handler(http.server.SimpleHTTPRequestHandler):
    def _write(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")
        self.send_response(200)
        self.end_headers()

    do_POST = do_PUT = do_PATCH = do_DELETE = _write

    def log_message(self, *args):
        pass


os.chdir(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
