"""Every quest carries the runtime's functions it calls (Maxim 08.10.: "jede quest geht ohne die runtime, die runtime
behebt sachen"). The build names each runtime function the quest's files call after the quest (CjGive ->
CjGive_<quest id>) and writes those functions, with everything they call, as the quest's own script
(Mods\\moddlc<id>\\content\\scripts\\local). Two quests never share a name, the runtime's own functions keep theirs,
so any number of quests and the runtime sit side by side. Of the item tables (every item of the game as text ->
its name) only the items the quest names come along.

What only the runtime can do - the fixer's timer, the name over an enemy, anything that adds to the game's classes
(@wrapMethod, @addMethod, @addField) - a quest can not carry: a quest whose files call it is refused here, so no
quest can depend on the runtime unseen.

    script, names = quest_script(qid, texts)      # texts: the quest's definition files as text
    apply(out, qid, script_dir, log)              # the build: the definition files renamed, the script written
"""
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.join(HERE, "..", "mod", "runtime", "scripts")
SCRIPT_NAME = "cj_quest_{qid}.ws"
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
HEAD = re.compile(r"^\s*((?:(?:latent|quest|storyscene|exec|timer|private|public|protected|final|cleanup|entry)\s+)*)"
                  r"function\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
TABLES = ("CjItemName", "CjLootName")       # text -> name: CjItemName0..n, then CjItemName asking each


class RuntimeOnly(Exception):
    """The quest calls something only the runtime can do."""


class Block:
    def __init__(self, kind, name, text, entry=False):
        self.kind, self.name, self.text, self.entry = kind, name, text, entry    # kind: function | annotated
        self.refs = set()


def _skip_space(s, i):
    """Past whitespace and comments."""
    while i < len(s):
        if s[i].isspace():
            i += 1
        elif s.startswith("//", i):
            j = s.find("\n", i)
            i = len(s) if j < 0 else j + 1
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            i = len(s) if j < 0 else j + 2
        else:
            break
    return i


def _block_end(s, i):
    """From the first '{' at or after i to its matching '}' (strings, names and comments skipped) -> index after."""
    i = s.index("{", i)
    depth = 0
    while i < len(s):
        c = s[i]
        if c in "\"'":
            j = i + 1
            while j < len(s) and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        if s.startswith("//", i):
            j = s.find("\n", i)
            i = len(s) if j < 0 else j + 1
            continue
        if s.startswith("/*", i):
            i = s.find("*/", i + 2) + 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced braces")


def parse(text):
    """The top-level definitions of a script file -> [Block]."""
    out, i = [], 0
    while True:
        i = _skip_space(text, i)
        if i >= len(text):
            return out
        start = i
        annotated = text.startswith("@", i)
        if annotated:                               # @wrapMethod(X) / @addMethod(X) / @addField(X) and what follows
            i = _skip_space(text, text.index(")", i) + 1)
        m = HEAD.match(text, i)
        if m:
            end = _block_end(text, m.end())
            kind = "annotated" if annotated else "function"
            entry = not annotated and bool(re.search(r"\b(quest|storyscene)\b", m.group(1) or ""))
            out.append(Block(kind, m.group(2), text[start:end], entry))
            i = end
            continue
        end = text.index(";", i) + 1                # a field (saved var x : T;) or anything else up to its ';'
        name = (re.search(r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)", text[i:end]) or [None, ""])[1]
        out.append(Block("annotated" if annotated else "other", name, text[start:end]))
        i = end


def library_dirs():
    """The runtime's scripts and the runtime scripts of the plug-ins that are on."""
    dirs = [RUNTIME]
    try:
        from . import plugins
        dirs += plugins.manager().scripts(runtime=True)
    except Exception:                               # noqa: BLE001 - plug-ins are extra
        pass
    return [d for d in dirs if os.path.isdir(d)]


def item_script():
    """The item tables as the runtime gets them (setup.install_runtime): made from this game's catalog and its content
    packs when there are any, else the one that comes with Conjunction -> path."""
    from . import assets, content
    try:
        packs = any(content.pack_index(p).get("items") for p in content.installed_packs(config_game()))
    except Exception:                               # noqa: BLE001 - no game folder: no packs
        packs = False
    if assets.Assets.ready() or packs:
        import tempfile
        folder = tempfile.mkdtemp(prefix="cj_items_")
        assets.write_item_script(folder)
        return os.path.join(folder, assets.ITEM_SCRIPT)
    return os.path.join(RUNTIME, "local", assets.ITEM_SCRIPT)


def config_game():
    from . import config
    return config.load().get("game", "")


def library(dirs=None):
    """{name: Block} of every runtime definition, each with the names it uses (functions, fields)."""
    blocks = {}
    files = []
    for d in dirs or library_dirs():
        files += sorted(glob.glob(os.path.join(d, "**", "*.ws"), recursive=True))
    if dirs is None:                                # the item tables of this game (and its packs)
        from .assets import ITEM_SCRIPT
        files = [f for f in files if os.path.basename(f) != ITEM_SCRIPT] + [item_script()]
    for f in files:
        if f:
            text = open(f, encoding="utf-8-sig").read()
            if os.path.basename(os.path.dirname(f)).startswith("cj_items_"):     # (item_script's own folder)
                import shutil
                shutil.rmtree(os.path.dirname(f), ignore_errors=True)
            for b in parse(text):
                if b.name:
                    blocks.setdefault(b.name, b)
    names = set(blocks)
    for b in blocks.values():
        body = b.text[b.text.index("{"):] if "{" in b.text else ""
        b.refs = {w for w in WORD.findall(body) if w in names and w != b.name}
    return blocks


def _runtime_only(name, lib, seen=None):
    """The chain to something only the runtime can do, or None."""
    seen = seen if seen is not None else set()
    if name in seen:
        return None
    seen.add(name)
    b = lib[name]
    if b.kind != "function":
        return [name]
    for r in sorted(b.refs):
        chain = _runtime_only(r, lib, seen)
        if chain:
            return [name] + chain
    return None


def used(texts, lib, sfx=""):
    """The runtime functions the quest's files call (by name, as a whole word; named after the quest already when a
    build ran over the same files before)."""
    words = {w for t in texts for w in WORD.findall(t)}
    words |= {w[:-len(sfx)] for w in words if sfx and w.endswith(sfx)}
    return sorted(n for n in words if n in lib and lib[n].kind == "function")


def closure(names, lib):
    """The functions needed, callers first -> [name]; RuntimeOnly when one needs the runtime."""
    out, todo = [], list(names)
    while todo:
        n = todo.pop(0)
        if n in out:
            continue
        chain = _runtime_only(n, lib)
        if chain:
            raise RuntimeOnly(" -> ".join(chain))
        out.append(n)
        todo += sorted(lib[n].refs - set(out))
    return out


def _table(base, lib, texts, sfx):
    """CjItemName_<id>(s): only the rows whose text the quest's files hold."""
    rows = []
    for name, b in lib.items():
        if re.fullmatch(base + r"\d+", name):
            rows += [ln for ln in b.text.splitlines() if ln.strip().startswith("if (s == ")]
    hay = "\n".join(texts)
    keep = [r for r in rows if (m := re.search(r'"((?:[^"\\]|\\.)*)"', r)) and m.group(1) in hay]
    return (f"function {base}{sfx}(s : string) : name {{\n" + "".join(r + "\n" for r in keep) +
            "    return '';\n}\n")


# what a quest may carry of the runtime's own (08.10.: two quests wrapping the same method compile and chain - checked
# with the game's compiler): {a definition file of the build that asks for it: the annotated block}
FEATURES = {"definition.names.yml": "UpdateName"}       # people with names of their own (conjunction_names.ws)


def quest_script(qid, texts, lib=None, features=()):
    """The quest's own script and the renames -> (script text, {runtime name: the quest's name}). texts: the quest's
    definition files as text; features: annotated blocks it carries too (FEATURES)."""
    lib = lib or library()
    sfx = "_" + qid
    entries = used(texts, lib, sfx)
    feats = [f for f in features if f in lib]
    if not entries and not feats:
        return "", {}
    need = closure(entries + sorted({r for f in feats for r in lib[f].refs}), lib)
    tables = [t for t in TABLES if t in need]
    need = [n for n in need if not any(re.fullmatch(t + r"\d*", n) for t in TABLES)]
    renames = {n: n + sfx for n in need + tables}
    pattern = re.compile(r"\b(" + "|".join(sorted(map(re.escape, renames), key=len, reverse=True)) + r")\b")
    parts = [f"// {qid}: the runtime functions this quest calls, its own copy (built by Conjunction, scriptlib.py)\n"]
    for n in need + feats:                          # (a feature keeps the method's name it wraps: only its calls renamed)
        parts.append(pattern.sub(lambda m: renames[m.group(1)], lib[n].text) + "\n")
    for t in tables:
        parts.append(_table(t, lib, texts, sfx))
    return "\n".join(parts), {n: renames[n] for n in entries}


def definition_files(out):
    """The build's definition files that name script functions (quest, scenes, stand-ins)."""
    files = []
    for d in ("definition.quest", "definition.scenes"):
        files += glob.glob(os.path.join(out, d, "**", "*.yml"), recursive=True)
    files += glob.glob(os.path.join(out, "definition.*.yml"))
    return sorted(set(files))


def apply(out, qid, script_dir, log=print, lib=None):
    """The build's step: the definition files call the quest's own names, its script is written to `script_dir`
    -> the script's path (None: the quest calls nothing of the runtime)."""
    lib = lib or library()
    files = definition_files(out)
    texts = {f: open(f, encoding="utf-8").read() for f in files}
    features = [block for name, block in FEATURES.items()
                if any(os.path.basename(f) == name and (t.strip() not in ("", "{}")) for f, t in texts.items())]
    script, renames = quest_script(qid, list(texts.values()), lib, features)
    for f in os.listdir(script_dir) if os.path.isdir(script_dir) else ():
        if f.startswith("cj_quest_") and f.endswith(".ws"):
            os.remove(os.path.join(script_dir, f))
    if not script:
        return None
    if renames:
        pattern = re.compile(r"\b(" + "|".join(sorted(map(re.escape, renames), key=len, reverse=True)) + r")\b")
        for f, t in texts.items():
            new = pattern.sub(lambda m: renames[m.group(1)], t)
            if new != t:
                open(f, "w", encoding="utf-8", newline="").write(new)
    os.makedirs(script_dir, exist_ok=True)
    path = os.path.join(script_dir, SCRIPT_NAME.format(qid=qid))
    open(path, "w", encoding="utf-8", newline="\n").write(script)
    log(f"[build] {qid}: its own script: {len(renames)} functions called, {script.count(chr(10))} lines")
    return path
