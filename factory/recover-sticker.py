#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Replace a lost router sticker (owner, 2026-10-25).

The sticker password is never stored: it is recalculated from this station's
factory key and the router's MAC, a new sticker is rendered and PRINTED NOW
(KNOTS_LABEL_PRINT_CMD, "{png}" = the file; no printer = PNG only, dry run),
and the recovery is logged in ~/knots-factory/recoveries.csv without the
password. A router made with a different factory key (TEST vs real) is refused.

  factory/recover-sticker.py rnode-9e3e            (router name)
  factory/recover-sticker.py 9e3e                  (just the 4 characters)
  factory/recover-sticker.py 3a:3f:64:1c:9e:3e     (MAC)
      [--reason "customer lost sticker"] [--print-cmd "lp {png}"]

Also on the station screen: "Replace a lost sticker".
"""
import argparse, importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("label_batch", os.path.join(HERE, "label-batch.py"))
label_batch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(label_batch)


def main():
    kf = os.path.expanduser("~/knots-factory")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("router", help="router name (rnode-xxxx or xxxx) or MAC")
    ap.add_argument("--reason", default="")
    ap.add_argument("--labels-csv", default=os.environ.get("KNOTS_LABELS_CSV", f"{kf}/labels.csv"))
    ap.add_argument("--key", default=os.environ.get("KNOTS_FACTORY_KEY_FILE", ""))
    ap.add_argument("--out", default=f"{kf}/recovered")
    ap.add_argument("--print-cmd", default=os.environ.get("KNOTS_LABEL_PRINT_CMD", ""))
    a = ap.parse_args()
    if not a.key or not os.path.isfile(a.key):
        sys.exit("no factory key — set KNOTS_FACTORY_KEY_FILE (source ~/knots-factory/station.env)")
    try:
        r = label_batch.recover_sticker(a.labels_csv, a.key, a.router, a.out, a.print_cmd, a.reason)
    except (LookupError, PermissionError) as e:
        sys.exit(f"NOT RECOVERED: {e}")
    print(f"New sticker for {r['unit']} ({r['mac']}): {r['png']}")
    print("Printed." if r["printed"] else "No printer configured — the sticker is the PNG above (dry run).")


if __name__ == "__main__":
    main()
