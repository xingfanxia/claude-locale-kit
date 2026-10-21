"""Test-only mitmproxy add-on: send every upstream connection to the local fixture server, so the
end-to-end test never resolves or contacts a real host. Not used by run.sh."""
from mitmproxy import ctx


class FixtureRedirect:
    def load(self, loader):
        loader.add_option("fixture_port", int, 0, "local fixture HTTPS port")

    def server_connect(self, data):
        data.server.address = ("127.0.0.1", ctx.options.fixture_port)


addons = [FixtureRedirect()]
