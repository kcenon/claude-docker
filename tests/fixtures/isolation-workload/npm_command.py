"""Use Node's npm CLI directly where Windows exposes npm as a batch launcher."""
import os
from pathlib import Path
import shutil


def npm_command():
    npm = shutil.which("npm")
    if not npm:
        raise RuntimeError("npm is required for the package workload")
    if os.name == "nt":
        cli = Path(npm).parent / "node_modules/npm/bin/npm-cli.js"
        node = shutil.which("node")
        if not cli.is_file() or not node:
            raise RuntimeError("Cannot locate the installed Node/npm CLI")
        return [node, str(cli)]
    return [npm]
