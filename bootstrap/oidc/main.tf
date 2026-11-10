# The account's GitHub Actions OIDC identity provider: lets workflows get short-lived AWS
# credentials instead of stored keys. It trusts nobody by itself - which repository may assume
# which role is decided by the roles' trust policies (per env, in the roles stack).
resource "aws_iam_openid_connect_provider" "github" {
  url             = var.url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.thumbprints
}
