vpc_cidr = "10.1.0.0/16" # distinct from dev (10.0.0.0/16) so the two can be peered later

# One NAT Gateway per AZ: an AZ outage does not cut egress for the others.
single_nat_gateway = false
