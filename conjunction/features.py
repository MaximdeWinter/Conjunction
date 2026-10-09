"""Experimental features (Maxim 05.10., after rmemr's advice: "I will not ship them with the first build"): what
changes the game's own files - the terrain brush (tiles and their collision in a mod) and editing the game's quests
(a game quest's file in the quest graph, a quest put inside a game quest, a game scene or cutscene replaced) - and
Edit Vanilla Objects (06.10.: a moved object of the game snaps back to its height, later to where it stood). Not
tested enough; two mods changing the same file clash, saves made inside a changed quest may not load or not go on.

Off until switched on in Settings > General > Experimental. The release leaves the switch out (IN_RELEASE) - its
users have none of it. While off: the terrain mode and the board's game file options are gone, a game quest opens
in the quest graph read only, and the build refuses a project that would change a game file.

    from . import features
    if features.experimental(): ...
"""
import os
import sys

KEY = "general.experimental"
IN_RELEASE = False          # the first release: the switch is not offered, everything of it off
WARNING = ("Unstable and hardly tested. Turns on:\n"
           "- Terrain editing\n"
           "- Editing the game's quests in the quest graph\n"
           "- Starting a quest inside a game quest\n"
           "- Replacing a game scene or cutscene\n"
           "- Edit Vanilla Objects: moving, turning and removing the game's own objects")


def released():
    """The release build (conjunction.exe)."""
    return bool(getattr(sys, "frozen", False))


def offered():
    """The switch shows in Settings."""
    return IN_RELEASE or not released()


def experimental():
    """Experimental features on (CJ_EXPERIMENTAL=1 for tests)."""
    if os.environ.get("CJ_EXPERIMENTAL") in ("1", "0"):
        return os.environ["CJ_EXPERIMENTAL"] == "1"
    if not offered():
        return False
    from .settings import value
    return bool(value(KEY, False))


class Off(RuntimeError):
    """An experimental feature used while it is switched off."""


def require(what):
    if not experimental():
        raise Off(f"{what} is an experimental feature (Settings > General > Experimental)")
