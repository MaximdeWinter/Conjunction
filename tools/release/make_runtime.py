"""The Conjunction Runtime as a mod of its own (06.10.): the scripts every quest made with Conjunction calls, for
players who install quests without Conjunction (a mod manager, by hand). An optional file on Conjunction's Nexus page
(09.10.), recommended on each quest's page - one runtime in the game, whatever the number of quests.

    python tools/release/make_runtime.py [--out DIR]     -> DIR/Conjunction-Runtime-<n>.zip (+ .sha256)

The zip: Mods/modConjunctionRuntime/content/scripts/local/*.ws (what setup.install_runtime puts in, with the item table
that comes with Conjunction), Mods/modConjunctionRuntime/runtime.txt (its version: Conjunction installs its own copy
only over an older one) and a README.
"""
import argparse
import hashlib
import os
import sys
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, ROOT)
from conjunction import setup  # noqa: E402
from conjunction.packaging import RUNTIME_VERSION  # noqa: E402

README = """Conjunction Runtime {n}

Removes quests made with Conjunction cleanly. Every Conjunction quest runs on its own, the runtime is optional.

A quest can change the game's own world: hide a villager, switch off monsters, make someone hostile or lock a door.
These changes are kept in your save. When you remove the quest (by hand or with a mod manager), the runtime puts them
back as they were, as soon as you come near them.

Install: unpack the zip into the game folder (the one with bin, content, dlc), or use a mod manager. It puts
Mods\\modConjunctionRuntime into the game.

Update: install the new one over it.

Remove: delete Mods\\modConjunctionRuntime.

Made by MaximdeWinter: idea, design, testing in the game and direction.
Code written together with Claude Opus 5.5.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "_scratch", "release", "out"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    zpath = os.path.join(a.out, f"Conjunction-Runtime-{RUNTIME_VERSION}.zip")
    top = f"Mods/{setup.RUNTIME_MOD}/"
    n = 0
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _d, files in os.walk(setup.RUNTIME_SCRIPTS):
            for f in sorted(files):
                if not f.endswith(".ws"):                       # (no .bak of a patch)
                    continue
                p = os.path.join(root, f)
                z.write(p, top + "content/scripts/" + os.path.relpath(p, setup.RUNTIME_SCRIPTS).replace("\\", "/"))
                n += 1
        z.writestr(top + setup.RUNTIME_MARK, f"{RUNTIME_VERSION}\n")
        z.writestr(top + "README.txt", README.format(n=RUNTIME_VERSION).replace("\n", "\r\n"))
    h = hashlib.sha256(open(zpath, "rb").read()).hexdigest()
    open(zpath + ".sha256", "w").write(f"{h}  {os.path.basename(zpath)}\n")
    print(f"{zpath}: {n} scripts, runtime {RUNTIME_VERSION}, sha256 {h[:16]}...")


if __name__ == "__main__":
    main()
