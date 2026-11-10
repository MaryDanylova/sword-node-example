# Conventions

The terms and rules used across this repository.

- [Stack or module?](#stack-or-module)
- [Stacks](#stacks)
- [Modules](#modules)
- [Bootstrap roots](#bootstrap-roots)
- [Configuration layers](#configuration-layers)
- [Naming](#naming)
- [Glossary](#glossary)

## Stack or module?

| | Stack | Module |
|---|---|---|
| **What it is** | Something you apply | A building block that stacks use |
| **Where it lives** | `stacks/<name>/` | `modules/<name>/` |
| **Terraform state** | Its own, one per environment | None of its own |
| **Knows about this deployment** | Yes: reads other stacks and uses `env` | No: everything comes in through variables |
| **Named after** | Its part in this deployment: `network`, `lb` | What it creates: `bastion`, `alb` |
| **You run it with** | `make up STACK=<name>` | You don't. A stack calls it |

A stack is the unit of change: its own plan, its own apply, and its own blast radius. Stacks read each other's outputs through `terraform_remote_state`.

## Stacks

Applied in this order and destroyed in reverse. The order is the `STACKS` list in `scripts/lib.sh`, and `make validate` checks that each stack reads only the ones before it.

### access

The environment's IAM roles: CI plan and apply, admin and viewer. Applied with `make access`, or through `apply.yml` naming it. `up-all` and `down-all` skip it, because it holds the role CI runs with. See [why roles live here](ENVIRONMENTS.md#why-roles-live-in-access).

### network

VPC, subnets across three zones, NAT Gateway and the S3 gateway endpoint. Uses `terraform-aws-modules/vpc`.

### eks

The cluster with its private endpoint, addons (VPC CNI with network policies, CoreDNS, kube-proxy, Pod Identity agent), the managed node group, access entries for the roles in [access](#access), and the [bastion](#bastion). Uses `terraform-aws-modules/eks`.

### ci-runner

Only with CI. A [CodeBuild project](#vpc-codebuild) in the private subnets, with its access entry and a rule into the cluster on port 443. Creates nothing when `github_repo` is not set, and `eks` knows nothing about it.

### database

RDS MySQL, its parameter group and security group, the AWS Backup vault and plan, and the secrets for the app and monitor users.

### app-aws

The app's AWS resources: read and write [buckets](#s3-bucket), SQS queue and dead-letter queue. Also the Pod Identity roles for the app, the `db-admin` Job and ProxySQL.

### app-k8s

What runs in Kubernetes: the app with its ServiceAccount, PDB, ConfigMap and NetworkPolicies, the `kube-system` RBAC, the Job that syncs MySQL users, and [ProxySQL](#proxysql). It is the only stack that talks to the private API, so it needs [a tunnel or a CodeBuild build](DEPLOYMENT.md#tunnel-or-codebuild).

### lb

The [load balancer](#alb) and its self-signed certificate. `enable_lb = false` removes it and keeps the stack.

## Modules

These are this repository's own modules. VPC and EKS use pinned community modules instead.

### alb

A public ALB, its listeners, target group and security groups, attached to the node Auto Scaling groups. Takes an ACM certificate ARN for HTTPS.

### assumable-role

An IAM role that people or other roles assume, listing who may do so.

### bastion

The small SSM instance with no inbound rules.

### github-oidc-role

An IAM role that GitHub Actions assumes through OIDC, trusted only for the listed subjects.

### proxysql

ProxySQL in its own namespace: Deployment, Service, backend ConfigMap, NetworkPolicy and, with more than one replica, a PDB.

### s3-bucket

A private, encrypted, TLS-only bucket. Used for the app buckets and the state bucket, so there is one bucket implementation.

### vpc-codebuild

A CodeBuild project inside a VPC that runs a buildspec on a commit of a GitHub repository. It starts on demand and has no webhook.

## Bootstrap roots

`bootstrap/state` and `bootstrap/oidc` solve a chicken-and-egg problem: a state bucket cannot keep its own state.

They run with a **throwaway** local state in a temporary directory. The resource is created, the state is deleted, and the resource is found afterwards by its tags (bucket) or URL (OIDC provider). A second run stops on purpose. If an apply fails halfway, the temporary state is kept and the script prints how to finish.

Nothing here changes these resources afterwards, apart from [`make clean`](ENVIRONMENTS.md#remove-an-environment), which deletes a state bucket after confirmation.

## Configuration layers

Inputs are layered, kustomize style. A later file wins. Terraform replaces a whole variable rather than merging it, so set only what changes.

| Order | File | Holds | Example |
|---|---|---|---|
| 1 | `stacks/<stack>/variables.tf` | Defaults right for any deployment | `single_nat_gateway = true` |
| 2 | `envs/base/common.tfvars` | This deployment: every stack, every env | `project`, `region` |
| 3 | `envs/base/<stack>.tfvars` | One stack, every env | Spot nodes in `eks.tfvars` |
| 4 | `envs/overlays/<env>/common.tfvars` | One env, every stack | Empty in dev |
| 5 | `envs/overlays/<env>/<stack>.tfvars` | One env, one stack | `vpc_cidr` in a new env's `network.tfvars` |

Three rules follow from this:

- **The base is how dev runs.** `envs/overlays/dev/` holds only an empty `common.tfvars`. A new env starts with dev's cheap, easy-to-destroy settings until it overrides them.
- **`env` is never written in a file.** It is the overlay's directory name: `ENV=dev` reads `envs/overlays/dev/`.
- **An env exists only once its `common.tfvars` exists.** A typo such as `ENV=dve` fails at once, rather than building something from the base.

## Naming

| Thing | Name | Example |
|---|---|---|
| Environment | 1 to 20 lower-case letters, digits or `-` | `dev` |
| Cluster, and the prefix for most resources | `<project>-<env>` | `sword-dev` |
| People's roles | `<project>-<env>-admin`, `-viewer` | `sword-dev-viewer` |
| CI roles | `<project>-<env>-github-plan`, `-github-apply` | `sword-dev-github-apply` |
| Bastion | `<project>-<env>-bastion` | `sword-dev-bastion` |
| CodeBuild project and role | `<project>-<env>-ci-runner` | `sword-dev-ci-runner` |
| MySQL instance | `<project>-<env>-mysql-<26 hex>` | `sword-dev-mysql-32452f…` |
| State bucket | `<project>-tfstate-<env>-<8 hex>` | `sword-tfstate-dev-43c710a9` |
| State file | `<stack>.tfstate` | `network.tfstate` |
| GitHub Environment | The env's name | `dev` |

**State buckets are found, not configured.** Scripts look one up by its tags (`Project`, `Env`, `Purpose = tfstate`), so its name is never copied anywhere. `TF_STATE_BUCKET=<name>` overrides the lookup.

**Role ARNs are built from names.** Nothing stores an account ID in cluster config, and CI needs no repository variables.

## Glossary

| Term | Meaning |
|---|---|
| **Access entry** | How EKS maps an IAM role to permissions inside the cluster |
| **Base** | The configuration every env shares, in `envs/base/` |
| **Bastion** | The small instance at the far end of the SSM tunnel |
| **Cutover** | Switching ProxySQL from one MySQL instance to another, without restarting the apps |
| **Environment (env)** | One deployment of all the stacks, with its own state bucket and roles |
| **GitHub Environment** | GitHub's own feature. Holds any deployment rules, and is what lets a job assume the apply role |
| **Hostgroup** | ProxySQL's grouping of backends. 10 is what the app uses, and 20 is where a new instance waits |
| **Overlay** | One env's differences from the base, in `envs/overlays/<env>/` |
| **PITR** | Point-in-time recovery: restoring a database to any moment in its backup window |
| **Pod Identity** | How a pod gets an AWS role through its ServiceAccount |
| **Retire** | Deleting the old MySQL instance after a restore, keeping a final snapshot |
| **Tunnel** | An SSM port-forward from your machine to the private API, through the bastion |
