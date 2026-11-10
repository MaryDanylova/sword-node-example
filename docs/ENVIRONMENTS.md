# Environments

An environment is one deployment of every stack, with its own state bucket and its own roles. It is declared by a directory, `envs/overlays/<env>/`, that holds only how it differs from the base. See [Configuration layers](CONVENTIONS.md#configuration-layers).

- [Create an environment](#create-an-environment)
- [Why roles live in access](#why-roles-live-in-access)
- [The production example](#the-production-example)
- [Remove an environment](#remove-an-environment)

## Create an environment

This example creates `staging`.

### 1. Declare it

```bash
make init-env ENV=staging
```

This creates `envs/overlays/staging/common.tfvars` and prints these steps. The name becomes part of bucket and role names: 1 to 20 lower-case letters, digits or `-`.

### 2. Set what differs

Add a file per stack, holding only what changes. A new env starts with dev's cheap settings, so decide what it should harden.

```hcl
# envs/overlays/staging/network.tfvars
vpc_cidr = "10.2.0.0/16"     # distinct, if it may ever be peered with another env

# envs/overlays/staging/eks.tfvars
node_capacity_type = "ON_DEMAND"
```

[The production example](#the-production-example) shows what hardening looks like. For an env in another AWS account, set `github_aws_account_id` in its `access.tfvars`.

### 3. Create the state bucket

```bash
make state-plan ENV=staging     # optional preview
make state      ENV=staging
```

A second run stops on purpose.

### 4. Create the roles

```bash
make access ENV=staging
```

**Why it comes first, and why locally:** the CI roles do not exist yet, so CI cannot log in to create them, and `eks` needs these roles for its access entries. Your credentials must be able to create IAM roles. After this, later changes can also go through `apply.yml` with `stack = access`. See [why roles live in `access`](#why-roles-live-in-access).

### 5. Open a pull request

Commit `envs/overlays/staging/`. `ci.yml` plans every env it finds there, so steps 3 and 4 must be done first, otherwise the pull request fails with a reminder.

### 6. Set up approvals (only with CI)

To use `apply.yml` for this env, add a GitHub Environment named `staging`. See [Configure approvals](DEPLOYMENT.md#configure-approvals).

### 7. Create everything else

After merging, either locally or from CI:

```bash
make up-all ENV=staging
```

Or run `apply.yml` with `env = staging`, `stack = all`, `action = apply`.

### 8. Check it

```bash
make tunnel ENV=staging         # terminal 1

make kubeconfig ENV=staging     # terminal 2
export KUBECONFIG=.kube/staging.kubeconfig
make verify ENV=staging
```

## Why roles live in access

People might expect the admin and viewer roles to live in `eks`, next to the cluster they open. They live in their own stack for four reasons.

| Reason | What it means |
|---|---|
| **They outlive the cluster** | `down-all` destroys `eks` every time you tear an env down. Roles there would disappear with it, and so would everyone's access and all the grants made to them |
| **CI depends on them** | The apply role is what `apply.yml` runs as. In `eks`, a destroy from CI would delete the role running the destroy |
| **They come first** | CI cannot log in until its role exists, so the first apply is local. `eks` then reads role names from `access` to create access entries |
| **They cost nothing and are separate to change** | Adding a reviewer plans and applies only `access`, in seconds, without touching the cluster's plan |

That is why `up-all` and `down-all` skip it. Only a person, or `apply.yml` naming it, applies it, and only `make down STACK=access` destroys it.

The split in responsibility is simple:

- **IAM decides who can reach the private API:** `access`, through each role's trust policy.
- **The EKS access entry decides what they can do in it:** `eks`, by role name.

Roles an AWS *service* assumes (nodes, bastion, Pod Identity, CodeBuild) stay with the resource that uses them, since they should live and die with it.

## The production example

`envs/examples/prod/` is a ready-made set of overrides for a hardened environment. It is only an example: nothing plans or applies it, and `make validate` just checks that every variable it sets still exists.

| Stack | What it changes |
|---|---|
| `network` | Its own VPC range, a NAT Gateway per zone |
| `eks` | On-demand `t3.large`, 3 to 6 nodes, 90-day logs |
| `database` | Larger instance, Multi-AZ, deletion protection, 14-day PITR, 35-day AWS Backup, changes in the maintenance window |
| `app-aws` | Buckets without force-destroy, read bucket not seeded |
| `app-k8s` | 3 app replicas, 2 ProxySQL replicas |
| `lb` | Deletion protection, plain HTTP until it has a domain |
| `state` | 90-day state version retention |

To use it, copy it into place, review the values, and follow the steps above from [step 3](#3-create-the-state-bucket) with `ENV=prod`:

```bash
cp -R envs/examples/prod envs/overlays/prod
```

Once it is in `envs/overlays/`, it is a real environment: `ci.yml` plans it on every pull request, and destroying it needs `CONFIRM=prod`.

For what else should change before real production use, see [Production](PRODUCTION.md).

## Remove an environment

```bash
make down-all ENV=staging CONFIRM=staging          # 1. everything except state and roles
make down STACK=access ENV=staging CONFIRM=staging # 2. the roles
make clean ENV=staging                             # 3. the state bucket
```

Then delete `envs/overlays/staging/` in a pull request, because `ci.yml` plans every env declared there. Also delete its GitHub Environment if it has one.

`make clean` is deliberately careful:

1. **It lists what would remain,** and never deletes these:
   - The env's data, kept on purpose: snapshots, retained backups, backup vaults, secrets, log groups.
   - Account-wide resources, shared with other envs: the OIDC provider and the GitHub connection.
2. **It refuses while any state holds resources,** because without its state Terraform could no longer destroy them.
3. **It asks you to type the bucket name at a terminal.** There is no flag to skip this, and piped input is refused.
