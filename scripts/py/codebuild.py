"""Run a step for one env inside the VPC, as a build of the ci-runner CodeBuild project, and stream its log.

Usage: scripts/py/main.py codebuild <env> <stack> plan|up|down [extra terraform args]
       scripts/py/main.py codebuild <env> - db-restore <args>     (the Kubernetes steps of db_restore.py)

run-env.sh calls it for the stacks that talk to the private Kubernetes API when K8S_VIA=codebuild
(apply.yml, db-restore.yml); people use the SSM tunnel by default.

The build checks out a commit from GitHub: GITHUB_SHA in CI, else HEAD, which must be pushed (local
changes are not in the build). Ctrl-C (or a cancelled workflow) stops the build too.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import time
from urllib.parse import quote

import boto3
import botocore.exceptions
import lib

TARGETS = ("plan", "up", "down", "db-restore")
POLL_SECONDS = 10
MAX_FAILED_POLLS = 30  # throttling or a network blip: keep trying, but not forever


def commit() -> str:
    """The commit the build checks out: GITHUB_SHA in CI, else HEAD if it is pushed."""
    if sha := os.environ.get("GITHUB_SHA"):
        return sha
    git = ["git", "-C", str(lib.ROOT)]
    sha = lib.run(*git, "rev-parse", "HEAD").stdout.strip()
    lib.run(*git, "fetch", "-q", "origin")
    if not lib.run(*git, "branch", "-r", "--contains", sha).stdout.strip():
        lib.die(f"Commit {sha[:7]} is not pushed: CodeBuild checks it out from GitHub. Push it first.")
    if lib.run(*git, "status", "--porcelain", "--", "envs", "stacks", "modules", "scripts", "Makefile").stdout.strip():
        print(f"Note: uncommitted changes are not part of the build (it runs {sha[:7]}).", flush=True)
    return sha


def terraform_version() -> str:
    """The build installs the same Terraform as here."""
    proc = lib.run("terraform", "version", "-json")
    if proc.returncode != 0:
        lib.die(f"terraform version failed:\n{proc.stdout}")
    return json.loads(proc.stdout)["terraform_version"]


class LogTail:
    """Prints the CloudWatch log of a build from where it left off."""

    def __init__(self, logs):
        self.logs, self.token = logs, None

    def print_new(self, group: str, stream: str) -> None:
        while True:
            kwargs = {"logGroupName": group, "logStreamName": stream, "startFromHead": True}
            if self.token:
                kwargs["nextToken"] = self.token
            try:
                page = self.logs.get_log_events(**kwargs)
            except self.logs.exceptions.ResourceNotFoundException:  # the stream appears a little after start
                return
            for event in page["events"]:
                print(event["message"], end="" if event["message"].endswith("\n") else "\n", flush=True)
            if page["nextForwardToken"] == self.token:
                return
            self.token = page["nextForwardToken"]


def run_build(env: lib.Env, stack: str, target: str, args: list[str]) -> int:
    """Start the build, stream its log until it ends; 0 if it succeeded."""
    if target not in TARGETS:
        lib.die(f"target must be one of {', '.join(TARGETS)}, got '{target}'")
    if target == "down" or (target == "up" and "-destroy" in args):
        env.require_destroy_confirm()

    project = f"{env.cluster}-ci-runner"  # stacks/ci-runner
    sha = commit()
    variables = {
        "ENV": env.name,
        "STACK": stack,
        "TARGET": target,
        "ARGS": " ".join(args),
        "CONFIRM": os.environ.get("CONFIRM", ""),
        "TF_VERSION": terraform_version(),
        "TF_STATE_BUCKET": env.state_bucket(),
    }
    overrides = [{"name": k, "value": v, "type": "PLAINTEXT"} for k, v in variables.items() if v]  # empty = unset

    session = boto3.Session(region_name=env.region)
    codebuild, tail = session.client("codebuild"), LogTail(session.client("logs"))
    try:
        build_id = codebuild.start_build(
            projectName=project, sourceVersion=sha, environmentVariablesOverride=overrides
        )["build"]["id"]
    except botocore.exceptions.ClientError as e:
        lib.die(
            f"Could not start CodeBuild project {project}: {e.response['Error']['Code']}. Is ci-runner applied for "
            f"'{env.name}' (make up STACK=ci-runner ENV={env.name})? Without CI, use the tunnel (K8S_VIA unset)."
        )
    console = (
        f"https://{env.region}.console.aws.amazon.com/codesuite/codebuild/projects/{project}"
        f"/build/{quote(build_id, safe='')}/?region={env.region}"
    )
    print(f"CodeBuild {build_id} ({stack} {target} at {sha[:7]}):\n  {console}", flush=True)

    # Stop the build if we are stopped (Ctrl-C, a cancelled workflow sends SIGTERM).
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    status, logs, failed_polls = "IN_PROGRESS", {}, 0
    try:
        while status == "IN_PROGRESS":
            try:
                build = codebuild.batch_get_builds(ids=[build_id])["builds"][0]
                status, logs, failed_polls = build["buildStatus"], build.get("logs", {}), 0
            except Exception as e:  # noqa: BLE001 - any API hiccup counts as a failed poll
                failed_polls += 1
                if failed_polls >= MAX_FAILED_POLLS:
                    lib.die(f"Lost track of {build_id} ({e}), see the console link above")
            if logs.get("streamName"):
                tail.print_new(logs["groupName"], logs["streamName"])
            if status == "IN_PROGRESS":
                time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        codebuild.stop_build(id=build_id)
        print(f"\nStopped {build_id}", flush=True)
        return 130

    time.sleep(5)  # CloudWatch lags a little behind the build
    if logs.get("streamName"):
        tail.print_new(logs["groupName"], logs["streamName"])
    print(f"CodeBuild {stack} {target}: {status}", flush=True)
    return 0 if status == "SUCCEEDED" else 1


def add_parser(commands) -> None:
    parser = commands.add_parser(
        "codebuild",
        help="a step as a ci-runner build in the VPC (run-env.sh with K8S_VIA=codebuild)",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("env", metavar="<env>")
    parser.add_argument("stack", help="the stack, or - for db-restore")
    parser.add_argument("target", choices=TARGETS)
    parser.add_argument("args", nargs=argparse.REMAINDER, help="extra terraform args, or the db-restore args")
    parser.set_defaults(run=run, parser=parser)


def run(args: argparse.Namespace) -> int:
    if (args.stack == "-") != (args.target == "db-restore"):
        args.parser.error("use - as the stack exactly for db-restore")
    return run_build(lib.Env.load(args.env), args.stack, args.target, args.args)
