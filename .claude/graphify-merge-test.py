"""Check that graphify-merge.py refuses real losses and lets re-extraction replace
the source-less nodes the AST pass made from a changed file.

Each case builds a throwaway git repo, saves a graph for its first commit, makes
a second commit, and runs the merge script there. Run with graphify's interpreter:
    ~/.local/share/uv/tools/graphifyy/bin/python .claude/graphify-merge-test.py
"""
import json
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path

from graphify.build import build_from_json
from graphify.export import to_json
from graphify.extract import extract

SCRIPT = Path(__file__).with_name("graphify-merge.py")
warnings.filterwarnings("ignore")


def git(repo, *args):
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()


def write(repo, files):
    for name, text in files.items():
        (repo / name).write_text(text)


def build_graph(repo, files, tweak=None):
    """Save the graph of the current commit; tweak(graph_dict) may edit it first."""
    r = extract([repo / f for f in files], cache_root=repo)
    G = build_from_json(r)
    path = repo / "graphify-out" / "graph.json"
    path.parent.mkdir(exist_ok=True)
    to_json(G, {0: list(G.nodes)}, str(path), force=True, built_at_commit=git(repo, "rev-parse", "HEAD"))
    if tweak:
        g = json.loads(path.read_text())
        tweak(g)
        path.write_text(json.dumps(g))


def run_case(first, second, tweak=None):
    """Returns (script exit code, its output, ids in the written graph)."""
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        git(repo, "init", "-q")
        write(repo, first)
        git(repo, "add", ".")
        git(repo, "commit", "-qm", "one")
        build_graph(repo, first, tweak)
        write(repo, second)
        git(repo, "add", ".")
        git(repo, "commit", "-qm", "two")
        p = subprocess.run([sys.executable, str(SCRIPT)], cwd=repo, capture_output=True, text=True)
        ids = {n["id"] for n in json.loads((repo / "graphify-out" / "graph.json").read_text())["nodes"]}
        return p.returncode, p.stdout + p.stderr, ids


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print(detail)
    return ok


results = []

# 1. A.swift alone refers to Double, so the AST pass names the type's placeholder
#    node `double`, with no source file. Once B.swift refers to it too, each file
#    gets its own `<file>_swift_double`, and `double` goes. That is no real loss.
code, out, ids = run_case(
    {"A.swift": "struct A { var x: Double }\n"},
    {"A.swift": "struct A { var x: Double; var y: Int32 }\n", "B.swift": "struct B { var z: Double }\n"},
)
results.append(check("source-less node replaced by re-extraction passes", code == 0 and "double" not in ids, out))

# 2. A source-less code stub that A.swift's old version had an edge to, but that
#    its AST pass did not make: re-extraction drops the edge, build_merge sweeps
#    the stub, and nothing says it was replaced. A real loss.
def add_stub(g):
    a = next(n["id"] for n in g["nodes"] if n.get("source_file") == "A.swift" and n["label"] == "A")
    g["nodes"].append({"id": "stub", "label": "Stub", "file_type": "code", "source_file": "", "community": 0, "_origin": "ast"})
    g["links"].append({
        "source": a, "target": "stub", "relation": "references", "confidence": "INFERRED",
        "source_file": "A.swift", "_origin": "ast",
    })


code, out, ids = run_case(
    {"A.swift": "struct A { var x: Double }\n"},
    {"A.swift": "struct A { var x: Double; var y: Int32 }\n", "B.swift": "struct B { var z: Double }\n"},
    add_stub,
)
results.append(check(
    "source-less node the changed file's AST pass did not make is refused",
    code != 0 and "would lose stub" in out and "Refusing to write" in out and "double" not in out, out,
))

sys.exit(0 if all(results) else 1)
