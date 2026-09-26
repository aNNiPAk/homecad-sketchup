"""Stop only the harness-owned SketchUp process and optionally restore production files."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.dev.core import (DevError, ensure_config, local_root, remove_dev_links,
                              repo_root, stop_owned_process)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remove-dev-links", action="store_true",
                        help="remove verified HomeCAD dev links and restore the saved production install")
    parser.add_argument("--sketchup-exe")
    parser.add_argument("--plugins-dir")
    args = parser.parse_args()
    try:
        root = repo_root()
        config = ensure_config(root=root, sketchup_exe=args.sketchup_exe, plugins_dir=args.plugins_dir)
        stop_owned_process(root, config)
        if args.remove_dev_links:
            remove_dev_links(root, config, restore_backup=True)
            print("Removed verified HomeCAD dev links and restored the original HomeCAD installation, if present.")
        else:
            print("Stopped the owned SketchUp process. Dev links remain installed.")
        state = local_root(root) / "state.json"
        if state.exists():
            raise DevError("process state remains after teardown; inspect it before further cleanup")
        print(json.dumps({"status": "success", "remove_dev_links": args.remove_dev_links,
                          "plugins_dir": config["plugins_dir"]}, indent=2))
    except Exception as error:
        print(f"dev_teardown: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
