"""GEM local dev server.

Deliberately avoids os.getcwd() / os.path.abspath() anywhere — the sandboxed
launcher runs with a cwd it may not stat, which makes those raise
PermissionError before the server ever binds.
"""
import functools
import http.server
import socketserver

ROOT = "/Users/ronin/Documents/GEM"
PORT = 8811


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # Serve the app at "/" without needing an index.html on disk.
        clean = path.split("?", 1)[0].split("#", 1)[0]
        if clean in ("/", "/index.html"):
            return ROOT + "/gem-artifact.html"
        return super().translate_path(path)

    def guess_type(self, path):
        ctype = super().guess_type(path)
        # Without an explicit charset the browser falls back to latin-1 and
        # mangles the ·, —, and ✦ glyphs used throughout the UI.
        if ctype in ("text/html", "text/css", "application/javascript", "text/javascript"):
            return ctype + "; charset=utf-8"
        return ctype

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


socketserver.TCPServer.allow_reuse_address = True

if __name__ == "__main__":
    handler = functools.partial(Handler, directory=ROOT)
    with socketserver.TCPServer(("127.0.0.1", PORT), handler) as httpd:
        print("GEM dev server on http://127.0.0.1:%d" % PORT, flush=True)
        httpd.serve_forever()
