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

    if len(sys.argv) > 1:
        expected_repo = sys.argv[1]

        repositories = response.get("repositories")

        if not isinstance(repositories, list):
            raise ValueError("Repository scope missing from token response")

        actual_repos = [
            repo.get("full_name")
            for repo in repositories
            if isinstance(repo, dict)
        ]

        if actual_repos != [expected_repo]:
            raise ValueError(
                "Repository scope does not match the expected repository"
            )

        print("PASS: Installation token restricted to expected repository")

except (ValueError, TypeError, KeyError) as exc:
    print("FAIL: " + str(exc), file=sys.stderr)
    sys.exit(1)