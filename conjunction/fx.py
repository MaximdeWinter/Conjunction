"""The effects a template can play (its CFXDefinition names: 'teleport', 'fire', 'activate' ...) - the Effect step and
the portal choose from them instead of a typed name (Maxim 01.10.: stress test with Keira's portal)."""
_cache = {}


def effects_of(template):
    """The names of the effects the template defines (its includes too), [] when it has none / is unknown."""
    key = (template or "").lower()
    if not key:
        return []
    if key not in _cache:
        names = []
        try:
            from .assets import _cr2w_parts
            from .bundles import Depot
            from .cr2w_props import decode
            depot = _depot()
            seen, todo = set(), [key]
            while todo:
                t = todo.pop()
                if t in seen or not depot.exists(t):
                    continue
                seen.add(t)
                for f in _cr2w_parts(depot.read(t)):
                    for cls, _fl, _pa, _tm, chunk in f.exports:
                        if cls == "CFXDefinition":
                            n = decode(f, chunk).get("name")
                            if n and n not in names:
                                names.append(str(n))
                    todo += [imp[0].lower() for imp in f.imports if imp[0].lower().endswith(".w2ent")]
            _ = Depot
        except Exception:                           # noqa: BLE001 - no game files: nothing to offer
            names = []
        _cache[key] = names
    return _cache[key]


_DEPOT = None


def _depot():
    global _DEPOT
    if _DEPOT is None:
        from .bundles import Depot
        _DEPOT = Depot()
    return _DEPOT
