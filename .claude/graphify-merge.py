"""Bring graphify-out/graph.json up to date with the commits since it was built.

`graphify update` rebuilds the graph from the AST pass alone and drops most of
its LLM-extracted nodes (see "graphify" in CLAUDE.md). This script re-extracts
only the code files changed since the graph's built_at_commit, merges them in
with build_merge(dedup=False), prunes deleted files, and keeps everything else.
Of a changed file's old nodes and edges it replaces only what the AST pass made
from the file's old version, so the LLM-extracted and hand-derived ones stay;
the summary lists them, since they may describe the old version. It refuses to
write if any other node would be lost.

Docs and other files the AST pass can't read are not re-extracted: the summary
lists them for a semantic pass by hand or with /graphify --update.

Run it from the repo with graphify's interpreter, then review and commit:
    ~/.local/share/uv/tools/graphifyy/bin/python .claude/graphify-merge.py [BASE]
BASE defaults to the graph's built_at_commit.
"""
import collections
import json
import os
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path

import networkx as nx
from graphify.build import build_merge
from graphify.detect import detect
from graphify.export import to_json
from graphify.extract import extract


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def edge_key(e):
    return (e["source"], e["target"], e["relation"])


def graph_edge_keys(u, v, d):
    # build_merge keeps an undirected edge's true endpoints in _src/_tgt.
    src, tgt = d.get("_src", u), d.get("_tgt", v)
    rel = d.get("relation")
    return {(src, tgt, rel), (tgt, src, rel)}


def ast_output(paths, tree):
    """Node ids and edge keys the AST pass makes from these files under tree."""
    if not paths:
        return set(), set()
    # graphify warns that a second cache root in one process loses a speed-up.
    warnings.filterwarnings("ignore", message="stat index switched")
    r = extract([tree / p for p in paths], cache_root=tree)
    return {n["id"] for n in r["nodes"]}, {edge_key(e) for e in r["edges"]}


root = Path(git("rev-parse", "--show-toplevel").decode().strip())
os.chdir(root)
graph_path = root / "graphify-out" / "graph.json"
old = json.loads(graph_path.read_text(encoding="utf-8"))
base = sys.argv[1] if len(sys.argv) > 1 else old["built_at_commit"]
head = git("rev-parse", "HEAD").decode().strip()

fields = git("diff", "--name-status", "--no-renames", "-z", base, head).decode().split("\0")
changes = [(s, p) for s, p in zip(fields[0::2], fields[1::2]) if not p.startswith("graphify-out/")]
deleted = [p for s, p in changes if s == "D"]
present = [p for s, p in changes if s != "D"]
if not changes:
    sys.exit(f"Nothing changed between {base[:7]} and {head[:7]}.")
if present and subprocess.run(["git", "diff", "--quiet", "HEAD", "--", *present]).returncode:
    sys.exit("Commit or stash the changes to these files first: the graph must match HEAD.")

corpus = set(detect(root)["files"]["code"])
code = [p for p in present if str(root / p) in corpus]
other = [p for p in present if p not in code]
modified = {p for s, p in changes if s != "A" and p in code}

new = extract([root / p for p in code], cache_root=root) if code else {"nodes": [], "edges": []}
with tempfile.TemporaryDirectory() as tmp:
    tree = Path(tmp)
    for p in modified:
        (tree / p).parent.mkdir(parents=True, exist_ok=True)
        (tree / p).write_bytes(git("show", f"{base}:{p}"))
    old_ast_nodes, old_ast_edges = ast_output(sorted(modified), tree)

G = build_merge(
    [new],
    graph_path=graph_path,
    prune_sources=deleted or None,
    dedup=False,
    root=root,
    ast_sources=[str(root / p) for p in code],
)

# build_merge replaces every AST-tier item of a re-extracted file, and many of
# this graph's LLM nodes are stamped _origin "ast". Put back what the AST pass
# did not make from the file's old version.
gone = set(deleted)
kept_nodes = []
for n in old["nodes"]:
    if n["id"] in G or n.get("source_file") not in modified or n["id"] in old_ast_nodes:
        continue
    G.add_node(n["id"], **{k: v for k, v in n.items() if k != "id"})
    kept_nodes.append(n)

lost = [
    n for n in old["nodes"]
    if n["id"] not in G and n.get("source_file") not in gone
    and not (n.get("source_file") in modified and n["id"] in old_ast_nodes)
]
if lost:
    for n in lost:
        print(f"  would lose {n['id']} ({n.get('source_file')})")
    sys.exit(f"Refusing to write: {len(lost)} node(s) of unchanged files would be lost.")

# An old edge goes only with a deleted file, a removed endpoint, or as the AST
# output of a re-extracted file; the graph holds one edge per node pair.
have = set()
for u, v, d in G.edges(data=True):
    have |= graph_edge_keys(u, v, d)
kept_edges = displaced = 0
for e in old["links"]:
    k = edge_key(e)
    if k in have or e.get("source_file") in gone or e["source"] not in G or e["target"] not in G:
        continue
    if e.get("source_file") in modified and k in old_ast_edges:
        continue
    if G.has_edge(e["source"], e["target"]):
        displaced += 1
        continue
    attrs = {k2: v for k2, v in e.items() if k2 not in ("source", "target")}
    G.add_edge(e["source"], e["target"], **attrs, _src=e["source"], _tgt=e["target"])
    kept_edges += 1

# A hyperedge that lost members to the replace above gets its old members back.
fresh_hyper = {h.get("id") for h in new.get("hyperedges", [])}
restore = {
    h["id"]: h for h in old.get("hyperedges", [])
    if h.get("id") not in fresh_hyper and h.get("source_file") not in gone
    and all(m in G for m in h.get("nodes", []))
}
hyper = [h for h in G.graph.get("hyperedges", []) if h.get("id") not in restore]
G.graph["hyperedges"] = hyper + list(restore.values())

# Loading the graph stamps a guessed _origin on items that had none; drop it
# again so untouched items stay as they were.
unstamped_nodes = {n["id"] for n in old["nodes"] if "_origin" not in n}
unstamped_edges = {edge_key(e) for e in old["links"] if "_origin" not in e}
for i in unstamped_nodes & set(G.nodes):
    G.nodes[i].pop("_origin", None)
for u, v, d in G.edges(data=True):
    if graph_edge_keys(u, v, d) & unstamped_edges:
        d.pop("_origin", None)

# Keep the saved communities, so the labels stay put. A new node joins the
# community most of its neighbours are in; a new group with no such neighbour
# becomes a community of its own, named after its best-connected node.
saved = {n["id"]: n for n in old["nodes"] if n.get("community") is not None}
community = {n: d["community"] for n, d in G.nodes(data=True) if d.get("community") is not None}
for n in G.nodes:
    if n not in community and n in saved:
        community[n] = saved[n]["community"]
labels = {}
for n in saved.values():
    if n.get("community_name"):
        labels.setdefault(n["community"], n["community_name"])
pending = [n for n in G.nodes if n not in community]
while pending:
    for n in pending:
        near = collections.Counter(community[m] for m in G.neighbors(n) if m in community)
        if near:
            community[n] = near.most_common(1)[0][0]
    placed = [n for n in pending if n in community]
    pending = [n for n in pending if n not in community]
    if not placed:
        break
next_id = max(community.values(), default=-1) + 1
for group in nx.connected_components(G.subgraph(pending).to_undirected()):
    hub = max(group, key=G.degree)
    for n in group:
        community[n] = next_id
    labels[next_id] = G.nodes[hub].get("label", hub)
    next_id += 1
communities = collections.defaultdict(list)
for n, c in community.items():
    communities[c].append(n)

if not to_json(G, dict(communities), str(graph_path), force=True, built_at_commit=head, community_labels=labels):
    sys.exit("to_json refused to write the graph.")


def count(g):
    return len(g["nodes"]), len(g["links"]), len(g.get("hyperedges", []))

now = json.loads(graph_path.read_text(encoding="utf-8"))
print(f"graph.json {base[:7]} -> {head[:7]}: nodes, edges, hyperedges {count(old)} -> {count(now)}")
print(f"  re-extracted {len(code)} code file(s), pruned {len(deleted)} deleted file(s)")
if kept_edges:
    print(f"  put back {kept_edges} edge(s) that build_merge dropped")
if displaced:
    print(f"  dropped {displaced} old edge(s) whose node pair now holds a new edge")
if kept_nodes:
    print(f"  kept {len(kept_nodes)} node(s) of changed files that the AST pass did not make; check they still match:")
    for n in kept_nodes:
        print(f"    {n['id']} ({n.get('source_file')})")
derived_dirs = {Path(n["source_file"]).parent for n in old["nodes"] if n.get("_origin") == "derived" and n.get("source_file")}
for p in code:
    if p not in modified and Path(p).parent in derived_dirs:
        print(f"  new package script {p}: add its provisioned_* node and edges by hand, like its siblings")
for p in other:
    print(f"  not re-extracted (no AST pass): {p}")
