# Usage: make <target> [VARIABLE=value ...]
#
# Variables
#   ENV       the environment, a directory in envs/overlays/ (default: dev)
#   STACK     one of: access network eks ci-runner database app-aws app-k8s lb
#   ROLE      kubeconfig role: admin (default), viewer, or empty for your current identity
#   ARGS      extra arguments for the underlying command, e.g. ARGS=--help
#   CONFIRM   the env name, required to destroy anything outside dev
#
#
# Set up the account and tools
#
#   Check tools, and the AWS credentials and permissions of whoever runs this
#     make init
#
#   Preview or create the GitHub OIDC provider: once per account, only for CI
#     make oidc-plan
#     make oidc
#
#
# Create an environment
#
#   Declare a new env: creates envs/overlays/<env>/, local only
#     make init-env    ENV=staging
#
#   Preview or create its Terraform state bucket: once per env
#     make state-plan  ENV=dev
#     make state       ENV=dev
#
#   Apply its roles (CI, admin, viewer): first time locally, never part of up-all
#     make access      ENV=dev
#
#
# Run a whole environment
#
#   Plan every stack in order, read-only
#     make plan-all    ENV=dev
#
#   Apply every stack in order; opens a tunnel for app-k8s if none is listening
#     make up-all      ENV=dev
#
#   The same, with app-k8s as a CodeBuild build in the VPC, on the pushed commit
#     make up-all      ENV=dev  K8S_VIA=codebuild
#
#   Destroy every stack in reverse order; state bucket and roles stay
#     make down-all    ENV=dev
#
#   Delete the state bucket once nothing is left: lists what remains, always asks
#     make clean       ENV=dev
#
#
# Run one stack
#
#   Plan, apply, destroy, or show outputs
#     make plan        ENV=dev  STACK=network
#     make up          ENV=dev  STACK=network
#     make down        ENV=dev  STACK=lb
#     make output      ENV=dev  STACK=lb
#
#   Pass extra Terraform arguments
#     make up          ENV=dev  STACK=database  ARGS='-replace=aws_db_instance.this'
#
#
# Reach the cluster
#
#   Terminal 1, keep it running: SSM port-forward to the private EKS API
#     make tunnel      ENV=dev
#
#   Terminal 2, once per cluster: then export KUBECONFIG=.kube/dev.kubeconfig
#     make kubeconfig  ENV=dev  [ROLE=viewer]
#
#   End-to-end checks; needs the tunnel
#     make verify      ENV=dev
#
#   Cut a role's access now, with no commit or apply
#     make revoke      ENV=dev  ARGS='viewer [--principal <arn>]'
#
#
# Restore the database
#
#   List restore points
#     make db-restore  ENV=dev  ARGS=list
#
#   Restore side by side and switch over; <point> is latest, a UTC time or a snapshot
#     make db-restore  ENV=dev  ARGS='restore <point>'
#
#   Switch back to the previous instance, or delete it later
#     make db-restore  ENV=dev  ARGS='rollback <id>'
#     make db-restore  ENV=dev  ARGS='retire <id>'
#
#
# Check the code
#
#   Format Terraform; validate the stack order and every Terraform root
#     make fmt
#     make validate

ENV   ?= dev
STACK ?=
ROLE  ?= admin
ARGS  ?=

.PHONY: help
help:
	@sed -n '/^[^#]/q;s/^# \{0,1\}//;p' Makefile

## ---- account and tools --------------------------------------------------------
.PHONY: init oidc-plan oidc

init:
	@./scripts/init.sh

oidc-plan:
	@./scripts/oidc.sh plan

oidc:
	@./scripts/oidc.sh create

## ---- create an environment ----------------------------------------------------
.PHONY: init-env state-plan state access

init-env:
	@./scripts/init-env.sh $(ENV)

state-plan:
	@./scripts/state.sh $(ENV) plan

state:
	@./scripts/state.sh $(ENV) create

# Shorthand for local runs of: make up STACK=access
access:
	@./scripts/run-stack.sh $(ENV) access apply $(ARGS)

## ---- whole environment --------------------------------------------------------
.PHONY: plan-all up-all down-all clean

plan-all:
	@./scripts/run-env.sh plan $(ENV) $(ARGS)

up-all:
	@./scripts/run-env.sh up $(ENV) $(ARGS)

down-all:
	@CONFIRM=$(CONFIRM) ./scripts/run-env.sh down $(ENV) $(ARGS)

# Always asks: takes no ARGS and has no auto-approve.
clean:
	@./scripts/clean.sh $(ENV)

## ---- one stack (scripts/run-stack.sh: state bucket, layered tfvars, init) ---------
.PHONY: plan up down output

plan:
	@./scripts/run-stack.sh $(ENV) $(STACK) plan $(ARGS)

up:
	@./scripts/run-stack.sh $(ENV) $(STACK) apply $(ARGS)

down:
	@CONFIRM=$(CONFIRM) ./scripts/run-stack.sh $(ENV) $(STACK) destroy $(ARGS)

output:
	@./scripts/run-stack.sh $(ENV) $(STACK) output $(ARGS)

## ---- cluster ----------------------------------------------------------------------
.PHONY: tunnel kubeconfig verify revoke

tunnel:
	@./scripts/tunnel.sh $(ENV)

kubeconfig:
	@ROLE=$(ROLE) ./scripts/kubeconfig.sh $(ENV)

verify:
	@./scripts/py/main.py verify $(ENV)

revoke:
	@./scripts/py/main.py revoke $(ENV) $(ARGS)

## ---- database ---------------------------------------------------------------------
.PHONY: db-restore

db-restore:
	@CONFIRM=$(CONFIRM) ./scripts/py/main.py db-restore $(ENV) $(ARGS)

## ---- code -------------------------------------------------------------------------
.PHONY: fmt validate

fmt:
	terraform fmt -recursive

validate:
	@./scripts/check-stacks.sh
	@# Drops only the local pointer to the last backend used, which may be a deleted env's bucket;
	@# scripts/run-stack.sh writes it again on every run.
	@for d in bootstrap/*/ stacks/*/; do \
		echo "==> $$d"; \
		rm -f "$$d.terraform/terraform.tfstate"; \
		terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; \
	done
