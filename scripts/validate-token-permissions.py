import json
import sys

try:
    response = json.load(sys.stdin)
    permissions = response.get("permissions", {})

    if not isinstance(permissions, dict):
        raise ValueError("Invalid permissions object")

    if permissions.get("contents") != "read":
        raise ValueError("Contents permission must be read-only")

    excessive = [
        name for name, level in permissions.items()
        if level in ("write", "admin")
    ]

    if excessive:
        raise ValueError("Excessive permissions: " + ", ".join(excessive))

    print("PASS: Installation token permissions are read-only")

except (ValueError, TypeError, KeyError) as exc:
    print("FAIL: " + str(exc), file=sys.stderr)
    sys.exit(1)