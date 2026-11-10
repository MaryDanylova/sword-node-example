# Contributing

How changes are checked and applied here, and, just as importantly, what this repository does **not** do.

- [Make a change](#make-a-change)
- [What is not implemented](#what-is-not-implemented)
- [What that means in practice](#what-that-means-in-practice)

## Make a change

1. **Work on a branch** and open a pull request against `master`.
2. **Run the checks locally.** These are the same ones `ci.yml` runs, apart from `tflint`:

   ```bash
   make fmt
   make validate
   uvx ruff@0.14.4 check scripts
   uvx ruff@0.14.4 format --check scripts
   uvx --python 3.12 checkov -d . --config-file .checkov.yaml
   ```

3. **Read the plans.** `ci.yml` plans every env declared in `envs/overlays/`, except `app-k8s`, which runners cannot reach. To plan that stack, run `make plan STACK=app-k8s ENV=<env>` with a tunnel open.
4. **Merge, then apply by hand:** with `apply.yml`, or locally with `make`. Merging applies nothing.

When adding a stack, also add it to `STACKS` in `scripts/lib.sh` and to the choices in `apply.yml`. `make validate` fails until they match. See [Conventions](docs/CONVENTIONS.md) for naming and configuration.

## What is not implemented

This repository is a platform you run by hand, and it has no release process. These are deliberate omissions, not hidden features.

| Practice | State here |
|---|---|
| **Versioning** | None. No tags, releases or changelog. A version of the platform is a commit |
| **Module versions** | The modules in `modules/` are used by relative path, so a change reaches every stack at once. Only community modules and providers are pinned |
| **Promotion between environments** | None. Nothing moves a change from dev to staging to prod |
| **Apply on merge** | None. Every apply is started by a person |
| **Branch rules** | Not configured by this repository. Nothing here sets up branch protection, required checks or code owners |
| **Restricting what can be applied** | None in the code. `apply.yml` and `db-restore.yml` run on whichever branch they are started from |
| **Required approvals** | Only if the GitHub Environment has them, and that depends on [the GitHub plan](docs/DEPLOYMENT.md#configure-approvals) |
| **Drift detection** | None. Nothing plans on a schedule, so a manual change stays unnoticed until the next plan |
| **Automated tests** | No test suite. `make verify` checks a running environment, and it is run by hand |
| **Rollback** | None for infrastructure. Going back means reverting the commit and applying again. The database has [its own rollback](docs/DATABASE.md#afterwards) |

## What that means in practice

**A change affects every env, whenever each is next applied.** A change to `envs/base/`, a stack or a module applies to every env on its next apply. Nothing records which commit an env is running, so two envs can quietly drift apart. To find out, plan them.

**A branch can be applied.** Starting `apply.yml` from a branch applies that branch, including `app-k8s`, because the CodeBuild build runs on the run's commit. A failing `ci.yml` or an unreviewed change doesn't stop it.

**Write access is close to admin access.** The apply role has `AdministratorAccess`, and it trusts any job bound to the env's GitHub Environment. Without deployment branch rules, anyone who can push can write a workflow that assumes it, from any branch. Treat write access to this repository as admin access to its AWS account, and see [Production](docs/PRODUCTION.md#security-and-access).

**The plan role can read state.** It trusts every run of the repository, including pull requests from branches here, and it can read all of an env's state. Pull requests from forks don't get to run the plans.

**Applying your working copy is possible.** Local `make` commands use whatever is on your disk, committed or not. The exception is `K8S_VIA=codebuild`, which uses the pushed commit.
