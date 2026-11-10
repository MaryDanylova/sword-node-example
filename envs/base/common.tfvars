# Base layer: values shared by every environment and every stack.
# Layers, later files win (Terraform replaces a whole variable, it does not merge maps/lists):
#   stacks/<stack>/variables.tf defaults
#   -> envs/base/common.tfvars                (this file: every stack, every env)
#   -> envs/base/<stack>.tfvars               (one stack, every env)
#   -> envs/overlays/<env>/common.tfvars      (every stack, one env)
#   -> envs/overlays/<env>/<stack>.tfvars     (one stack, one env: only what differs)
# variables.tf holds defaults that are right for any deployment; everything about THIS
# deployment (names, accounts, repository, sizes) lives here in envs/.
# `env` is not set in any file: it is the overlay directory name (ENV=dev -> envs/overlays/dev/).
project = "sword"
region  = "us-east-1"
