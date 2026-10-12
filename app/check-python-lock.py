# check-python-lock.py — does a Python environment hold exactly the packages
# in python-requirements.lock, at the locked versions?
#
#   <env>/bin/python3 -I -B check-python-lock.py python-requirements.lock
#
# Run with the environment's own interpreter, which is what it inspects. Exits
# 1 and names every difference when they don't match. bundle-python.sh runs it
# on the env it builds or reuses, and release.sh on the env inside the app it
# is about to notarize, so a release can't ship packages the lock doesn't name.
import re
import sys
from importlib.metadata import distributions

def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()

locked = {}
for line in open(sys.argv[1]):
    match = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s\;]+)", line)
    if match:
        locked[norm(match[1])] = match[2]
installed = {norm(d.metadata["Name"]): d.version for d in distributions()}
# The interpreter's own installers, unless the lock pins them; pruned later.
for tool in ("pip", "setuptools", "wheel"):
    if tool not in locked:
        installed.pop(tool, None)
mismatched = sorted(set(locked.items()) ^ set(installed.items()))
if mismatched:
    print("!!  Installed packages don't match the lock:")
    for name, version in mismatched:
        where = "lock" if locked.get(name) == version else "installed"
        print(f"!!    {name}=={version} (only in {where})")
    sys.exit(1)
print(f"    {len(installed)} packages, all as locked")
