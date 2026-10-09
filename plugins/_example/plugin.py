"""Example plug-in - copy this folder (without the leading underscore) into a folder of plug-ins, or add the copy's
folder in Settings > Plug-ins. Shows the hooks: a catalog entry, a quest step type, a page of the app, a tab of the
in-game panel, a section of the inspector, its settings. See conjunction/plugins.py for every one.
"""
from PySide6 import QtWidgets

from conjunction.quest import StepOut


class Bonfire:
    """Quest step `wait_night`: continues when it is night in the game (a radish time condition)."""
    name = "wait_night"

    def generate(self, ctx, i, step):
        block = f"waituntil.s{i}"
        # StepOut(blocks, first block, last block, journal objective or None)
        return StepOut({block: {"after": "21:00"}}, block, block,
                       {"caption": step.get("text", "Wait until night falls")})


def panel(editor):
    w = QtWidgets.QWidget()
    v = QtWidgets.QVBoxLayout(w)
    v.addWidget(QtWidgets.QLabel(f"Hello from a plug-in - project {editor.project.id}, place {editor.place}"))
    b = QtWidgets.QPushButton("Place a campfire")
    b.clicked.connect(lambda: editor.set_template(r"environment\decorations\light_sources\campfire\campfire_01.w2ent"))
    v.addWidget(b)
    v.addStretch(1)
    return w


def register(api):
    values = api.settings()
    api.add_catalog([{"path": r"environment\decorations\light_sources\campfire\campfire_01.w2ent",
                      "name": "campfire (example plug-in)", "kind": "Light", "source": "Example plug-in"}])
    api.add_block("wait_night", Bonfire())
    api.add_panel("Example", panel)
    api.add_page("Example", lambda app: QtWidgets.QLabel(f"An app page: no game needed. Greeting: {values['greeting']}"))
    api.add_inspector_section("npc", lambda editor, obj, place, index: QtWidgets.QLabel(f"{obj.get('id') or 'a person'}"
                                                                                       f" - {values['greeting']}"),
                              title="Example")
    api.add_settings("Example", [{"key": "greeting", "label": "Greeting", "type": "text", "default": "Hello"},
                                 {"key": "loud", "label": "Loud", "type": "bool", "default": False}])
