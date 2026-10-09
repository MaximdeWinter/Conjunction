"""Conjunction's line to the running game, through the script extender (TW3SE, tw3se.py): commands go in with the
pipe's `exec`, the lines Conjunction's scripts send (CjOut -> TW3SE_Emit) come back with `events`. Works with a
game started any way, from Steam too: no -debugscripts, no scriptslog.txt.

    link = GameLink(robust=True)
    link.exec("cj_where()")            # queued; a sender thread passes everything queued in one exec per tick
    pos = mark()                        # the current end of the game's lines
    pos, lines = since(pos)             # the lines sent after it

Commands are fire and forget, as with the script debugger before: what a command finds comes back as a line.
"""
import sys
import threading
import time

from . import tw3se

US = "\x1f"                 # between the commands of one exec (they run in the same tick, in order)
BATCH_BYTES = 3500          # one exec stays under the 4096 bytes the extender reads at once


_seen = [0.0, set()]


def _pids():
    """This suite's game (bg.our_pids), looked up at most once a second: the link asks many times a second."""
    if time.time() - _seen[0] > 1.0:
        from . import bg
        _seen[:] = [time.time(), bg.our_pids()]
    return _seen[1]


class GameLink:
    """`robust=True` (the editor): no game, or the game restarted - the link looks again on the next command, at
    most every 2 s; commands meanwhile are dropped (`connected` tells). Otherwise no answer raises OSError."""

    def __init__(self, robust=False):
        self.robust = robust
        self.cv = threading.Condition()
        self.pending, self.busy, self._alive = [], False, True
        self.ok, self._next_try = False, 0.0
        if not self._look() and not robust:
            raise OSError("no script extender answers (is the game running with TW3SE?)")
        threading.Thread(target=self._send_loop, daemon=True).start()

    @property
    def connected(self):
        return self.ok

    def _look(self):
        self.ok = tw3se.ready(_pids())
        self._next_try = time.time() + 2.0
        return self.ok

    def exec(self, cmd):
        """Queue an exec function call (`cj_where()`, `addfact("x", 1)`) -> False: no game to send it to."""
        if not self.ok and (not self.robust or time.time() < self._next_try or not self._look()):
            return False
        with self.cv:
            self.pending.append(cmd)
            self.cv.notify()
        return True

    def flush(self, timeout=5.0):
        """Wait until every queued command has run in the game."""
        end = time.time() + timeout
        with self.cv:
            while (self.pending or self.busy) and time.time() < end:
                self.cv.wait(0.05)

    def _send_loop(self):
        while True:
            with self.cv:
                while not self.pending and self._alive:
                    self.cv.wait()
                if not self._alive:
                    return
                batch = [self.pending.pop(0)]
                size = len(batch[0])
                while self.pending and size + len(self.pending[0]) + 1 < BATCH_BYTES:
                    size += len(self.pending[0]) + 1
                    batch.append(self.pending.pop(0))
                self.busy = True
            answer = tw3se.send("exec " + US.join(batch), _pids())
            with self.cv:
                self.busy = False
                if answer is None:                  # the game went away: the rest is for a game that is gone
                    self.ok = False
                    self.pending.clear()
                self.cv.notify_all()
            if answer and answer.startswith("error"):
                print(f"[game] {answer}", file=sys.stderr)

    def close(self):
        with self.cv:
            self._alive = False
            self.cv.notify_all()


def mark():
    """The current end of the game's lines (0: no extender answers)."""
    answer = tw3se.send("events", _pids())
    try:
        return int(answer.split()[1])
    except (AttributeError, IndexError, ValueError):
        return 0


def since(pos):
    """The lines the game's scripts sent after `pos` -> (new position, lines); (pos, []) without a game."""
    lines = []
    for _ in range(64):                     # a reply holds ~3800 bytes: ask again while it comes full
        answer = tw3se.send(f"events {pos}", _pids())
        if not answer:
            break
        head, *got = answer.split("\n")
        try:
            new = int(head.split()[1])
        except (IndexError, ValueError):
            break
        if new == pos or not got:
            pos = new
            break
        pos = new
        lines += got
    return pos, lines


def listen(q, stop, every=0.01):
    """Every line the game's scripts send into the queue `q`, until `stop` is set (the editor's Qt timer takes
    them). The game running at the start is read from now on (like a log from its end); a game that starts
    later is read from its first line."""
    game = frozenset(_pids())
    pos = mark() if game else None
    while not stop.is_set():
        now = frozenset(_pids())
        if now != game:                     # another game: from the start of its lines
            game, pos = now, 0 if now else None
        if pos is None:
            time.sleep(0.5)
            continue
        pos, lines = since(pos)
        for line in lines:
            q.put(line)
        if not lines:
            time.sleep(every)


def run(cmds, wait=1.0):
    """Exec commands, return the lines the game sends within `wait` seconds (tests, the CLI, one-off questions).
    Raises OSError without a game."""
    pos = mark()
    answer = tw3se.send("exec " + US.join(cmds), _pids())
    if answer is None:
        raise OSError("no script extender answers (is the game running with TW3SE?)")
    time.sleep(wait)
    return since(pos)[1]


if __name__ == "__main__":
    args = sys.argv[1:]
    wait = 1.0
    if args and args[0].startswith("--wait="):
        wait = float(args.pop(0).split("=", 1)[1])
    for line in run(args or ["cj_ping(1)"], wait):
        print(line)
