"""A public timestamp for an export (Maxim 06.10.: proof of who was first). Off unless the user turns it on
(Settings > Profile > Public timestamp on export): then the sha256 of the quest's history - a fingerprint, nothing
else - goes to the OpenTimestamps calendars, which anchor it in Bitcoin within hours. The answer is a standard .ots
proof: with history.json and history.ots anyone can check at opentimestamps.org that the history existed at that
time. Conjunction sends nothing else, and nothing at all with it off.

    on() -> bool / set_on(bool)
    stamp(data) -> .ots bytes          (raises when no calendar answers)
    digest_of(ots) -> bytes            the sha256 the proof is for
"""
import hashlib
import urllib.request

from . import config

KEY = "public_timestamp"
CALENDARS = ("https://a.pool.opentimestamps.org", "https://b.pool.opentimestamps.org",
             "https://a.pool.eternitywall.com")
MAGIC = b"\x00OpenTimestamps\x00\x00Proof\x00\xbf\x89\xe2\xe8\x84\xe8\x92\x94"
SHA256 = b"\x08"


def on():
    return bool(config.load().get(KEY))


def set_on(value):
    cfg = config.load()
    cfg[KEY] = bool(value)
    config.save(cfg)


def stamp(data, timeout=15):
    """The .ots proof for `data` from every calendar that answers (one is enough)."""
    d = hashlib.sha256(data).digest()
    answers = []
    for cal in CALENDARS:
        try:
            req = urllib.request.Request(cal + "/digest", data=d, headers={
                "Accept": "application/vnd.opentimestamps.v1", "User-Agent": "Conjunction"})
            answers.append(urllib.request.urlopen(req, timeout=timeout).read())
        except Exception:                               # noqa: BLE001 - another calendar may answer
            continue
    if not answers:
        raise RuntimeError("no timestamp calendar answered (offline?)")
    # a detached timestamp: header, version 1, the file's sha256, then each calendar's branch (0xff before all but
    # the last)
    return MAGIC + b"\x01" + SHA256 + d + b"".join(b"\xff" + a for a in answers[:-1]) + answers[-1]


def digest_of(ots):
    if not ots.startswith(MAGIC) or ots[len(MAGIC) + 1:len(MAGIC) + 2] != SHA256:
        return None
    return ots[len(MAGIC) + 2:len(MAGIC) + 34]
