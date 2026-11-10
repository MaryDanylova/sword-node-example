"""Shared helpers for the Python commands in scripts/py/ (`import lib`; main.py's directory is on sys.path).

The env layout (tfvars layers, project, region, names) stays in lib.sh, the single source of truth:
Env.load() sources it in bash and reads the values back instead of parsing the layers again.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

# The AWS CLI reports a failed call as "An error occurred (<Code>) when calling the <Op> operation: ...".
# Authorization failures, by error code: AccessDenied (S3, SQS, STS), AccessDeniedException (JSON
# protocol services such as Secrets Manager), 403 (S3 HEAD requests, which have no error body).
AWS_DENIED = re.compile(r"An error occurred \((AccessDenied|AccessDeniedException|403)\) when calling")


@dataclass(frozen=True)
class Env:
    name: str
    project: str
    region: str
    cluster: str
    local_port: int
    kubeconfig: Path

    @classmethod
    def load(cls, name: str) -> Env:
        names = ["ENV_NAME", "PROJECT", "REGION", "CLUSTER_NAME", "LOCAL_PORT", "KUBECONFIG_FILE"]
        script = '. "$0" "$1" >&2 && printf "%s\\n" ' + " ".join(f'"${n}"' for n in names)
        proc = subprocess.run(["bash", "-c", script, str(SCRIPTS / "lib.sh"), name], capture_output=True, text=True)
        if proc.returncode != 0:
            sys.exit(proc.stderr.strip() or f"Could not load env '{name}'")
        env_name, project, region, cluster, port, kubeconfig = proc.stdout.splitlines()
        return cls(env_name, project, region, cluster, int(port), Path(kubeconfig))

    def tf_outputs(self, stack: str) -> dict:
        """All outputs of a stack as {name: value}; {} if the stack is not applied."""
        proc = subprocess.run(
            [str(SCRIPTS / "run-stack.sh"), self.name, stack, "output", "-json"],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return {}
        return {k: v.get("value") for k, v in json.loads(proc.stdout).items()}

    def db_instance_id(self) -> str:
        """The MySQL instance Terraform manages, unless DB_ID is set ("" if none)."""
        return os.environ.get("DB_ID") or self.tf_outputs("database").get("db_instance_identifier") or ""

    def state_bucket(self) -> str:
        """The env's state bucket (lib.sh state_bucket: TF_STATE_BUCKET, or the one found by tags)."""
        script = '. "$0" "$1" >&2 && state_bucket'
        proc = subprocess.run(
            ["bash", "-c", script, str(SCRIPTS / "lib.sh"), self.name], capture_output=True, text=True
        )
        if proc.returncode != 0:
            die(proc.stderr.strip() or f"No state bucket for '{self.name}'")
        return proc.stdout.strip()

    def require_destroy_confirm(self) -> None:
        """Destroying anything outside dev needs CONFIRM=<env> (as lib.sh require_destroy_confirm)."""
        if self.name != "dev" and os.environ.get("CONFIRM") != self.name:
            die(f"Refusing to destroy in '{self.name}' without CONFIRM={self.name}")


# ------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------
def say(msg: str) -> None:
    """A step banner with the time, like run-env.sh's."""
    print(f"\n\033[1;36m==> [{time.strftime('%H:%M:%S')}] {msg}\033[0m", flush=True)


def die(msg: str) -> NoReturn:
    sys.exit(msg)


def table(rows: list[dict], columns: list[str]) -> None:
    """Rows as an aligned table (missing values print as -); "(none)" for no rows."""
    if not rows:
        print("   (none)")
        return
    cells = [[str(r.get(c) or "-") for c in columns] for r in rows]
    widths = [max(len(c), *(len(row[i]) for row in cells)) for i, c in enumerate(columns)]
    for row in [columns, ["-" * w for w in widths], *cells]:
        print("   " + "  ".join(v.ljust(w) for v, w in zip(row, widths, strict=True)).rstrip())


@dataclass
class Report:
    """Prints checks as they run and counts them."""

    passed: int = 0
    failed: int = 0
    failures: list[str] = field(default_factory=list)

    @staticmethod
    def section(title: str) -> None:
        print(f"\n\033[1m== {title}\033[0m", flush=True)

    def ok(self, desc: str) -> None:
        self.passed += 1
        print(f"  \033[32m✓\033[0m {desc}", flush=True)

    def bad(self, desc: str, detail: str = "") -> None:
        self.failed += 1
        self.failures.append(desc)
        print(f"  \033[31m✗\033[0m {desc}", flush=True)
        for line in detail.strip().splitlines()[:5]:
            print(f"      {line}")

    @staticmethod
    def skip(desc: str) -> None:
        print(f"  - skipped: {desc}", flush=True)

    def check(self, condition: bool, desc: str, detail: str = "", *, failed: str | None = None) -> bool:
        """ok(desc) if condition, else bad(failed or desc, detail)."""
        if condition:
            self.ok(desc)
        else:
            self.bad(failed or desc, detail)
        return condition

    def summary(self) -> int:
        self.section("Result")
        print(f"  passed: {self.passed}  failed: {self.failed}")
        return 0 if self.failed == 0 else 1


# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------
def run(*cmd: str, input: str | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    """Run a command, capture stdout and stderr together in .stdout, never raise on failure."""
    return subprocess.run(
        cmd,
        input=input,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ, **(env or {})},
    )


def run_live(*cmd: str, env: dict | None = None) -> int:
    """Run a command with its output going straight to the terminal (long steps: Terraform, builds)."""
    return subprocess.run(cmd, env={**os.environ, **(env or {})}).returncode


# ------------------------------------------------------------------------------
# Kubernetes (kubectl with a given kubeconfig)
# ------------------------------------------------------------------------------
class Kube:
    def __init__(self, kubeconfig: str):
        self.env = {"KUBECONFIG": kubeconfig}

    def kubectl(self, *args: str, input: str | None = None) -> subprocess.CompletedProcess:
        return run("kubectl", *args, input=input, env=self.env)

    def configmap(self, ns: str, name: str) -> dict:
        proc = self.kubectl("get", "configmap", "-n", ns, name, "-o", "json")
        return json.loads(proc.stdout).get("data", {}) if proc.returncode == 0 else {}

    def pod_names(self, ns: str, selector: str, *, running: bool = False) -> list[str]:
        extra = ["--field-selector=status.phase=Running"] if running else []
        proc = self.kubectl("get", "pods", "-n", ns, "-l", selector, *extra, "-o", "jsonpath={.items[*].metadata.name}")
        return proc.stdout.split() if proc.returncode == 0 else []

    def pod_ip(self, ns: str, selector: str) -> str:
        proc = self.kubectl("get", "pods", "-n", ns, "-l", selector, "-o", "jsonpath={.items[0].status.podIP}")
        return proc.stdout.strip()


@dataclass(frozen=True)
class Pod:
    kube: Kube
    ns: str
    name: str
    container: str | None = None

    def exec(self, *cmd: str, input: str | None = None) -> subprocess.CompletedProcess:
        flags = (["-i"] if input is not None else []) + (["-c", self.container] if self.container else [])
        return self.kube.kubectl("exec", *flags, "-n", self.ns, self.name, "--", *cmd, input=input)

    def sh(self, script: str, *args: str, input: str | None = None) -> subprocess.CompletedProcess:
        """Run a shell snippet in the pod; args are $0, $1, ... (never interpolated into the script)."""
        return self.exec("sh", "-c", script, *args, input=input)


class Tunnel:
    """The env's API on localhost through the SSM tunnel, for the steps in the with block (scripts/tunnel-up.sh).

    A tunnel already listening (your `make tunnel`) is reused and left running; one started here is
    stopped on the way out, also after an error or Ctrl-C. Nothing reconnects in the middle of a step:
    if the tunnel drops, the step fails and the same command run again continues.
    """

    def __init__(self, env: Env):
        self.env, self.pid = env, None

    def __enter__(self) -> Tunnel:
        proc = subprocess.run([str(SCRIPTS / "tunnel-up.sh"), self.env.name], stdout=subprocess.PIPE, text=True)
        if proc.returncode != 0:
            die(f"No access to the Kubernetes API of '{self.env.name}' (above)")
        self.pid = int(proc.stdout.strip()) if proc.stdout.strip() else None
        return self

    def __exit__(self, *_) -> None:
        if self.pid is None:
            return
        subprocess.run(["pkill", "-P", str(self.pid)], capture_output=True)  # session-manager-plugin child
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        print(f"Stopped the background tunnel (pid {self.pid})", file=sys.stderr, flush=True)
        self.pid = None
