# Deployment

Everything can run from your machine with `make`, and GitHub Actions is optional. Both use the same scripts, so a run behaves the same either way.

- [Choose a path](#choose-a-path)
- [Prerequisites](#prerequisites)
- [Without CI](#without-ci)
- [With GitHub Actions](#with-github-actions)
- [Tunnel or CodeBuild](#tunnel-or-codebuild)
- [Using the cluster](#using-the-cluster)
- [HTTPS](#https)
- [Tear down](#tear-down)
- [Try it in your own account](#try-it-in-your-own-account)

## Choose a path

| | Without CI | With GitHub Actions |
|---|---|---|
| **Who applies** | You, with your AWS credentials | A workflow you start by hand, with a role it assumes through OIDC |
| **Reaches the private API through** | An SSM tunnel | A CodeBuild build in the VPC |
| **Extra setup** | None | [OIDC provider, GitHub connection, GitHub Environment](#set-up-once) |
| **Set in `envs/base/access.tfvars`** | `github_repo = null` | `github_repo`, `github_aws_account_id` |
| **Plans on pull requests** | No | Yes |

The two mix freely: with CI set up, you can still run everything locally, and `K8S_VIA=codebuild make up-all` uses the CodeBuild path from your machine.

## Prerequisites

```bash
make init
```

This checks `terraform >= 1.11`, the `aws` CLI, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `kubectl` and [uv](https://docs.astral.sh/uv/), with `gh` optional. It shows your AWS identity and simulates one representative action per stack. The simulation is best effort, as it cannot see every SCP or resource policy. With CI configured, it also shows the GitHub connection's status.

## Without CI

Leave `github_repo = null` in `envs/base/access.tfvars`. `access` then creates no CI roles and `ci-runner` creates nothing.

```bash
make state  ENV=dev         # 1. the state bucket, once per environment
make access ENV=dev         # 2. the IAM roles
make up-all ENV=dev         # 3. everything else, in order
```

`up-all` opens a background tunnel for `app-k8s` by itself and closes it afterwards. It is safe to re-run after a failure, because finished stacks are no-ops.

To work on one stack at a time:

```bash
make plan-all ENV=dev                 # plan every stack, read-only
make plan     ENV=dev STACK=network
make up       ENV=dev STACK=network
make output   ENV=dev STACK=network
```

`make plan-all` skips a stack, with a note, if a stack it depends on is not applied.

## With GitHub Actions

### Set up once

| Once per | What | How |
|---|---|---|
| AWS account | GitHub OIDC provider | [`make oidc`](#oidc-provider) |
| AWS account and region | Connection between CodeBuild and GitHub | [Connect CodeBuild to GitHub](#connect-codebuild-to-github) |
| Repository | Which repository and account CI trusts | [With the workflows, in a fork](#with-the-workflows-in-a-fork) |
| Environment | CI roles | `make access ENV=<env>`, always local the first time |
| Environment | A GitHub Environment, and approvals if available | [Configure approvals](#configure-approvals) |

### OIDC provider

```bash
make oidc-plan              # preview
make oidc                   # create; stops if the account already has one
```

It is shared by every repository in the account and trusts nobody by itself. The roles in `access` decide which repository may assume what.

### Connect CodeBuild to GitHub

CodeBuild needs a CodeConnections connection named `github` to check out the repository. AWS requires a sign-in step in the console, so this cannot be fully scripted.

1. Create the connection. It starts as `PENDING`:

   ```bash
   aws codeconnections create-connection \
     --provider-type GitHub --connection-name github --region us-east-1
   ```

2. Open [Settings, Connections](https://console.aws.amazon.com/codesuite/settings/connections) in the AWS console and choose **Update pending connection**.
3. Install the **AWS Connector for GitHub** app, on only this repository.
4. Check it: `make init` shows the status, which should be `AVAILABLE`.

One connection serves every repository the app is installed on. An env in another region or account needs its own. `github_connection_name` in `ci-runner` changes the name.

### Configure approvals

`apply.yml` and `db-restore.yml` run in a [GitHub Environment](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments) named after the env. It controls who can approve a run, and only jobs bound to it can assume the apply role.

Required reviewers depend on the repository's visibility and GitHub plan: see [GitHub's documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

Where they are supported, you can configure them with the [GitHub CLI](https://cli.github.com/), replacing the values on the first three lines, or in GitHub under **Settings, Environments, `<env>`**:

```bash
REPO=<owner>/<repo>
GH_ENV=dev
REVIEWER_ID="$(gh api users/<login> --jq .id)"

# Create or update the Environment: who approves, and that only named branches may deploy
gh api -X PUT "repos/$REPO/environments/$GH_ENV" --input - <<EOF
{
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": $REVIEWER_ID }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF

# Allow only master to deploy, so only merged code is applied
gh api -X POST "repos/$REPO/environments/$GH_ENV/deployment-branch-policies" \
  -f name=master -f type=branch

# Check the result
gh api "repos/$REPO/environments/$GH_ENV" --jq '{name, protection_rules, deployment_branch_policy}'
```

Good to know:

- **Reviewers:** up to six users or teams, and one approval is enough. For a team, use `"type": "Team"` with the team's ID.
- **Self-approval:** `prevent_self_review: false` lets you approve your own runs, which suits one person working alone. Set it to `true` once there are several reviewers, and always for prod.
- **Re-running:** the `PUT` replaces the whole configuration, so include every setting each time.

### Workflows

| Workflow | When | What it does | Approval |
|---|---|---|---|
| `ci.yml` | Every pull request | Lint, `checkov`, then plans `access` and every other stack for **every** env | None: read-only role |
| `apply.yml` | By hand | Plan, apply or destroy one env, or one stack of it | If the Environment requires it |
| `db-restore.yml` | By hand | `list`, `restore`, `rollback` or `retire` | If the Environment requires it, never for `list` |

**`ci.yml`** has no path filter, because a change to a base tfvars or a module affects every env. It stops at the first error, and it skips `app-k8s` because runners cannot reach the private API. An env must already have a state bucket and roles, or the pull request fails.

**`apply.yml`** takes `env`, `stack` (`all` or one stack), `action` and `confirm`, which must be the env name to destroy anything outside dev. To change a replica count, for example: open a pull request, merge it, then run `stack = app-k8s`. For a change that also touches AWS, run `stack = all`, where unchanged stacks are no-ops.

**Changing roles from CI:** `stack = access` applies the env's roles with the apply role itself. It is never part of `all`, and it cannot be destroyed from CI. The risk is lockout: a change that breaks the apply role stops CI logging in. To recover, someone with admin rights runs `make access ENV=<env>` locally.

**No repository variables:** `scripts/ci-role.sh` derives the role and region from `envs/`. `bootstrap/*` never runs from CI.

## Tunnel or CodeBuild

`app-k8s` is the one stack that talks to the private Kubernetes API, so it needs a path into the VPC. Everything else only uses AWS APIs. `K8S_VIA` chooses the path.

| | Tunnel (`K8S_VIA=tunnel`, the default) | CodeBuild (`K8S_VIA=codebuild`) |
|---|---|---|
| **Used by** | People, locally | `apply.yml`, `db-restore.yml` |
| **Terraform runs** | On your machine | In a build inside the VPC |
| **Goes through** | Bastion and SSM port-forward | The private endpoint directly |
| **Code that runs** | Your working copy | The pushed commit |
| **Needs** | Session Manager plugin, a running bastion | `ci-runner` applied, the GitHub connection |
| **Kubernetes identity** | The env's admin role | The build's own role, cluster-admin through its own access entry |

Why not a tunnel from CI? A build keeps everything in one job, so a required approval is asked for only once. It also doesn't depend on the bastion, and has nothing listening to GitHub. Its log streams into the job.

```bash
K8S_VIA=codebuild make up-all ENV=dev      # push your commit first
```

## Using the cluster

```bash
make tunnel ENV=dev                         # terminal 1: keep it running

make kubeconfig ENV=dev                     # terminal 2: once per cluster
export KUBECONFIG=.kube/dev.kubeconfig
kubectl get nodes
make verify ENV=dev
```

`make kubeconfig` writes `.kube/<env>.kubeconfig` and leaves `~/.kube/config` alone. By default `kubectl` assumes the admin role from your own identity. Use `ROLE=viewer` for read-only, or `ROLE=` if your current identity already is the role you want.

To give someone else access, see [Access](ACCESS.md).

## HTTPS

Dev has no domain, and a trusted certificate needs one. So Terraform generates a self-signed certificate for the load balancer's own DNS name, imports it into ACM and redirects port 80 to 443.

```bash
make -s output STACK=lb ENV=dev ARGS='-raw self_signed_certificate_pem' 2>/dev/null > alb.pem
curl --cacert alb.pem "$(make -s output STACK=lb ENV=dev ARGS='-raw app_url' 2>/dev/null)"
```

Limits of this approach:

- Browsers warn about the certificate.
- Its private key is in the `lb` state. The bucket is private and encrypted, but it is still a key on disk.
- ACM does not renew an imported certificate. It lasts a year, and re-applying with `-replace` issues a new one.

For a real domain, see [Production](PRODUCTION.md). To serve plain HTTP, as [the production example](ENVIRONMENTS.md#the-production-example) does, set `https_self_signed = false`.

## Tear down

```bash
make down-all ENV=dev                       # outside dev, also CONFIRM=<env>
make down     ENV=dev STACK=lb              # or one stack
```

`down-all` keeps the state bucket, the roles, the database's final snapshot and retained backups, and prints how to bring the data back. Without that, the next `up-all` starts with an empty database.

**NOTE: After a database restore or rollback, retire the instances they left behind first.** Otherwise `down-all` fails at the `database` stack. See [Before `down-all`](DATABASE.md#before-down-all).

To remove an environment for good, see [Remove an environment](ENVIRONMENTS.md#remove-an-environment).

## Try it in your own account

**NOTE: Not tested from another account.**

A running environment costs real money, so tear it down when you are done. [Remove an environment](ENVIRONMENTS.md#remove-an-environment) also deletes its roles and state bucket.

### Locally, no fork needed

This is the simplest way to try everything except the workflows. It needs no edits. In another account, `access` skips the CI roles with a warning, and `ci-runner` then creates nothing.

```bash
git clone <this repository>
make init
make state  ENV=dev
make access ENV=dev
make up-all ENV=dev
```

Then follow [Using the cluster](#using-the-cluster).

### With the workflows, in a fork

1. **Fork the repository and enable Actions on the fork.** GitHub turns workflows off on forks until you do, under the **Actions** tab. You need access to the source repository to fork it, and a fork of a private repository stays private.
2. **Point CI at your fork and account.** Set these in `envs/base/access.tfvars` and commit:

   ```hcl
   github_repo             = "<owner>/<repo>"
   github_aws_account_id   = "<your account id>"
   github_subject_prefixes = ["repo:<owner>@<owner id>/<repo>@<repo id>", "repo:<owner>/<repo>"]
   ```

   `gh api repos/<owner>/<repo> --jq '.owner.id, .id'` prints the IDs. GitHub may put them in the OIDC `sub` claim, and keeping the plain form too does no harm. If a login fails, CloudTrail shows the real `sub` under `AssumeRoleWithWebIdentity`.

   Until you change these, applying `access` in another account creates the admin and viewer roles but **no CI roles**, so a plain clone never trusts someone else's repository.
3. **Create the OIDC provider,** if the account has no GitHub provider yet: `make oidc`.
4. **[Connect CodeBuild to GitHub](#connect-codebuild-to-github),** installing the app on your fork.
5. **Create the state bucket and roles:**

   ```bash
   make state  ENV=dev
   make access ENV=dev
   ```

6. **Run `apply.yml`** with `env = dev`, `stack = all`, `action = apply`.

`make clean` leaves the OIDC provider and the GitHub connection behind, because they are account-wide. Delete them by hand if nothing else uses them.
