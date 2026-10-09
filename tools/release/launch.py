"""The suite's start for the release build (PyInstaller): the same as python -m conjunction."""
import multiprocessing

from conjunction.__main__ import main

if __name__ == "__main__":
    multiprocessing.freeze_support()            # the asset database is read by worker processes
    main()
