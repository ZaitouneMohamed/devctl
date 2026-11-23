"""devctl dashboard entry point.

Started by `devctl dashboard` as a transient systemd user unit:
    /usr/bin/python3 -I dashboard/main.py --port 7780 --devctl-bin ... --state-dir ... --run-dir ...

-I (isolated mode) ignores PYTHON* variables, the user site directory and the current
directory, so only this package and the standard library are importable.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from devctl_dash.server import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
