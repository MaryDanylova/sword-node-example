"""End-to-end checks of the requirements, from this machine and from short-lived debug pods.

Needs `make tunnel ENV=<env>` running in another terminal and `make kubeconfig ENV=<env>` done once.

Usage: scripts/py/main.py verify <env>        (make verify ENV=dev)

Debug pods:
  - in the app namespace, under the app ServiceAccount: same Pod Identity role and RBAC as the app
  - in `default`: an "other" pod, for the network isolation checks
  - deleted on exit
AWS calls made with your own credentials (from this machine) use boto3; the ones that must run
as the app go through `kubectl exec` into the debug pods.
"""

from __future__ import annotations

import argparse
import http.client
import json
import socket
import ssl
import sys
import tempfile
import time
from contextlib import contextmanager

import boto3
import lib

NS = "app"
SA = "node-example"
SVC = "node-example"
USERS_BODY = "respond with a resource"  # GET /users in swordhealth/node-example (routes/users.js)
APP_PORT = 3000
AWS_IMAGE = "amazon/aws-cli:2.37.12"
CURL_IMAGE = "curlimages/curl:8.22.0"
MYSQL_IMAGE = "mysql:8.4"
RUN_ID = str(int(time.time()))
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

report = lib.Report()


@contextmanager
def debug_pods(kube: lib.Kube, region: str, specs: list[tuple[str, str, str, str | None, int]]):
    """Start restricted-PSS-compliant pods that just sleep, wait until ready, delete them on exit.

    specs: (key, namespace, image, serviceAccount or None, uid). Yields {key: Pod}.
    """
    pods = {}
    try:
        for key, ns, image, sa, uid in specs:
            name = f"verify-{key}-{RUN_ID}"
            spec = {
                "restartPolicy": "Never",
                "terminationGracePeriodSeconds": 1,  # sleep ignores SIGTERM: do not wait 30s on cleanup
                "securityContext": {
                    "runAsNonRoot": True,
                    "runAsUser": uid,
                    "runAsGroup": uid,
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                "containers": [
                    {
                        "name": "main",
                        "image": image,
                        "command": ["sleep", "900"],
                        "env": [{"name": "HOME", "value": "/tmp"}, {"name": "AWS_REGION", "value": region}],
                        "securityContext": {
                            "runAsNonRoot": True,
                            "allowPrivilegeEscalation": False,
                            "capabilities": {"drop": ["ALL"]},
                        },
                    }
                ],
            }
            if sa:
                spec["serviceAccountName"] = sa
            manifest = {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {"name": name, "namespace": ns, "labels": {"app.kubernetes.io/name": "verify"}},
                "spec": spec,
            }
            pods[key] = lib.Pod(kube, ns, name)
            proc = kube.kubectl("apply", "-f", "-", input=json.dumps(manifest))
            if proc.returncode != 0:
                sys.exit(f"Could not create debug pod {ns}/{name}:\n{proc.stdout}")
        for pod in pods.values():
            if (
                kube.kubectl(
                    "wait", "--for=condition=Ready", "-n", pod.ns, f"pod/{pod.name}", "--timeout=180s"
                ).returncode
                != 0
            ):
                describe = kube.kubectl("describe", "pod", "-n", pod.ns, pod.name).stdout
                sys.exit(f"Debug pod {pod.ns}/{pod.name} did not start:\n" + "\n".join(describe.splitlines()[-15:]))
        yield pods
    finally:
        for pod in pods.values():
            kube.kubectl("delete", "pod", "--ignore-not-found", "--wait=false", "-n", pod.ns, pod.name)


# ------------------------------------------------------------------------------
# Expectations on a finished command
# ------------------------------------------------------------------------------
def expect_ok(desc: str, proc) -> None:
    report.check(proc.returncode == 0, desc, proc.stdout)


def expect_denied(desc: str, proc) -> None:
    """An AWS CLI call in a pod must fail with an authorization error code, not just any error."""
    if proc.returncode == 0:
        report.bad(f"{desc} (unexpectedly allowed)", proc.stdout)
    elif lib.AWS_DENIED.search(proc.stdout):
        report.ok(desc)
    else:
        report.bad(f"{desc} (failed, but not with an authorization error)", proc.stdout)


def expect_dropped(desc: str, proc) -> None:
    """A curl in a pod must time out (exit 28): the NetworkPolicy drops the packets."""
    report.check(
        proc.returncode == 28, desc, proc.stdout, failed=f"{desc} (curl exit {proc.returncode}, expected 28 = timeout)"
    )


def curl(pod: lib.Pod, url: str, *extra: str):
    return pod.exec("curl", "-s", "--max-time", "5", *extra, url)


def curl_code(pod: lib.Pod, url: str, *extra: str) -> str:
    return curl(pod, url, "-o", "/dev/null", "-w", "%{http_code}", *extra).stdout.strip()


def http_get(host: str, path: str = "/", *, https: bool = False, cafile: str | None = None) -> tuple[str, str]:
    """(status, body) of GET path without following redirects, or ("error: ...", "")."""
    try:
        if https:
            ctx = ssl.create_default_context(cafile=cafile)
            conn = http.client.HTTPSConnection(host, timeout=10, context=ctx)
        else:
            conn = http.client.HTTPConnection(host, timeout=10)
        conn.request("GET", path)
        resp = conn.getresponse()
        return str(resp.status), resp.read().decode(errors="replace")
    except (OSError, ssl.SSLError) as e:
        return f"error: {e}", ""


def check_users_route(base: str, get) -> None:
    """GET /users reaches the app's own route (not only the / used by the probes and the health check)."""
    code, body = get("/users")
    report.check(
        code == "200" and body.strip() == USERS_BODY,
        f"{base}/users -> 200 '{USERS_BODY}'",
        failed=f"{base}/users -> {code} {body.strip()[:80]!r}",
    )


# ------------------------------------------------------------------------------
# Checks
# ------------------------------------------------------------------------------
def check_api_private(env: lib.Env, kube: lib.Kube, eks) -> None:
    report.section("1. Cluster API is private")
    cluster = eks.describe_cluster(name=env.cluster)["cluster"]
    public = cluster["resourcesVpcConfig"]["endpointPublicAccess"]
    report.check(public is False, f"endpointPublicAccess = {str(public).lower()}")
    host = cluster["endpoint"].removeprefix("https://")
    try:
        socket.create_connection((host, 443), timeout=5).close()
        report.bad("endpoint reachable from this machine without the tunnel")
    except OSError as e:
        report.ok(f"endpoint not reachable from this machine without the tunnel ({type(e).__name__})")
    expect_ok("kubectl works through the tunnel", kube.kubectl("get", "--raw", "/version"))


def check_app_aws(env: lib.Env, cfg: dict, aws_pod: lib.Pod, sqs, rds) -> str:
    """Returns the app's DB secret JSON ("" if not readable)."""
    report.section("2. App AWS permissions (Pod Identity, from a pod with the app ServiceAccount)")
    aws = lambda *args: aws_pod.exec("aws", *args)  # noqa: E731 - short alias for readability below
    read, write, queue = cfg.get("READ_BUCKET", ""), cfg.get("WRITE_BUCKET", ""), cfg.get("QUEUE_URL", "")
    key = f"verify-{RUN_ID}.txt"

    arn = aws("sts", "get-caller-identity", "--query", "Arn", "--output", "text").stdout.strip()
    report.check(f":assumed-role/{env.cluster}-app/" in arn, f"pod runs as role {env.cluster}-app", arn)

    expect_ok("read bucket:  ListBucket", aws("s3api", "list-objects-v2", "--bucket", read, "--max-items", "1"))
    expect_ok("read bucket:  GetObject hello.txt", aws("s3", "cp", f"s3://{read}/hello.txt", "-"))
    expect_denied("read bucket:  PutObject denied", aws_pod.sh('echo x | aws s3 cp - "$0"', f"s3://{read}/{key}"))
    expect_ok("write bucket: PutObject", aws_pod.sh('echo verify | aws s3 cp - "$0"', f"s3://{write}/{key}"))
    expect_denied(
        "write bucket: ListBucket denied", aws("s3api", "list-objects-v2", "--bucket", write, "--max-items", "1")
    )
    expect_denied(
        "write bucket: GetObject denied", aws("s3api", "get-object", "--bucket", write, "--key", key, "/tmp/out")
    )

    # The message is sent with *your* credentials: the app role must not be able to send.
    sqs.send_message(QueueUrl=queue, MessageBody=f"verify-{RUN_ID}")
    proc = aws(
        "sqs",
        "receive-message",
        "--queue-url",
        queue,
        "--wait-time-seconds",
        "10",
        "--max-number-of-messages",
        "1",
        "--query",
        "Messages[0].ReceiptHandle",
        "--output",
        "text",
    )
    handle = proc.stdout.strip()
    if proc.returncode == 0 and handle not in ("", "None"):
        report.ok("queue: ReceiveMessage")
        expect_ok(
            "queue: DeleteMessage", aws("sqs", "delete-message", "--queue-url", queue, "--receipt-handle", handle)
        )
    else:
        report.bad("queue: ReceiveMessage (no message received)", proc.stdout)
    expect_denied(
        "queue: SendMessage denied", aws("sqs", "send-message", "--queue-url", queue, "--message-body", "nope")
    )

    secret_arn = cfg.get("DB_SECRET_ARN", "")
    if not secret_arn:
        return ""
    proc = aws(
        "secretsmanager", "get-secret-value", "--secret-id", secret_arn, "--query", "SecretString", "--output", "text"
    )
    db_secret = proc.stdout if proc.returncode == 0 else ""
    report.check(bool(db_secret), "secrets manager: GetSecretValue on the DB secret", proc.stdout)

    # The app has its own MySQL user; the master secret is for admins and the db-admin Job only.
    if instance := env.db_instance_id():
        db = rds.describe_db_instances(DBInstanceIdentifier=instance)["DBInstances"][0]
        if master := db.get("MasterUserSecret", {}).get("SecretArn"):
            expect_denied(
                "secrets manager: master DB secret denied",
                aws("secretsmanager", "get-secret-value", "--secret-id", master, "--query", "ARN", "--output", "text"),
            )
    return db_secret


def check_rbac(app_curl: lib.Pod) -> None:
    report.section("3. Bonus RBAC: the app may list pods in kube-system (from inside the pod, SA token)")
    script = (
        'curl -s -o /dev/null -w "%{http_code}" --cacert "$1/ca.crt" -H "Authorization: Bearer $(cat "$1/token")" '
        '"https://kubernetes.default.svc/api/v1/namespaces/$0/pods"'
    )
    for ns, want in (("kube-system", "200"), ("default", "403")):
        code = app_curl.sh(script, ns, SA_DIR).stdout.strip()
        report.check(code == want, f"GET pods in {ns} -> {code}", failed=f"GET pods in {ns} -> {code} (want {want})")


def check_network(kube: lib.Kube, cfg: dict, app_curl: lib.Pod, other: lib.Pod) -> None:
    report.section("4. Network isolation: no pod can reach the app")
    code = curl_code(other, "https://kubernetes.default.svc/version", "-k")
    report.check(code.isdigit() and code != "000", f"control: pod in default has working network (API -> {code})")
    app_ip = kube.pod_ip(NS, f"app.kubernetes.io/name={SVC}")
    expect_dropped(f"pod in default -> service {SVC}.{NS}:80 dropped", curl(other, f"http://{SVC}.{NS}.svc/"))
    expect_dropped(
        f"pod in default -> app pod {app_ip}:{APP_PORT} dropped", curl(other, f"http://{app_ip}:{APP_PORT}/")
    )
    expect_dropped(f"pod in {NS} (same ns) -> service dropped", curl(app_curl, f"http://{SVC}.{NS}.svc/"))
    if host := cfg.get("DB_HOST"):
        port = cfg.get("DB_PORT", "")
        expect_dropped(f"pod in default -> ProxySQL {host}:{port} dropped", curl(other, f"telnet://{host}:{port}"))


def check_mysql(kube: lib.Kube, cfg: dict, db_secret: str, mysql_pod: lib.Pod | None) -> None:
    report.section("5. MySQL")
    host, port = cfg.get("DB_HOST", ""), cfg.get("DB_PORT", "")
    if not host or mysql_pod is None:
        report.bad("no DB_HOST in the app config (is database up? re-apply app-k8s)")
        return
    if not db_secret:
        report.bad("skipped: could not read the DB secret")
        return
    secret = json.loads(db_secret)
    user = secret["username"]

    def query(ssl_mode: str, sql: str):
        # The password goes over stdin, never into a pod spec or the process list.
        return mysql_pod.sh(
            'read -r P; MYSQL_PWD="$P" mysql -h "$0" -P "$1" -u "$2" --connect-timeout=5 --ssl-mode="$3" -N -e "$4"',
            host,
            port,
            user,
            ssl_mode,
            sql,
            input=secret["password"] + "\n",
        )

    # Ssl_version is the backend session's (ProxySQL -> MySQL). The client -> ProxySQL leg is TLS
    # too: ssl-mode=REQUIRED here, and plaintext is rejected below.
    proc = query(
        "REQUIRED",
        "SELECT CONCAT(VERSION(), ' backend tls=', (SELECT VARIABLE_VALUE "
        "FROM performance_schema.session_status WHERE VARIABLE_NAME='Ssl_version'))",
    )
    report.check(proc.returncode == 0, f"connect through ProxySQL over TLS: {proc.stdout.strip()}", proc.stdout)

    proc = query("DISABLED", "SELECT 1")
    if proc.returncode == 0:
        report.bad("plaintext connection unexpectedly allowed")
    else:
        rejected = "SSL is required" in proc.stdout or "secure transport" in proc.stdout.lower()
        report.check(
            rejected,
            "plaintext connection rejected",
            proc.stdout,
            failed="plaintext connection failed for another reason",
        )

    # Privileges on the app database only (granted by the db-admin Job in app-k8s).
    current = query("REQUIRED", "SELECT CURRENT_USER()").stdout.strip()
    report.check(
        current == f"{user}@%",
        f"connected as the app user {current} (from DB_SECRET_ARN)",
        failed=f"connected as {current}, expected {user}@%",
    )
    proc = query("REQUIRED", "CREATE DATABASE verify_denied")
    if proc.returncode == 0:
        query("REQUIRED", "DROP DATABASE verify_denied")
        report.bad("app user could create another database")
    else:
        report.check(
            "Access denied" in proc.stdout,
            "app user cannot create another database",
            proc.stdout,
            failed="CREATE DATABASE failed for another reason",
        )

    # Every ProxySQL pod sees its backend ONLINE (admin interface, local to the pod).
    px_ns = host.split(".")[1]
    admin_sql = "SELECT CONCAT(srv_host, ' ', status) FROM stats_mysql_connection_pool WHERE hostgroup = 10"
    for name in kube.pod_names(px_ns, "app.kubernetes.io/name=proxysql"):
        out = (
            lib.Pod(kube, px_ns, name)
            .sh('mysql -h127.0.0.1 -P6032 -uadmin -p"$(cat /config/admin_password)" -N -e "$0" 2>/dev/null', admin_sql)
            .stdout.strip()
        )
        report.check("ONLINE" in out, f"{name}: backend {out}", out, failed=f"{name}: backend not ONLINE")


def check_lb(env: lib.Env, elbv2, acm) -> None:
    report.section("6. Load balancer (lb, optional)")
    name = f"{env.cluster}-app"
    try:
        lb = elbv2.describe_load_balancers(Names=[name])["LoadBalancers"][0]
    except elbv2.exceptions.LoadBalancerNotFoundException:
        report.skip(f"no ALB {name} (enable_lb = false)")
        return
    dns = lb["DNSName"]

    tg = elbv2.describe_target_groups(Names=[name])["TargetGroups"][0]["TargetGroupArn"]
    health = elbv2.describe_target_health(TargetGroupArn=tg)["TargetHealthDescriptions"]
    states = " ".join(f"{t['Target']['Id']}={t['TargetHealth']['State']}" for t in health)
    report.check(
        "=healthy" in states, f"target group has healthy nodes: {states}", failed=f"no healthy targets: {states}"
    )

    # The pod only accepts traffic from the public-subnet CIDRs (NetworkPolicy). A 200 here proves
    # the ALB's own IP reaches the pod (externalTrafficPolicy=Local, no SNAT to the node IP).
    listeners = elbv2.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"])["Listeners"]
    cert_arn = next(
        (x["Certificates"][0]["CertificateArn"] for x in listeners if x["Port"] == 443 and x.get("Certificates")), None
    )
    code, _ = http_get(dns)
    if not cert_arn:
        report.check(
            code == "200", f"http://{dns}/ -> 200", failed=f"http://{dns}/ -> {code} (a new ALB's DNS can take 1-2 min)"
        )
        check_users_route(f"http://{dns}", lambda path: http_get(dns, path))
        return
    report.check(
        code == "301", f"http://{dns}/ -> 301 (redirect to HTTPS)", failed=f"http://{dns}/ -> {code}, expected 301"
    )

    # Verify the certificate for real: trust exactly the one the listener serves. An ACM-issued
    # certificate is in the system trust store; an imported (self-signed) one is not.
    with tempfile.NamedTemporaryFile("w", suffix=".pem") as ca:
        cafile = None
        if acm.describe_certificate(CertificateArn=cert_arn)["Certificate"]["Type"] == "IMPORTED":
            ca.write(acm.get_certificate(CertificateArn=cert_arn)["Certificate"])
            ca.flush()
            cafile = ca.name
        code, _ = http_get(dns, https=True, cafile=cafile)
        report.check(code == "200", f"https://{dns}/ -> 200 (certificate verified)", failed=f"https://{dns}/ -> {code}")
        check_users_route(f"https://{dns}", lambda path: http_get(dns, path, https=True, cafile=cafile))


# ------------------------------------------------------------------------------
def add_parser(commands) -> None:
    parser = commands.add_parser(
        "verify",
        help="end-to-end checks of an env (needs the tunnel)",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("env", metavar="<env>")
    parser.set_defaults(run=run)


def run(args: argparse.Namespace) -> int:
    env = lib.Env.load(args.env)
    session = boto3.Session(region_name=env.region)
    kube = lib.Kube(str(env.kubeconfig))

    report.section("Preflight")
    try:
        socket.create_connection(("localhost", env.local_port), timeout=2).close()
    except OSError:
        sys.exit(f"Tunnel is not running: start 'make tunnel ENV={env.name}' in another terminal.")
    if not env.kubeconfig.exists():
        sys.exit(f"Missing {env.kubeconfig}: run 'make kubeconfig ENV={env.name}'.")
    cfg = kube.configmap(NS, SVC)  # DB_HOST is ProxySQL (app-k8s), not the RDS endpoint
    db = cfg.get("DB_HOST") or "<none>"
    print(f"  cluster={env.cluster} read={cfg.get('READ_BUCKET')} write={cfg.get('WRITE_BUCKET')} db={db}")

    specs = [
        ("aws", NS, AWS_IMAGE, SA, 1000),
        ("curl", NS, CURL_IMAGE, SA, 100),
        ("other", "default", CURL_IMAGE, None, 100),
    ]
    if cfg.get("DB_HOST"):
        specs.append(("mysql", NS, MYSQL_IMAGE, None, 999))  # app namespace: ProxySQL only accepts clients from there
    with debug_pods(kube, env.region, specs) as pods:
        check_api_private(env, kube, session.client("eks"))
        db_secret = check_app_aws(env, cfg, pods["aws"], session.client("sqs"), session.client("rds"))
        check_rbac(pods["curl"])
        check_network(kube, cfg, pods["curl"], pods["other"])
        check_mysql(kube, cfg, db_secret, pods.get("mysql"))
        check_lb(env, session.client("elbv2"), session.client("acm"))
    return report.summary()
