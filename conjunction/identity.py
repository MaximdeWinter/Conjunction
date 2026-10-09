"""Profiles: who made something with Conjunction (Maxim 06.10.). A profile is a display name and a key pair of its own
(ed25519), made at the first start; the key is never shown in Conjunction - it is one file in
Documents\\Conjunction\\identity that its owner keeps, copies to a new PC and never posts. A person may have several
profiles (each its own key, nothing links them); renaming one keeps its key.

    profiles() -> [Profile]           active() -> Profile or None      create(name) -> Profile (made active)
    p.name, p.public (hex), p.path    p.sign(bytes) -> bytes           p.rename(name)
    set_active(p)                     add_file(path) -> Profile (a key file brought from another PC)
    verify(public_hex, message, signature) -> bool
    p.project_seed(uid) -> bytes      what marks this profile's work in a project (see marks.py)
"""
import base64
import datetime
import os
import re

import yaml

from . import config, paths

EXT = ".cjkey"
HEAD = """# Conjunction profile key. This file is you: what you make with Conjunction is signed with it.
# Keep it safe. On a new PC copy it into Documents\\Conjunction\\identity.
# Never post it or send it to anyone: whoever has this file can sign as you.
"""


def folder():
    return getattr(paths, "IDENTITY", os.path.join(paths.HOME, "identity"))


class Profile:
    def __init__(self, path):
        self.path = path
        d = yaml.safe_load(open(path, encoding="utf-8")) or {}
        self.name = str(d.get("name") or "")
        self.created = str(d.get("created") or "")
        self._private = base64.b64decode(d["private"])
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        self._key = Ed25519PrivateKey.from_private_bytes(self._private)
        from cryptography.hazmat.primitives import serialization as S
        self.public = self._key.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw).hex()

    @property
    def id(self):
        return os.path.splitext(os.path.basename(self.path))[0]

    def sign(self, message):
        return self._key.sign(message)

    def project_seed(self, uid):
        """This profile's seed for one project: its signature of the project's uid - only this key makes it, and
        anyone can check it against the public key."""
        return self.sign(b"cj-mark/1|" + str(uid).encode("utf-8"))

    def rename(self, name):
        _write(self.path, name.strip() or self.name, self.created, self._private)
        self.name = name.strip() or self.name

    def __eq__(self, other):
        return isinstance(other, Profile) and other.public == self.public

    def __hash__(self):
        return hash(self.public)


def _write(path, name, created, private):
    body = HEAD + yaml.safe_dump({"name": name, "created": created,
                                  "private": base64.b64encode(private).decode("ascii")},
                                 sort_keys=False, allow_unicode=True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(path + ".tmp", path)


def profiles():
    d = folder()
    out = []
    if os.path.isdir(d):
        for n in sorted(os.listdir(d)):
            if n.lower().endswith(EXT):
                try:
                    out.append(Profile(os.path.join(d, n)))
                except Exception as ex:                 # noqa: BLE001 - a broken file is skipped, not fatal
                    print(f"[identity] {n}: {ex}")
    return out


NONE = "none"                       # (config profile: none - Maxim 08.10.: signing is opt-in, nothing signed then)


def active():
    ps = profiles()
    want = (config.load().get("profile") or "")
    if not ps or want == NONE:
        return None
    return next((p for p in ps if p.id == want), ps[0])


def set_active(p):
    """The profile that signs from now on; None: none (nothing is signed)."""
    cfg = config.load()
    cfg["profile"] = p.id if p is not None else NONE
    config.save(cfg)


def _slug(name):
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")[:24] or "profile"


def create(name):
    from cryptography.hazmat.primitives import serialization as S
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    key = Ed25519PrivateKey.generate()
    raw = key.private_bytes(S.Encoding.Raw, S.PrivateFormat.Raw, S.NoEncryption())
    base = os.path.join(folder(), _slug(name))
    path, n = base + EXT, 2
    while os.path.exists(path):
        path, n = f"{base}_{n}{EXT}", n + 1
    _write(path, name.strip(), datetime.datetime.now().isoformat(timespec="seconds"), raw)
    p = Profile(path)
    set_active(p)
    return p


def add_file(src):
    """A key file from another PC into the identity folder (the same key twice is kept once) -> its Profile."""
    p = Profile(src)
    for q in profiles():
        if q.public == p.public:
            return q
    dst = os.path.join(folder(), os.path.basename(src))
    base, n = os.path.splitext(dst)[0], 2
    while os.path.exists(dst):
        dst, n = f"{base}_{n}{EXT}", n + 1
    os.makedirs(folder(), exist_ok=True)
    with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as g:
        g.write(f.read())
    return Profile(dst)


def verify(public_hex, message, signature):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(public_hex)).verify(signature, message)
        return True
    except (InvalidSignature, ValueError):
        return False
