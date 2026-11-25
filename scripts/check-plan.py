#!/usr/bin/env python3
"""Fail when a plan would replace or destroy a host, or touch the tape bucket.

    terraform plan -no-color | tee plan.txt && python3 scripts/check-plan.py plan.txt

user_data is ForceNew, so an innocent-looking template edit can replace a server
and lose its volumes. Reads the plan's text because a speculative remote plan has
no JSON form. --allow-replace (CI: the `replace-hosts` label) accepts it.
"""
import re
import sys

ACTION = re.compile(
    r"^\s*# (?P<addr>\S*(?:hcloud_server|cloudflare_r2_bucket)\.\S+) "
    r".*?(?P<what>must be replaced|will be replaced|will be destroyed)", re.M)
DONE = re.compile(r"^(Plan: \d+ to add|No changes\.)|^Changes to Outputs:", re.M)


def problems(text):
    return [f"{m['addr']} {m['what']}" for m in ACTION.finditer(text)]


def main(argv):
    allow = "--allow-replace" in argv
    paths = [a for a in argv if not a.startswith("--")]
    text = re.sub(r"\x1b\[[0-9;]*m", "", open(paths[0]).read())
    if not DONE.search(text):
        sys.exit("error: no plan summary found; refusing to call an incomplete plan safe")
    found = problems(text)
    for p in found:
        print(f"{'allowed' if allow else 'error'}: {p}")
    if found and not allow:
        sys.exit("a host or the tape bucket would be lost; if that is intended, label the PR `replace-hosts`")
    print("plan is safe" if not found else "plan replaces hosts, as labelled")


if __name__ == "__main__":
    main(sys.argv[1:])
