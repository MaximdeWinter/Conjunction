"""The game's own quests, readable: a quest graph (.w2quest / .w2phase) as text - each block, what it waits for or
does, where it leads - following its phases into other files; and the counts of what a quest is made of.

    python -m conjunction.questread <depot path of a .w2phase / .w2quest> [--stats] [--depth N]

The first step towards building quests at the game's scale, and towards editing the game's quests (a copy made
from one, a scene swapped, a quest hooked into).
"""
import argparse
import collections
import os
import sys

from .cr2w_props import decode

SKIP = {"guid", "cachedConnections", "name"}


def short(cls):
    for p in ("CQuest", "CJournal", "CStoryScene", "C"):
        if cls.startswith(p):
            cls = cls[len(p):]
            break
    return cls.replace("Block", "").replace("Condition", "?")


def _fmt(v, f, depth=0):
    """A value, compact: handles to other objects of the file are followed one level (a condition, a journal
    entry); imports by their file name."""
    if isinstance(v, tuple) and v and v[0] == "import":
        return v[1].rsplit("\\", 1)[-1]
    if isinstance(v, tuple) and v and v[0] == "export":
        if depth > 1 or not (0 < v[1] <= len(f.exports)):
            return f"#{v[1]}"
        cls, _fl, _p, _t, chunk = f.exports[v[1] - 1]
        props = {k: x for k, x in decode(f, chunk).items() if k not in SKIP}
        inner = ", ".join(f"{k}={_fmt(x, f, depth + 1)}" for k, x in props.items() if x not in (None, "", [], {}))
        return f"{short(cls)}({inner})" if inner else short(cls)
    if isinstance(v, list):
        return "[" + ", ".join(_fmt(x, f, depth) for x in v[:8]) + (" ..." if len(v) > 8 else "") + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{k}={_fmt(x, f, depth)}" for k, x in v.items() if x not in (None, "", [], {})) + "}"
    if isinstance(v, bytes):
        return f"<{len(v)} bytes>"
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


class Graph:
    """The blocks of a quest graph (in one file): {export index: (class, props, outs)}, outs: [(socket, target,
    target socket)]."""

    def __init__(self, f, graph_export):
        self.f, self.blocks = f, {}
        props = decode(f, f.exports[graph_export - 1][4])
        for ref in props.get("graphBlocks") or []:
            if not (isinstance(ref, tuple) and ref[0] == "export"):
                continue
            i = ref[1]
            cls, _fl, _p, _t, chunk = f.exports[i - 1]
            bp = decode(f, chunk)
            outs = []
            for c in bp.get("cachedConnections") or []:
                for b in c.get("blocks") or []:
                    t = b.get("ock")
                    if isinstance(t, tuple) and t[0] == "export":
                        outs.append((c.get("socketId") or "Out", t[1], b.get("putName") or "In"))
            self.blocks[i] = (cls, bp, outs)

    def describe(self, i):
        cls, bp, _outs = self.blocks[i]
        name = bp.get("name") or ""
        if cls == "CQuestScriptBlock":
            args = ", ".join(f"{p.get('name')}={_fmt(p.get('value'), self.f)}" for p in bp.get("parameters") or [])
            return f"do {bp.get('functionName')}({args})"
        if cls == "CQuestPauseConditionBlock":
            return f"wait {name!r}: " + " & ".join(_fmt(c, self.f) for c in bp.get("conditions") or [])
        if cls in ("CQuestSceneBlock", "CQuestInteractionDialogBlock"):
            return f"{'scene' if cls == 'CQuestSceneBlock' else 'talk'} {_fmt(bp.get('scene'), self.f)}"
        if cls == "CQuestPhaseBlock":
            inner = bp.get("phase") or bp.get("embeddedGraph")
            return f"phase {name!r} -> {_fmt(inner, self.f, 2)}"
        rest = ", ".join(f"{k}={_fmt(v, self.f)}" for k, v in bp.items() if k not in SKIP and v not in (None, "", [], {}))
        return f"{short(cls)} {name!r} {rest}".rstrip()


def open_graph(depot, path):
    """(Graph of the file's main graph, CR2W) of a .w2phase / .w2quest."""
    from .assets import _cr2w_parts
    f = _cr2w_parts(depot.read(path))[0]
    top = decode(f, f.exports[0][4])
    g = top.get("graph")
    if not (isinstance(g, tuple) and g[0] == "export"):
        g = next((("export", k) for k, e in enumerate(f.exports, 1) if e[0] == "CQuestGraph"), None)
    return Graph(f, g[1]), f


def dump(depot, path, depth=1, out=print, indent="", seen=None):
    """The graph as text; phases in other files followed `depth` levels, embedded ones always."""
    seen = seen if seen is not None else set()
    if path in seen:
        out(f"{indent}(already above: {path})")
        return
    seen.add(path)
    g, f = open_graph(depot, path)
    out(f"{indent}== {path}  ({len(g.blocks)} blocks)")
    _dump_graph(depot, g, f, depth, out, indent, seen)


def _dump_graph(depot, g, f, depth, out, indent, seen):
    for i in sorted(g.blocks):
        cls, bp, outs = g.blocks[i]
        links = "; ".join(f"{s} -> #{t}{'' if ts in ('In', 'Activate') else '.' + ts}" for s, t, ts in outs)
        out(f"{indent}#{i} {g.describe(i)}" + (f"   [{links}]" if links else ""))
        if cls == "CQuestPhaseBlock":
            emb = bp.get("embeddedGraph")
            ph = bp.get("phase")
            if isinstance(emb, tuple) and emb[0] == "export":
                sub = Graph(f, emb[1])
                out(f"{indent}   (inside, {len(sub.blocks)} blocks)")
                _dump_graph(depot, sub, f, depth, out, indent + "   ", seen)
            elif isinstance(ph, tuple) and ph[0] == "import" and depth > 0 and depot.exists(ph[1]):
                dump(depot, ph[1], depth - 1, out, indent + "   ", seen)


def stats(depot, path, counts=None, seen=None, scenes=None, functions=None):
    """What a quest is made of, through all its phases: block classes, scenes, functions, conditions."""
    counts = counts if counts is not None else collections.Counter()
    seen = seen if seen is not None else set()
    scenes = scenes if scenes is not None else set()
    functions = functions if functions is not None else collections.Counter()
    if path in seen or not depot.exists(path):
        return counts, scenes, functions
    seen.add(path)
    g, f = open_graph(depot, path)
    stack = [g]
    while stack:
        gr = stack.pop()
        for _i, (cls, bp, _outs) in gr.blocks.items():
            counts[short(cls)] += 1
            if cls == "CQuestScriptBlock":
                functions[bp.get("functionName")] += 1
            if cls in ("CQuestSceneBlock", "CQuestInteractionDialogBlock"):
                s = bp.get("scene")
                if isinstance(s, tuple):
                    scenes.add(s[1])
            if cls == "CQuestPauseConditionBlock":
                for c in bp.get("conditions") or []:
                    if isinstance(c, tuple) and c[0] == "export":
                        counts["?" + short(f.exports[c[1] - 1][0])] += 1
            if cls == "CQuestPhaseBlock":
                emb, ph = bp.get("embeddedGraph"), bp.get("phase")
                if isinstance(emb, tuple) and emb[0] == "export":
                    stack.append(Graph(f, emb[1]))
                elif isinstance(ph, tuple) and ph[0] == "import":
                    stats(depot, ph[1], counts, seen, scenes, functions)
    counts["phase files"] = len(seen)
    return counts, scenes, functions


class LooseFiles:
    """Files on disk in place of the game's depot (a quest conjunction built)."""

    def read(self, path):
        return open(path, "rb").read()

    def exists(self, path):
        return os.path.isfile(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--depth", type=int, default=1)
    args = ap.parse_args()
    if os.path.isfile(args.path):
        d = LooseFiles()                    # a file on disk (an own build): read as it is
    else:
        from .bundles import Depot
        d = Depot()
    if args.stats:
        counts, scenes, functions = stats(d, args.path)
        print(f"{args.path}: {counts['phase files']} phase files, {len(scenes)} scenes")
        for k, n in counts.most_common():
            print(f"  {n:6}  {k}")
        print("functions:", ", ".join(f"{k} {n}" for k, n in functions.most_common()))
        return
    dump(d, args.path, args.depth)


if __name__ == "__main__":
    sys.exit(main())
