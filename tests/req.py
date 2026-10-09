#!/usr/bin/env python3
"""Reads back one request tests/intake-stub.py saved.

Usage: req.py <dir> <n|last> method|path|keys|header <name>|field <name>|len <name>

The body is decoded as strict UTF-8 and parsed as strict JSON, so a request
the intake could not read makes this exit non-zero instead of answering.
"""
import json
import os
import re
import sys

state_dir, which, query = sys.argv[1], sys.argv[2], sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else None
if which == "last":
    nums = [int(m.group(1)) for m in (re.match(r"req\.(\d+)\.json$", f) for f in os.listdir(state_dir)) if m]
    which = str(max(nums))
with open(os.path.join(state_dir, "req.%s.json" % which)) as f:
    meta = json.load(f)
with open(os.path.join(state_dir, "req.%s.body" % which), "rb") as f:
    raw = f.read()

if query == "method":
    out = meta["method"]
elif query == "path":
    out = meta["path"]
elif query == "header":
    out = meta["headers"].get(arg.lower(), "")
else:
    body = json.loads(raw.decode("utf-8"))
    if query == "keys":
        out = ",".join(sorted(body))
    elif query == "field":
        value = body.get(arg)
        out = value if isinstance(value, str) else json.dumps(value)
    elif query == "len":
        out = str(len(body[arg]))
    else:
        sys.exit("unknown query: " + query)
sys.stdout.write(out)
