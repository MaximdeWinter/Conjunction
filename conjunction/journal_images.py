"""The game's journal portraits (the image names of its character pages), read once and kept in Conjunction's folder."""
import json
import os

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "journal_portraits.json")


def portraits():
    """['journal_anabelle.png', ...] - every image the game's character journals use."""
    if os.path.exists(CACHE):
        try:
            return json.load(open(CACHE, encoding="utf-8"))
        except (OSError, ValueError):
            pass
    names = set()
    try:
        from .assets import _cr2w_parts
        from .bundles import Depot
        depot = Depot()
        for p in depot.where:
            if not (p.startswith("gameplay\\journal\\characters\\") and p.endswith(".journal")):
                continue
            try:
                f = _cr2w_parts(depot.read(p))[0]
            except Exception:                           # noqa: BLE001
                continue
            for cls, _fl, _parent, _tmpl, chunk in f.exports:
                if cls != "CJournalCharacter":
                    continue
                for name, tp, off, sz in f.props(chunk):
                    if name == "image" and tp == "String":
                        text = bytes(chunk[off + 1:off + sz]).decode("utf-8", "replace")
                        if text.endswith(".png"):
                            names.add(text)
    except Exception:                                   # noqa: BLE001 - without the game: a default only
        pass
    out = sorted(names) or ["journal_grandma.png"]
    try:
        json.dump(out, open(CACHE, "w", encoding="utf-8"))
    except OSError:
        pass
    return out
