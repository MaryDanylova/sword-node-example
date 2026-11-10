"""Restore the env's MySQL next to the live instance and switch the apps to it without restarting them.

Usage: scripts/py/main.py db-restore <env> <command>      (--help on each command)
  list                                      what can be restored (read-only)
  restore <point> [--stop-before-cutover]   point: latest | a UTC time 2026-01-31T12:00:00Z | a snapshot id or ARN
  rollback <instance-id>                    switch back to an instance that still exists
  retire <instance-id>                      delete an instance nothing uses (final snapshot kept)

restore is one command, safe to re-run with the same arguments: each phase checks whether it is
already done, so a dropped tunnel or a failed step continues where it stopped.
  1. create    <name>-<26 hex> next to the live instance, with its settings. Nothing else changes.
  2. check     the app and monitor users on the new instance are set to their current secrets, because a
               backup can be older than those (only this instance changes). Then, from a ProxySQL pod,
               they log in over verified TLS and the app database exists (proxysql/check.sh).
  3. cutover   in every ProxySQL pod, the new instance waits in hostgroup 20 until the monitor reports
               it healthy (all pods, before any switch), then replaces the old one in hostgroup 10
               while that drains (proxysql/stage.sh, switch.sh); saved in the pods and the backend
               ConfigMap. The apps keep their connections and use the restored data from their next
               query on. Writes made after the restore point are not in it.
  4. finalize  Terraform follows: state rm + import of the new instance (stops if the plan would
               replace it), then apply database, app-aws, app-k8s. No file changes, nothing to commit.
The old instance keeps running until `retire`; until then `rollback <old-id>` switches back.
--stop-before-cutover ends after the check (look at the data: DB_ID=<new> scripts/db-sql.sh <env> "...").

The Kubernetes steps (users, check, cutover, finalize's app-k8s) run here through the SSM tunnel, opened after
the RDS waits (a tunnel already listening is reused and left running; one opened here is closed at the
end), or with K8S_VIA=codebuild as a build of the ci-runner project inside the VPC (db-restore.yml does).
The "instance gone" case (after make down) is not this command:
TF_VAR_restore_snapshot_id=<id> make up-all ENV=<env> (see list).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import boto3
import botocore.exceptions
import codebuild
import lib

PROXYSQL_SCRIPTS = Path(__file__).parent / "proxysql"
TIME_FORMAT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
WAIT_TIMEOUT = 3600  # a restore takes 10-20 min
MYSQL_IMAGE = "mysql:8.4"
DB_USERS_SCRIPT = lib.ROOT / "stacks/app-k8s/scripts/db-users.sh"  # what the app-k8s user Job runs


@dataclass(frozen=True)
class Source:
    """What to restore from: kind time | latest | snapshot, and its value."""

    kind: str
    value: str

    @classmethod
    def parse(cls, point: str) -> Source:
        """latest, a UTC time (RDS identifiers start with a letter, so a digit means a time), else a snapshot."""
        if not point:
            lib.die("restore needs a point: latest, a UTC time or a snapshot id / ARN (see list)")
        if point == "latest":
            return cls("latest", "latest")
        if point[0].isdigit():
            if not TIME_FORMAT.match(point):
                lib.die(f"'{point}' is not a UTC time like 2026-01-31T12:00:00Z")
            return cls("time", point)
        return cls("snapshot", point)

    @property
    def tag(self) -> str:  # the RestoredFrom tag on the new instance
        return f"{self.kind}:{self.value}"

    def instance_name(self, prefix: str, from_id: str) -> str:
        """Same arguments, same name: a re-run finds the instance it already created."""
        digest = hashlib.sha256(f"{from_id}|{self.kind}|{self.value}".encode()).hexdigest()
        return prefix + digest[:26]


def ts(value: datetime | None) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ") if value else ""


# ------------------------------------------------------------------------------
# RDS
# ------------------------------------------------------------------------------
class Rds:
    def __init__(self, session: boto3.Session):
        self.client = session.client("rds")

    def get(self, instance_id: str) -> dict | None:
        try:
            return self.client.describe_db_instances(DBInstanceIdentifier=instance_id)["DBInstances"][0]
        except self.client.exceptions.DBInstanceNotFoundFault:
            return None

    def status(self, instance_id: str) -> str:
        return (self.get(instance_id) or {}).get("DBInstanceStatus", "not found")

    def wait_available(self, instance_id: str) -> None:
        self.wait_for(instance_id, "available", "become available")

    def wait_deleted(self, instance_id: str) -> None:
        self.wait_for(instance_id, "not found", "get deleted")

    def wait_for(self, instance_id: str, wanted: str, goal: str) -> None:
        """Poll until the instance reaches the wanted status ("not found" = deleted).

        Giving up (timeout or Ctrl-C) only stops the waiting: RDS carries on, and the same command waits again.
        """
        deadline, last = time.time() + WAIT_TIMEOUT, None
        try:
            while (status := self.status(instance_id)) != wanted:
                if time.time() > deadline:
                    lib.die(
                        f"{instance_id} did not {goal} within {WAIT_TIMEOUT // 60} min (still {status}). "
                        "RDS carries on: re-run the same command to keep waiting."
                    )
                if status != last:
                    print(f"  {instance_id}: {status}, waiting", flush=True)
                    last = status
                time.sleep(30)
        except KeyboardInterrupt:
            print(
                f"\nStopped waiting for {instance_id} to {goal}. RDS carries on: re-run the same command to keep "
                "waiting.",
                file=sys.stderr,
            )
            raise SystemExit(130) from None

    def all(self, paginator: str, key: str, keep) -> list[dict]:
        """Every item of a paginated describe call for which keep(item) is true."""
        pages = self.client.get_paginator(paginator).paginate()
        return [item for page in pages for item in page[key] if keep(item)]


# ------------------------------------------------------------------------------
# ProxySQL (the Kubernetes side): here through the tunnel, or inside the CodeBuild build
# ------------------------------------------------------------------------------
class ProxySql:
    def __init__(self, env: lib.Env):
        self.env = env
        kube = lib.Kube(self._kubeconfig(env))
        px = env.tf_outputs("app-k8s").get("proxysql") or lib.die(f"No ProxySQL in app-k8s for '{env.name}'")
        self.kube, self.ns, self.config_map = kube, px["namespace"], px["backend_config_map"]
        names = kube.pod_names(self.ns, "app.kubernetes.io/name=proxysql", running=True)
        self.pods = [lib.Pod(kube, self.ns, n, container="proxysql") for n in names]
        if not self.pods:
            lib.die(f"No running ProxySQL pods in {self.ns}")

    @staticmethod
    def _kubeconfig(env: lib.Env) -> str:
        if os.environ.get("CODEBUILD_BUILD_ID"):  # inside the VPC: the private endpoint, as the build role
            eks = env.tf_outputs("eks")
            exec_args = ["eks", "get-token", "--cluster-name", env.cluster, "--region", env.region]
            config = {
                "apiVersion": "v1",
                "kind": "Config",
                "clusters": [
                    {
                        "name": "eks",
                        "cluster": {
                            "server": eks["cluster_endpoint"],
                            "certificate-authority-data": eks["cluster_certificate_authority_data"],
                        },
                    }
                ],
                "users": [
                    {
                        "name": "build",
                        "user": {
                            "exec": {
                                "apiVersion": "client.authentication.k8s.io/v1beta1",
                                "command": "aws",
                                "args": exec_args,
                            }
                        },
                    }
                ],
                "contexts": [{"name": "eks", "context": {"cluster": "eks", "user": "build"}}],
                "current-context": "eks",
            }
            path = Path(tempfile.mkdtemp()) / "kubeconfig"
            path.write_text(json.dumps(config))  # kubectl reads JSON as YAML
            return str(path)
        try:
            socket.create_connection(("localhost", env.local_port), timeout=2).close()
        except OSError:
            lib.die(
                f"No tunnel on localhost:{env.local_port}: run 'make tunnel ENV={env.name}' (or K8S_VIA=codebuild)."
            )
        if not env.kubeconfig.exists():
            lib.die(f"Missing {env.kubeconfig}: run 'make kubeconfig ENV={env.name}'.")
        return str(env.kubeconfig)

    def _run(self, pod: lib.Pod, script: str, *args: str) -> None:
        body = (PROXYSQL_SCRIPTS / "common.sh").read_text() + (PROXYSQL_SCRIPTS / script).read_text()
        proc = pod.sh(body, "sh", *args)
        print(f"  {pod.name}: {proc.stdout.strip()}", flush=True)
        if proc.returncode != 0:
            lib.die(f"{script} failed in {pod.name}")

    def sync_users(self, host: str, port: str, database: str, master_secret_arn: str) -> None:
        """Set the app and monitor users on <host> to their current secrets, as the user Job does at finalize.

        A backup older than the secrets has other passwords, and the check below would refuse it. The secrets
        are only read, and only this instance is written to. It runs the Job's script in a pod of the Job's
        namespace, with the credentials over stdin in a memory-backed volume, never in the pod spec.
        """
        secrets = boto3.Session(region_name=self.env.region).client("secretsmanager")

        def creds(arn: str) -> str:
            secret = json.loads(secrets.get_secret_value(SecretId=arn)["SecretString"])
            return f"{secret['username']}\n{secret['password']}\n"

        users = self.env.tf_outputs("database")["db_user_secrets"]
        files = {
            "master": creds(master_secret_arn),
            "app": creds(users["app"]["secret_arn"]),
            "monitor": creds(users["monitor"]["secret_arn"]),
        }
        ns, name = self.env.tf_outputs("app-aws")["db_admin_namespace"], f"db-users-sync-{int(time.time())}"
        values = {"DB_HOST": host, "DB_PORT": port, "DB_NAME": database, "HOME": "/tmp"}
        manifest = {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": name, "namespace": ns},
            "spec": {
                "restartPolicy": "Never",
                "terminationGracePeriodSeconds": 1,  # sleep ignores SIGTERM: do not wait 30s on cleanup
                "automountServiceAccountToken": False,
                "securityContext": {
                    "runAsNonRoot": True,
                    "runAsUser": 999,
                    "runAsGroup": 999,
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                "containers": [
                    {
                        "name": "main",
                        "image": MYSQL_IMAGE,
                        "command": ["sleep", "600"],
                        "env": [{"name": k, "value": v} for k, v in values.items()],
                        "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                        "volumeMounts": [{"name": "creds", "mountPath": "/creds"}],
                    }
                ],
                "volumes": [{"name": "creds", "emptyDir": {"medium": "Memory"}}],
            },
        }
        proc = self.kube.kubectl("apply", "-f", "-", input=json.dumps(manifest))
        if proc.returncode != 0:
            lib.die(f"Could not create pod {ns}/{name}:\n{proc.stdout}")
        try:
            proc = self.kube.kubectl("wait", "--for=condition=Ready", "-n", ns, f"pod/{name}", "--timeout=180s")
            if proc.returncode != 0:
                lib.die(f"Pod {ns}/{name} did not start:\n{proc.stdout}")
            pod = lib.Pod(self.kube, ns, name)
            for file, content in files.items():
                if pod.sh('cat > "/creds/$0"', file, input=content).returncode != 0:
                    lib.die(f"Could not write {file} credentials in {ns}/{name}")
            proc = pod.sh(DB_USERS_SCRIPT.read_text())
            print(f"  {proc.stdout.strip()}", flush=True)
            if proc.returncode != 0:
                lib.die(f"Could not set the users on {host}")
        finally:
            self.kube.kubectl("delete", "pod", "--ignore-not-found", "--wait=false", "-n", ns, name)

    def check(self, host: str, port: str, database: str) -> None:
        self._run(self.pods[0], "check.sh", host, port, database)

    def cutover(self, host: str, port: str) -> None:
        for pod in self.pods:  # stage in all of them before any switch
            self._run(pod, "stage.sh", host, port)
        for pod in self.pods:
            self._run(pod, "switch.sh", host)
        # Pods started from now on (rescheduled, scaled) render the same backend.
        patch = json.dumps({"data": {"BACKEND_HOST": host, "BACKEND_PORT": port}})
        proc = self.kube.kubectl("patch", "configmap", "-n", self.ns, self.config_map, "--type", "merge", "-p", patch)
        if proc.returncode != 0:
            lib.die(f"Could not patch configmap {self.ns}/{self.config_map}:\n{proc.stdout}")
        print(f"  configmap {self.ns}/{self.config_map}: {host}:{port}")


# ------------------------------------------------------------------------------
# The restore
# ------------------------------------------------------------------------------
class Restore:
    def __init__(self, env: lib.Env):
        self.env = env
        self.session = boto3.Session(region_name=env.region)
        self.rds = Rds(self.session)
        self.prefix = f"{env.cluster}-mysql-"  # the database stack's identifier_prefix

    def cmd(self, command: str) -> str:
        """The command line that runs this command for this env (for the hints printed along the way)."""
        return f"scripts/py/main.py db-restore {self.env.name} {command}"

    # --- Kubernetes steps: here, or the same command as a CodeBuild build in the VPC ---
    def k8s(self, step: str, *args: str) -> None:
        if os.environ.get("K8S_VIA", "tunnel") == "codebuild":
            if codebuild.run_build(self.env, "-", "db-restore", ["_k8s", step, *args]) != 0:
                lib.die(f"The {step} build failed (log above)")
        else:
            getattr(ProxySql(self.env), step)(*args)

    # --- phases ---
    def create(self, new: str, source: Source, from_id: str) -> None:
        if existing := self.rds.get(new):
            print(f"  {new} exists ({existing['DBInstanceStatus']}), not creating it again")
        else:
            old = self.rds.get(from_id) or lib.die(f"{from_id} not found")
            tags = [t for t in old.get("TagList", []) if not t["Key"].startswith("aws:")]
            settings = {
                "DBInstanceClass": old["DBInstanceClass"],
                "DBSubnetGroupName": old["DBSubnetGroup"]["DBSubnetGroupName"],
                "DBParameterGroupName": old["DBParameterGroups"][0]["DBParameterGroupName"],
                "VpcSecurityGroupIds": [g["VpcSecurityGroupId"] for g in old["VpcSecurityGroups"]],
                "StorageType": old["StorageType"],
                "MultiAZ": old["MultiAZ"],
                "PubliclyAccessible": False,
                "CopyTagsToSnapshot": True,
                "Tags": [*tags, {"Key": "RestoredFrom", "Value": source.tag}],
            }
            if logs := old.get("EnabledCloudwatchLogsExports"):
                settings["EnableCloudwatchLogsExports"] = logs
            client = self.rds.client
            if source.kind == "snapshot":
                client.restore_db_instance_from_db_snapshot(
                    DBInstanceIdentifier=new, DBSnapshotIdentifier=source.value, **settings
                )
            else:
                point = (
                    {"UseLatestRestorableTime": True}
                    if source.kind == "latest"
                    else {"RestoreTime": datetime.fromisoformat(source.value)}
                )
                client.restore_db_instance_to_point_in_time(
                    TargetDBInstanceIdentifier=new, SourceDbiResourceId=old["DbiResourceId"], **point, **settings
                )
            print(f"  creating {new} from {source.kind} {source.value} (settings of {from_id})")
        self.rds.wait_available(new)

        # Settings the restore calls do not take; Terraform reconciles anything else at finalize.
        old, created = self.rds.get(from_id) or {}, self.rds.get(new) or {}
        modify = {}
        if old and created.get("BackupRetentionPeriod") != old["BackupRetentionPeriod"]:
            modify |= {
                "BackupRetentionPeriod": old["BackupRetentionPeriod"],
                "PreferredBackupWindow": old["PreferredBackupWindow"],
                "PreferredMaintenanceWindow": old["PreferredMaintenanceWindow"],
            }
            if old.get("MaxAllocatedStorage"):
                modify["MaxAllocatedStorage"] = old["MaxAllocatedStorage"]
        # A restored instance keeps the source's master password but not its Secrets Manager link (the restore
        # calls reject ManageMasterUserPassword for MySQL): turn it on here, so the secret exists before cutover.
        if not created.get("MasterUserSecret"):
            modify["ManageMasterUserPassword"] = True
        if modify:
            self.rds.client.modify_db_instance(DBInstanceIdentifier=new, ApplyImmediately=True, **modify)
            time.sleep(30)  # the modification shows up in the status a little later
            self.rds.wait_available(new)
        print(f"  {new} available: {(self.rds.get(new) or {}).get('Endpoint', {}).get('Address')}")

    def finalize(self, new: str) -> None:
        stack = [str(lib.SCRIPTS / "run-stack.sh"), self.env.name, "database"]
        managed = self.env.db_instance_id()
        if managed != new:
            if managed:
                self._ok(lib.run(*stack, "state", "rm", "aws_db_instance.this"), "state rm")
            self._ok(lib.run(*stack, "import", "aws_db_instance.this", new), f"import {new}")
            print(f"  state: aws_db_instance.this is now {new} (was {managed or 'none'}, still running until retire)")
        else:
            print(f"  state already points at {new}")

        tf = ["terraform", f"-chdir={lib.ROOT / 'stacks/database'}"]
        with tempfile.TemporaryDirectory() as tmp:
            plan = f"{tmp}/plan"
            self._ok(lib.run(*stack, "plan", "-input=false", "-no-color", f"-out={plan}"), "plan database")
            changes = (
                json.loads(self._ok(lib.run(*tf, "show", "-json", plan), "show plan")).get("resource_changes") or []
            )
            if any(c["address"] == "aws_db_instance.this" and "delete" in c["change"]["actions"] for c in changes):
                lib.die(
                    f"The database plan would replace {new}: stopped before applying "
                    f"(see make plan STACK=database ENV={self.env.name})"
                )
            out = self._ok(lib.run(*tf, "apply", "-input=false", "-no-color", plan), "apply database")
            for line in out.splitlines():
                if line.startswith("Apply complete") or re.search(r": (Modifying|Creating|Destroying)", line):
                    print(f"  {line}")
        # app-aws: db-admin reads the new master secret. app-k8s: the user Job re-syncs against the new
        # instance; the ProxySQL ConfigMap already says so, the app's config does not change.
        for name in ("app-aws", "app-k8s"):
            rc = lib.run_live(str(lib.SCRIPTS / "run-env.sh"), "up", self.env.name, "-auto-approve", env={"ONLY": name})
            if rc != 0:
                lib.die(f"Applying {name} failed (above). Re-run the same command to continue.")

    @staticmethod
    def _ok(proc, what: str) -> str:
        if proc.returncode != 0:
            lib.die(f"{what} failed:\n{proc.stdout}")
        return proc.stdout

    def switch_to(self, instance_id: str, *, stop_before_cutover: bool = False) -> bool:
        """check, cutover, finalize. False if it stopped before the cutover."""
        if os.environ.get("K8S_VIA", "tunnel") == "codebuild":
            return self._switch_to(instance_id, stop_before_cutover)
        lib.say("tunnel to the Kubernetes API")
        with lib.Tunnel(self.env):  # finalize's run-env.sh reuses it
            return self._switch_to(instance_id, stop_before_cutover)

    def _switch_to(self, instance_id: str, stop_before_cutover: bool) -> bool:
        instance = self.rds.get(instance_id) or {}
        endpoint = instance["Endpoint"]
        host, port = endpoint["Address"], str(endpoint["Port"])
        db_name = self.env.tf_outputs("database").get("db_name") or "app"
        lib.say(f"users on {instance_id}: set to their current secrets")
        self.k8s("sync_users", host, port, db_name, instance["MasterUserSecret"]["SecretArn"])
        lib.say(f"check {instance_id}")
        self.k8s("check", host, port, db_name)
        if stop_before_cutover:
            print(
                f"\nStopped before the cutover. The apps still use {self.env.db_instance_id()}. "
                f"Look at the restored data, e.g.:\n"
                f'  DB_ID={instance_id} scripts/db-sql.sh {self.env.name} "SHOW TABLES FROM {db_name}"\n'
                "Then run the same command again without --stop-before-cutover."
            )
            return False
        lib.say(f"cutover to {instance_id}")
        self.k8s("cutover", host, port)
        lib.say(f"finalize: Terraform follows {instance_id}")
        self.finalize(instance_id)
        return True

    # --- commands ---
    def restore(self, source: Source, *, stop_before_cutover: bool) -> None:
        from_id = self.env.db_instance_id()
        current = self.rds.get(from_id) if from_id else None
        if not current or current["DBInstanceStatus"] != "available":
            lib.die(
                f"No live instance in database for '{self.env.name}' ({from_id or 'none'}). Without one: "
                f"TF_VAR_restore_snapshot_id=<id> make up-all ENV={self.env.name} (see list)"
            )
        # Re-run after it finished: Terraform already manages the instance restored from this source.
        tags = {t["Key"]: t["Value"] for t in current.get("TagList", [])}
        if tags.get("RestoredFrom") == source.tag:
            print(
                f"Already done: {from_id} was restored from {source.kind} {source.value} and is the instance "
                "the apps use. To restore again, pick another point (list)."
            )
            return
        new = source.instance_name(self.prefix, from_id)
        lib.say(f"create {new} ({source.kind} {source.value}) next to {from_id}")
        self.create(new, source, from_id)
        if self.switch_to(new, stop_before_cutover=stop_before_cutover):
            print(
                f"\nDone: the apps use {new}, and Terraform manages it. {from_id} is still running:\n"
                f"  switch back:  {self.cmd(f'rollback {from_id}')}\n"
                f"  delete it:    {self.cmd(f'retire {from_id}')}   "
                f"(final snapshot kept; outside dev with CONFIRM={self.env.name})"
            )

    def rollback(self, target: str) -> None:
        self._own(target, "rollback")
        if self.rds.status(target) != "available":
            lib.die(f"{target} is not available")
        self.switch_to(target)

    def retire(self, target: str) -> None:
        self._own(target, "retire")
        if target == self.env.db_instance_id():
            lib.die(f"{target} is the instance Terraform manages (and the apps use): not retiring it")
        self.env.require_destroy_confirm()
        instance = self.rds.get(target) or lib.die(f"{target} not found (already deleted?): see {self.cmd('list')}")
        if instance["DBInstanceStatus"] == "deleting":  # a re-run: the delete already started
            print(f"{target} is already being deleted")
        else:
            if instance.get("DeletionProtection"):
                self.rds.client.modify_db_instance(
                    DBInstanceIdentifier=target, DeletionProtection=False, ApplyImmediately=True
                )
            final = f"{target}-final-{datetime.now(UTC):%Y%m%d%H%M}"
            self.rds.client.delete_db_instance(
                DBInstanceIdentifier=target, FinalDBSnapshotIdentifier=final, DeleteAutomatedBackups=False
            )
            print(f"Deleting {target}; final snapshot {final}, automated backups kept until their retention ends.")
        # Wait until it is gone: until then it holds the database stack's subnet group and security group,
        # so a down-all right after would fail to destroy them. RDS deletes it once the final snapshot is done.
        self.rds.wait_deleted(target)
        print(f"{target} deleted")

    def _own(self, target: str, command: str) -> None:
        if not target.startswith(self.prefix):
            lib.die(f"{command} needs an instance of this env ({self.prefix}...): see {self.cmd('list')}")

    def list(self) -> None:
        p = self.prefix
        print(f"== Instances ({p}*), Terraform manages: {self.env.db_instance_id() or 'none'}")
        instances = self.rds.all(
            "describe_db_instances", "DBInstances", lambda i: i["DBInstanceIdentifier"].startswith(p)
        )
        lib.table(
            [
                {
                    "id": i.get("DBInstanceIdentifier"),
                    "status": i.get("DBInstanceStatus"),
                    "created": ts(i.get("InstanceCreateTime")),
                    "latest restorable": ts(i.get("LatestRestorableTime")),
                }
                for i in instances
            ],
            ["id", "status", "created", "latest restorable"],
        )

        print("\n== PITR windows (live instances and retained automated backups)  -> restore <UTC time> | latest")
        backups = self.rds.all(
            "describe_db_instance_automated_backups",
            "DBInstanceAutomatedBackups",
            lambda b: b["DBInstanceIdentifier"].startswith(p),
        )
        lib.table(
            [
                {
                    "instance": b.get("DBInstanceIdentifier"),
                    "resource id": b.get("DbiResourceId"),
                    "status": b.get("Status"),
                    "earliest": ts(b.get("RestoreWindow", {}).get("EarliestTime")),
                    "latest": ts(b.get("RestoreWindow", {}).get("LatestTime")),
                }
                for b in backups
            ],
            ["instance", "resource id", "status", "earliest", "latest"],
        )

        print("\n== DB snapshots (manual, final, automated)  -> restore <id>")
        snapshots = self.rds.all(
            "describe_db_snapshots",
            "DBSnapshots",
            lambda s: s["DBSnapshotIdentifier"].startswith(p) or s.get("DBInstanceIdentifier", "").startswith(p),
        )
        snapshots.sort(key=lambda s: s.get("SnapshotCreateTime") or datetime.max.replace(tzinfo=UTC), reverse=True)
        lib.table(
            [
                {
                    "id": s.get("DBSnapshotIdentifier"),
                    "type": s.get("SnapshotType"),
                    "created": ts(s.get("SnapshotCreateTime")),
                    "status": s.get("Status"),
                }
                for s in snapshots
            ],
            ["id", "type", "created", "status"],
        )

        vault = p.rstrip("-")
        print(f"\n== AWS Backup recovery points (vault {vault})  -> restore <ARN>")
        backup = self.session.client("backup")
        try:
            pages = backup.get_paginator("list_recovery_points_by_backup_vault").paginate(BackupVaultName=vault)
            points = [r for page in pages for r in page["RecoveryPoints"]]
        except botocore.exceptions.ClientError as e:  # a vault that does not exist answers AccessDeniedException
            print(f"   (no vault, or not readable: {e.response['Error']['Code']})")
        else:
            points.sort(key=lambda r: r.get("CreationDate") or datetime.min.replace(tzinfo=UTC), reverse=True)
            lib.table(
                [
                    {"arn": r.get("RecoveryPointArn"), "created": ts(r["CreationDate"]), "status": r.get("Status")}
                    for r in points
                ],
                ["arn", "created", "status"],
            )

        now = datetime.now(UTC)
        e = self.env.name
        print(
            f"\nLive instance:  {self.cmd(f'restore <UTC, e.g. {ts(now)}>')}   (or latest, a snapshot id / ARN)\n"
            f"No instance:    TF_VAR_restore_snapshot_id=<id> make up-all ENV={e}   (or make up STACK=database)\n"
            f'                TF_VAR_restore_point_in_time=\'{{source_dbi_resource_id="<resource id>",'
            f'restore_time="<UTC>"}}\' make up-all ENV={e}\n'
            "                (create-time only: nothing to commit, nothing to undo)"
        )


# ------------------------------------------------------------------------------
def add_parser(commands) -> None:
    parser = commands.add_parser(
        "db-restore",
        help="MySQL restore next to the live instance, with a ProxySQL cutover",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("env", metavar="<env>")
    parser.set_defaults(run=run)
    actions = parser.add_subparsers(dest="action", required=True, metavar="{list,restore,rollback,retire}")
    actions.add_parser("list", help="what can be restored (read-only)")
    restore = actions.add_parser("restore", help="restore next to the live instance and switch to it")
    restore.add_argument(
        "point",
        help="latest (the latest restorable time), a UTC time like 2026-01-31T12:00:00Z, "
        "or a DB snapshot id / AWS Backup recovery point ARN (see list)",
    )
    restore.add_argument("--stop-before-cutover", action="store_true", help="stop after the check")
    actions.add_parser("rollback", help="switch back to an instance that still exists").add_argument("instance")
    actions.add_parser("retire", help="delete an instance nothing uses").add_argument("instance")
    k8s = actions.add_parser("_k8s")  # internal: the Kubernetes steps, run by the CodeBuild build
    k8s.add_argument("step", choices=["sync_users", "check", "cutover"])
    k8s.add_argument("args", nargs="+")


def run(args: argparse.Namespace) -> int:
    env = lib.Env.load(args.env)
    if args.action == "_k8s":
        getattr(ProxySql(env), args.step)(*args.args)
        return 0
    job = Restore(env)
    match args.action:
        case "list":
            job.list()
        case "restore":
            job.restore(Source.parse(args.point), stop_before_cutover=args.stop_before_cutover)
        case "rollback":
            job.rollback(args.instance)
        case "retire":
            job.retire(args.instance)
    return 0
