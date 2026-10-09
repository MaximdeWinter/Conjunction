"""Small shared fields. A number and its unit: the unit is a label next to the field, never inside it (typing into
'10 m' fought the unit) - every number field of Conjunction goes through `with_unit`."""
from PySide6 import QtWidgets

UNIT_STYLE = "color:#9a9a9a;font:12px"


def with_unit(spin, after="", before=""):
    """[before] [the field] [after] in one row; the field stays reachable as `.spin`."""
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    h.setSpacing(3)
    grow = spin.sizePolicy().horizontalPolicy() in (QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Expanding)
    for text in (before, None, after):
        if text is None:
            h.addWidget(spin, 1 if grow else 0)         # its own width, unless it was made to fill (a grid cell)
        elif text.strip():
            lab = QtWidgets.QLabel(text.strip())
            lab.setStyleSheet(UNIT_STYLE)
            h.addWidget(lab)
    spin.setSuffix("")
    spin.setPrefix("")
    w.spin = spin
    w.setSizePolicy(spin.sizePolicy() if grow else QtWidgets.QSizePolicy(QtWidgets.QSizePolicy.Maximum,
                                                                         QtWidgets.QSizePolicy.Fixed))
    return w
