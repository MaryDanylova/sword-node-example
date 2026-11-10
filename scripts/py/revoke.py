"""Cut a role's access now, with no commit and no Terraform apply. Run it first, then make it permanent.

Usage: make revoke ENV=<env> ARGS='admin|viewer [--principal <arn>]'

In this order:
  1. --principal only: a Deny for that principal in the role's trust policy, so they cannot assume
     the role again. Without it, whoever the role trusts can start a new session straight away.
  2. An inline policy on the role that denies everything to sessions issued before now.
  3. Every open SSM tunnel of the role is terminated.

Step 3 is what closes the cluster: an explicit deny does not stop sts:GetCallerIdentity, which EKS
tokens are built on, so a denied session can still sign a token. It needs the tunnel to use it.

Everyone on the role loses their session, not only the principal named. They can assume the role
again and carry on, because only sessions issued before the command are denied.

Make it permanent: remove the ARN from envs/overlays/<env>/access.tfvars and `make access ENV=<env>`.
That apply rewrites the trust policy and drops the Deny. Until the ARN is gone, plans and applies of
`access` fail on purpose (modules/assumable-role), so a revoked principal cannot quietly get back in.
If the role has no principal ARNs it trusts the whole account, so list who may assume it instead.
The inline policy is not managed by Terraform and can stay: it only matches sessions older than it.
"""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime

import boto3
import lib

REVOKE_POLICY = "revoke-older-sessions"
DENY_SID = "RevokedPrincipals"


def deny_principal(iam, role: str, principal: str) -> None:
    """Add the principal to the Deny statement of the role's trust policy."""
    trust = iam.get_role(RoleName=role)["Role"]["AssumeRolePolicyDocument"]
    statements = trust["Statement"]
    deny = next((s for s in statements if s.get("Sid") == DENY_SID), None)
    if deny is None:
        deny = {"Sid": DENY_SID, "Effect": "Deny", "Principal": {"AWS": []}, "Action": "sts:AssumeRole"}
        statements.append(deny)
    denied = deny["Principal"]["AWS"]
    denied = [denied] if isinstance(denied, str) else denied
    if principal not in denied:
        denied.append(principal)
    deny["Principal"]["AWS"] = denied
    iam.update_assume_role_policy(RoleName=role, PolicyDocument=json.dumps(trust))
    lib.say(f"Trust policy of {role}: {principal} denied")


def deny_older_sessions(iam, role: str, now: str) -> None:
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Deny",
                "Action": "*",
                "Resource": "*",
                "Condition": {"DateLessThan": {"aws:TokenIssueTime": now}},
            }
        ],
    }
    iam.put_role_policy(RoleName=role, PolicyName=REVOKE_POLICY, PolicyDocument=json.dumps(policy))
    lib.say(f"Inline policy {REVOKE_POLICY} on {role}: sessions issued before {now} are denied")


def terminate_tunnels(ssm, role: str) -> list[dict]:
    """Terminate the role's active SSM sessions. Returns the active sessions it left alone."""
    others = []
    for page in ssm.get_paginator("describe_sessions").paginate(State="Active"):
        for session in page["Sessions"]:
            if f"assumed-role/{role}/" in session.get("Owner", ""):
                ssm.terminate_session(SessionId=session["SessionId"])
                lib.say(f"Terminated {session['SessionId']} ({session['Owner']})")
            else:
                others.append(session)
    return others


def add_parser(commands) -> None:
    parser = commands.add_parser(
        "revoke",
        help="cut a role's access now, without a commit or an apply",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("env", metavar="<env>")
    parser.add_argument("role", choices=["admin", "viewer"])
    parser.add_argument("--principal", metavar="<arn>", help="also stop this principal assuming the role again")
    parser.set_defaults(run=run)


def run(args: argparse.Namespace) -> int:
    env = lib.Env.load(args.env)
    session = boto3.Session(region_name=env.region)
    iam = session.client("iam")
    role = f"{env.cluster}-{args.role}"
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    if args.principal:
        deny_principal(iam, role, args.principal)
    deny_older_sessions(iam, role, now)
    others = terminate_tunnels(session.client("ssm"), role)

    if others:
        lib.say("Other active SSM sessions, left open (not started through this role):")
        for s in others:
            print(f"  {s['SessionId']}  {s.get('Target', '-')}  {s.get('Owner', '-')}")
    if args.principal:
        lib.say(
            f"Now make it permanent: remove {args.principal} from envs/overlays/{env.name}/access.tfvars, "
            f"then make access ENV={env.name}. Plans and applies of access fail until then."
        )
    else:
        lib.say("Whoever the role trusts can assume it again: use --principal, or change the trust in access.tfvars.")
    return 0
