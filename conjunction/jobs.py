"""Long jobs (a pack converted, a batch baked): run beside the app, their progress shown, the app stays usable.
Plug-ins start them with api.run_job; the app's jobs bar (app.py) shows each one's name, its fraction and its line.

    job = run(name, fn, on_done=None)      fn(progress) -> result; progress(fraction 0..1, text="")
    JOBS.changed (signal), JOBS.active()   [job]
    job.name, job.fraction, job.text, job.done, job.error, job.result
    job.cancel() / progress(...) raises Cancelled after it (the job ends where it asks next)
"""
import threading
import time
import traceback

from PySide6 import QtCore


class Cancelled(Exception):
    pass


class Job:
    def __init__(self, name):
        self.name, self.fraction, self.text = name, 0.0, ""
        self.done, self.error, self.result, self.cancelled = False, None, None, False
        self.started = time.time()

    def cancel(self):
        self.cancelled = True


class Jobs(QtCore.QObject):
    changed = QtCore.Signal()
    finished = QtCore.Signal(object)            # (job) - in the app's thread

    def __init__(self):
        super().__init__()
        self.jobs = []
        self._lock = threading.Lock()
        self.finished.connect(self._finished)
        self._done_fns = {}

    def active(self):
        with self._lock:
            return [j for j in self.jobs if not j.done]

    def run(self, name, fn, on_done=None):
        job = Job(name)
        with self._lock:
            self.jobs.append(job)
        self._done_fns[id(job)] = on_done

        def progress(fraction, text=""):
            if job.cancelled:
                raise Cancelled()
            job.fraction, job.text = max(0.0, min(1.0, float(fraction))), str(text)
            self.changed.emit()

        def work():
            try:
                job.result = fn(progress)
            except Cancelled:
                job.error = "cancelled"
            except Exception:                           # noqa: BLE001 - a job's failure is the job's, not the app's
                job.error = traceback.format_exc(limit=4)
            job.done = True
            self.finished.emit(job)
        threading.Thread(target=work, name=f"job: {name}", daemon=True).start()
        self.changed.emit()
        return job

    def _finished(self, job):
        fn = self._done_fns.pop(id(job), None)
        with self._lock:
            self.jobs = [j for j in self.jobs if not j.done or time.time() - j.started < 3600]
        if fn is not None:
            try:
                fn(job)
            except Exception:                           # noqa: BLE001
                traceback.print_exc()
        self.changed.emit()


JOBS = None


def jobs():
    global JOBS
    if JOBS is None:
        JOBS = Jobs()
    return JOBS


def run(name, fn, on_done=None):
    return jobs().run(name, fn, on_done)
