#!/usr/bin/env python3
"""Use ATIMA from a script, through its MCP endpoint.

The script lists the projects you can open, runs a statistical test on one
of them, and saves a figure with its caption and the R code that makes it.
It needs Python 3.8 or later and nothing outside Python's standard library.

    python atima_mcp.py
    python atima_mcp.py --url http://127.0.0.1:8080/mcp --project hmp50 --field "Body Site"

ATIMA must be running on this computer: start it in R with `atima::run()`,
which prints the endpoint's address ("AI apps can connect to ..."). An ATIMA
on your own computer has no accounts, so nothing has to be signed in to. A
shared server lets in only apps that a person has signed in and approved,
which this script does not do; use an AI app there (see the article
"Connecting an AI app": https://cmmr.github.io/atima/articles/ai-apps.html).

ATIMA's endpoint speaks the Model Context Protocol (MCP), revision
2026-07-28: every request is one JSON-RPC message in a POST, which says in
its `_meta` and in three headers which revision it speaks, what it asks for
and, for a tool call, which tool. `tools/list` gives every tool with a
description of its arguments; `describe_function` gives the arguments of an
rbiom function. Change the calls in `main()` to ask other questions.
"""

import argparse
import base64
import json
import sys
import urllib.error
import urllib.request

PROTOCOL = "2026-07-28"
META = "io.modelcontextprotocol/"


class AtimaError(Exception):
    """A request that failed, or a tool that could not do what was asked."""


class Atima:
    """A connection to ATIMA's MCP endpoint. Nothing is kept between requests."""

    def __init__(self, url, timeout=600):
        self.url = url
        self.timeout = timeout
        self.last_id = 0

    def request(self, method, params=None, tool=None):
        """Send one JSON-RPC request and return its result."""
        self.last_id += 1
        params = dict(params or {})
        params["_meta"] = {
            META + "protocolVersion": PROTOCOL,
            META + "clientCapabilities": {},
            META + "clientInfo": {"name": "atima-example-script", "version": "1.0"},
        }
        body = json.dumps({"jsonrpc": "2.0", "id": self.last_id, "method": method, "params": params})
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "MCP-Protocol-Version": PROTOCOL,
            "Mcp-Method": method,
        }
        if tool is not None:
            headers["Mcp-Name"] = tool
        req = urllib.request.Request(self.url, data=body.encode("utf-8"), headers=headers, method="POST")

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                reply = json.load(resp)
        except urllib.error.HTTPError as e:
            # A request the server refused still has a JSON-RPC error in its body.
            try:
                reply = json.load(e)
            except ValueError:
                reply = {}
            if "error" not in reply:
                if e.code == 401:
                    raise AtimaError("This server needs a sign-in, which this script does not do. Use it with an ATIMA on your own computer.") from None
                raise AtimaError("The server answered HTTP {}.".format(e.code)) from None
        except urllib.error.URLError as e:
            raise AtimaError("Could not reach {} ({}). Is ATIMA running?".format(self.url, e.reason)) from None

        if "error" in reply:
            raise AtimaError("{}: {}".format(method, reply["error"].get("message")))
        return reply["result"]

    def call(self, tool, **arguments):
        """Call a tool. Returns its result: `structuredContent` and `content`."""
        result = self.request("tools/call", {"name": tool, "arguments": arguments}, tool=tool)
        if result.get("isError"):
            text = " ".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
            raise AtimaError("{}: {}".format(tool, text))
        return result


def print_table(data, max_rows=10):
    """Print a table from run_stats or make_plot: `columns` and `rows`."""
    columns, rows = data["columns"], data["rows"][:max_rows]
    cells = [[("" if v is None else str(v)) for v in row] for row in rows]
    widths = [max([len(c)] + [len(r[i]) for r in cells]) for i, c in enumerate(columns)]
    print("  " + "  ".join(c.ljust(w) for c, w in zip(columns, widths)))
    for r in cells:
        print("  " + "  ".join(v.ljust(w) for v, w in zip(r, widths)))
    if data.get("note"):
        print("  " + data["note"])


def main():
    parser = argparse.ArgumentParser(description="List projects, run a test and save a figure, through ATIMA's MCP endpoint.")
    parser.add_argument("--url", default="http://127.0.0.1:8080/mcp", help="the endpoint (default: %(default)s)")
    parser.add_argument("--project", help="a project's key (default: the first one listed)")
    parser.add_argument("--field", help="a categorical metadata field to compare groups by (default: the first that suits)")
    parser.add_argument("--out", default="ordination.png", help="where to save the figure (default: %(default)s)")
    opts = parser.parse_args()

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")

    atima = Atima(opts.url)

    # Which server this is, and which tools it offers.
    found = atima.request("server/discover")
    server = found.get("_meta", {}).get(META + "serverInfo", {})
    print("Connected to {} {}.".format(server.get("title", "ATIMA"), server.get("version", "")))
    tools = [t["name"] for t in atima.request("tools/list")["tools"]]
    print("Tools: " + ", ".join(tools) + "\n")

    # 1. The projects.
    projects = atima.call("list_projects")["structuredContent"]["projects"]
    if not projects:
        sys.exit("No project to open. Upload one in the browser first.")
    print("Projects:")
    for p in projects:
        print("  {:<12} {} ({} samples, {} taxa)".format(p["project"], p["title"], p["samples"], p["taxa"]))

    project = opts.project or projects[0]["project"]
    about = atima.call("describe_project", project=project)["structuredContent"]
    print("\nUsing '{}', saved at a rarefaction depth of {}.".format(about["title"], about["depth"]["saved"]))

    # A field whose values make groups worth comparing.
    fields = [f for f in about["fields"] if f["class"] == "categorical" and f["name"] != ".sample"]
    if opts.field:
        field = opts.field
    else:
        suits = [f["name"] for f in fields if 2 <= f["n_values"] <= 8]
        if not suits:
            sys.exit("This project has no categorical field with 2 to 8 values. Name one with --field.")
        field = suits[0]
    print("Comparing groups by '{}'.".format(field))

    # 2. A statistical test: Shannon diversity, compared between each pair of groups.
    stats = atima.call("run_stats", project=project, function="adiv_stats", args={"adiv": "shannon", "stat.by": field})
    stats = stats["structuredContent"]
    print("\nShannon diversity by '{}':".format(field))
    model = stats.get("model") or []
    for line in (model.values() if isinstance(model, dict) else model):
        print("  Model: {}".format(line))
    print_table(stats)
    print("  The whole table: " + stats["table_url"])

    # 3. A figure: an ordination of Bray-Curtis distances, with a PERMANOVA.
    plot = atima.call(
        "make_plot", project=project, function="bdiv_ord_plot",
        args={"bdiv": "bray", "ord": "PCoA", "stat.by": field},
        image={"width": 900, "height": 600, "dpi": 100})
    images = [c for c in plot["content"] if c.get("type") == "image"]
    with open(opts.out, "wb") as f:
        f.write(base64.b64decode(images[0]["data"]))
    figure = plot["structuredContent"]
    print("\nSaved the figure as {}.".format(opts.out))
    # The caption says what the figure was made from and how.
    if figure.get("caption"):
        print("Caption: " + " ".join(figure["caption"].split("\n")))
    if figure.get("stats"):
        print("Its statistics:")
        print_table(figure["stats"])
    print("\nThe R code that makes it:\n" + figure["code"]["rbiom"])


if __name__ == "__main__":
    try:
        main()
    except AtimaError as e:
        sys.exit("Error: {}".format(e))
