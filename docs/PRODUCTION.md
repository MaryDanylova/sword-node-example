# Production

What should differ for real production use. [The production example](ENVIRONMENTS.md#the-production-example) already covers sizing, high availability and retention through configuration. The items below need more than a setting.

## Security and access

- **CI role:** a least-privilege apply role instead of `AdministratorAccess`. Where [your GitHub plan supports it](DEPLOYMENT.md#configure-approvals), more than one required reviewer on the prod Environment, with self-review prevented.
- **Apply role trust:** require deployment branch rules, so only merged code can reach the role. Without them, anyone with write access can get the role from a branch. See [what that means in practice](../CONTRIBUTING.md#what-that-means-in-practice).
- **State access:** limit the plan role to what it needs, and keep sensitive values out of state. It can currently read an env's whole state, including the self-signed certificate's private key.
- **Audit:** a CloudTrail trail with retained logs, SSM session logging, and GuardDuty.
- **Accounts:** separate AWS accounts for dev and prod. This is supported: an env overrides `github_aws_account_id`, and its state bucket lives in its own account.
- **People:** SSO or Client VPN instead of a single bastion, with short-lived credentials only.
- **Secrets:** External Secrets Operator or the Secrets Store CSI driver, once an app needs its secrets as Kubernetes objects or files rather than reading Secrets Manager itself.
- **Image:** only the tag `0.0.1` exists. Pin by digest and scan it in CI. The image defaults to root, which the pod already overrides with a non-root user.

## Traffic

- **TLS:** a domain with an ACM-issued certificate (DNS validation, auto-renewed), passed to `modules/alb` as `certificate_arn`, instead of the self-signed one. The private key then stays inside ACM.
- **Edge:** WAF in front of the load balancer, a restricted `lb_allowed_cidrs`, and access logs.
- **Ingress:** the AWS Load Balancer Controller with Ingress, once there is more than one app.
- **Encryption behind the load balancer:** TLS from the load balancer to the pods, or a service mesh, if your compliance rules require encryption in transit inside the VPC.

## Scaling

- **Nodes:** Karpenter, which picks instance types per pending pod, consolidates and handles Spot interruptions. Or, closer to the current setup, Cluster Autoscaler on the managed node group. Either way `node_min_size` becomes a floor and the autoscaler owns the size. Until then, raising `node_min_size` above the current size is rejected by EKS: scale the group with the AWS CLI first.
- **Pods:** HPA on the app, so there is something to scale for. It needs `metrics-server`, which the cluster does not run yet.
- **ProxySQL:** when adding replicas, keep `backend_max_connections` times the replica count below the database's `max_connections`.

## Database

- **Managed proxy:** Amazon RDS Proxy gives pooling, faster failover and IAM or Secrets Manager auth, run and patched by AWS, at an extra hourly cost. Before relying on it for the restore cutover, test whether client connections survive a target swap (`deregister-db-proxy-targets`, `register-db-proxy-targets`), since it is designed for failover within one instance or cluster. ProxySQL stays the choice where controlled cutovers or query rules matter.
- **Restore testing:** an AWS Backup restore testing plan (`aws_backup_restore_testing_plan`) restores the latest recovery point on a schedule, checks that it becomes available and deletes it again, so backups are proven restorable with nobody involved.
- **Disaster recovery:** a cross-region or cross-account copy of backups, AWS Backup Vault Lock so they cannot be deleted early, and restore drills on a schedule.
- **Password rotation:** automatic rotation for the app and monitor users. Today it is manual: bump `password_version`, apply, and restart ProxySQL.
- **Database visibility:** slow query logs, enhanced monitoring and Performance Insights.

## Operations

- **Observability:** metrics and dashboards, alerts with somewhere to send them, and application log shipping. Today only control plane and database error logs are collected, and nothing raises an alert.
- **Patching:** a routine for Kubernetes versions, addons and node images, and SSM Patch Manager or regular replacement for the bastion, which keeps its original image. Staying on a Kubernetes version past standard support costs extra.
- **Cost:** AWS Budgets and anomaly alerts. A forgotten environment keeps charging, and nothing here warns you.
- **Retention:** a policy for final snapshots and retained backups, which build up with every teardown and restore. Automated backups expire on their own, but manual snapshots stay until someone deletes them.
- **Delivery:** a GitOps controller such as Argo CD or Flux for the Kubernetes layer, once there is more than one app.
