# Access

People and CI get access by **assuming a role**. Nobody is added to the cluster directly, and nobody is admin just for having created it.

- [Roles](#roles)
- [Add a reviewer](#add-a-reviewer)
- [Connect as a reviewer](#connect-as-a-reviewer)
- [Revoke access](#revoke-access)
- [Other identities](#other-identities)

## Roles

The `access` stack creates these per environment. For why they live there, see [Why roles live in access](ENVIRONMENTS.md#why-roles-live-in-access).

| Role | Who may assume it | What it can do |
|---|---|---|
| `<project>-<env>-admin` | `admin_principal_arns` | Open the tunnel, describe the cluster, cluster-admin in Kubernetes |
| `<project>-<env>-viewer` | `viewer_principal_arns` | The same tunnel and describe, read-only in Kubernetes |
| `<project>-<env>-github-plan` | Any workflow run of the repository | AWS read-only, read the env's state |
| `<project>-<env>-github-apply` | Only jobs bound to the GitHub Environment `<env>` | `AdministratorAccess` in this demo, no Kubernetes access: it starts a CodeBuild build for `app-k8s` |

**An empty ARN list means the whole account:** any principal in this account that is allowed `sts:AssumeRole` can use the role. List ARNs to narrow it down, which you will want as soon as more than a few people share the account.

## Add a reviewer

Access is a reviewed change: a pull request adds an ARN, and an apply turns it on. There is deliberately no shortcut, for two reasons. The change stays reviewed and in history, and a manual edit to the trust policy would be undone by the next apply anyway.

Adding someone takes a minute and doesn't touch the cluster.

### 1. Ask for their account ID

`aws sts get-caller-identity` shows it as `Account`.

### 2. Add it

```hcl
# envs/overlays/dev/access.tfvars
viewer_principal_arns = [
  "arn:aws:iam::<their account id>:root",
]
```

**`:root` means their whole account, not its root user.** Their own account then decides who may assume the role, by granting `sts:AssumeRole` on it. It is the simplest ARN that works, because IAM accepts it without checking any user.

**To name one person instead,** use the user or role ARN that `get-caller-identity` shows:

- An IAM user: `arn:aws:iam::<account id>:user/<path/>reviewer`, including any path.
- An assumed role, such as SSO: `arn:aws:iam::<account id>:role/<role name>`, the role's ARN and not the session's.

That ARN has to exist: IAM checks it when saving the trust policy, and the apply fails with `MalformedPolicyDocument: Invalid principal in policy` otherwise. Naming a person also lets `make revoke --principal` block just them, rather than their whole account.

Either way, someone from another account also needs `sts:AssumeRole` on this role's ARN, granted in their own account. Trust on this side alone is not enough.

Use `admin_principal_arns` for cluster-admin. Remember that a list replaces the previous layer, and that a non-empty list stops the whole-account default.

### 3. Open a pull request

`ci.yml` plans `access` for each env, so the trust change shows up for review.

### 4. Apply it

After merging, either run `apply.yml` with `env = dev`, `stack = access`, `action = apply`, or locally:

```bash
make access ENV=dev
```

The cluster needs nothing: the role already has its access entry.

### 5. Send them the details

Send the role ARN, the region and the env name. `make output STACK=access ENV=dev` prints the ARN.

## Connect as a reviewer

You need no Terraform, state or GitHub access. You need a clone of this repository (for its scripts), the `aws` CLI, `kubectl` and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

Create a profile that assumes the role, in `~/.aws/config`:

```ini
[profile dev-viewer]
role_arn         = <viewer role arn>
source_profile   = default
region           = us-east-1
duration_seconds = 3600
```

Then:

```bash
export AWS_PROFILE=dev-viewer

make tunnel ENV=dev                   # terminal 1: keep it running

export AWS_PROFILE=dev-viewer         # terminal 2
make kubeconfig ENV=dev ROLE=         # ROLE= uses the assumed role as it is
export KUBECONFIG=.kube/dev.kubeconfig
kubectl get pods -A
```

A role assumed from another role lasts at most 1 hour, which is an AWS limit. If you sign in as an IAM user or through SSO, you can raise `duration_seconds` to the 4 hours the role allows.

## Revoke access

### Now

```bash
make revoke ENV=dev ARGS='viewer --principal arn:aws:iam::123456789012:user/reviewer'
```

This needs no commit and no apply, and it takes effect as soon as IAM propagates, usually within seconds. It does three things, in order:

1. **Stops them assuming the role again:** `--principal` adds a Deny to the role's trust policy.
2. **Denies older sessions:** an inline policy denies everything to sessions issued before now.
3. **Closes the path to the cluster:** it terminates the role's open SSM tunnels, and lists any other sessions it left open, which may include stale ones for instances that no longer exist.

Step 3 matters most. An explicit deny [does not stop `sts:GetCallerIdentity`](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html), which EKS tokens are built on, so a denied session may still sign a token. It has nowhere to use one once the tunnel is closed and it cannot open a new one.

**Everyone on the role is affected.** Everyone's current session on that role ends, but they can simply assume it again. Only the principal you name stays blocked. Without `--principal`, the person you meant to remove can do the same, so use it unless you only want to end sessions.

### Then permanently

Remove the ARN from `envs/overlays/<env>/access.tfvars`, and apply through a pull request as in [Add a reviewer](#add-a-reviewer).

**Forgetting this fails loudly.** An apply rewrites the trust policy and would drop the Deny, letting that person back in. So every plan and apply of `access`, including the plan on every pull request, fails until the ARN is gone:

```
Error: Resource precondition failed
sword-dev-viewer: revoked but still trusted: <arn>. Remove them from the role's principal ARNs in access.tfvars...
```

**If the role has an empty ARN list,** it trusts the whole account, so there is no ARN to remove. List who may assume it instead.

The inline policy is not managed by Terraform and can stay, because it only matches sessions older than itself.

## Other identities

Roles managed elsewhere, such as SSO roles, can be given cluster access directly in `envs/overlays/<env>/eks.tfvars`. Use names rather than ARNs, and without the path for SSO roles:

```hcl
extra_viewer_role_names = ["AWSReservedSSO_ReadOnly_0123456789abcdef"]
extra_admin_role_names  = ["AWSReservedSSO_Admin_0123456789abcdef"]
```

These bypass the `admin` and `viewer` roles, so `make revoke` does not cover them. Remove them from the list and apply `eks` to take access away.

Terraform itself never needs direct cluster access from you. `app-k8s` gets its Kubernetes token as the admin role, so your identity only has to be able to assume that role.
