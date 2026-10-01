# ──────────────────────────────────────────────────────────────────────────────
# vpc_endpoints.tf — AWS PrivateLink Interface Endpoints
#
# These endpoints give air-gapped ECS EC2 instances in private subnets a
# private path to AWS service APIs — no NAT Gateway, no internet route required.
#
# Cost note: Each Interface Endpoint is charged at ~$0.01/hr per AZ + data.
#            9 endpoints × 2 AZs = 18 ENIs. The S3 Gateway Endpoint (vpc.tf)
#            is free and handles the bulk of ECR image data transfer.
#
# Required endpoints:
#   ECR API      — Docker authentication and manifest queries
#   ECR DKR      — docker pull layer downloads (metadata; blobs go via S3)
#   ECS          — ECS control plane API
#   ECS Agent    — ECS agent ↔ control plane registration
#   ECS Telemetry— Container metrics and status reporting
#   CloudWatch   — Container STDOUT/STDERR log delivery
#   Secrets Mgr  — Runtime injection of JDBC_USERNAME / JDBC_PASSWORD
#   SSM          — Session Manager shell access (no SSH / no Bastion needed)
#   SSM Messages — Session Manager data channel
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Services that need Interface Endpoints.
  # The map key becomes part of the resource Name tag.
  interface_endpoint_services = {
    "ecr-api"         = "ecr.api"
    "ecr-dkr"         = "ecr.dkr"
    "ecs"             = "ecs"
    "ecs-agent"       = "ecs-agent"
    "ecs-telemetry"   = "ecs-telemetry"
    "logs"            = "logs"
    "secretsmanager"  = "secretsmanager"
    "ssm"             = "ssm"
    "ssmmessages"     = "ssmmessages"
  }
}

# ── Interface Endpoints ───────────────────────────────────────────────────────
# private_dns_enabled = true rewrites the service's public DNS name to resolve
# to the private ENI IP inside the VPC — no application config changes needed.

resource "aws_vpc_endpoint" "interfaces" {
  for_each = local.interface_endpoint_services

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  # Place ENIs in both private AZs for high availability
  subnet_ids = aws_subnet.private[*].id

  # Only allow HTTPS from within the VPC
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpce-${each.key}"
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "vpc_endpoint_ids" {
  description = "Map of Interface Endpoint logical names to their IDs"
  value       = { for k, ep in aws_vpc_endpoint.interfaces : k => ep.id }
}

output "s3_gateway_endpoint_id" {
  description = "ID of the free S3 Gateway Endpoint"
  value       = aws_vpc_endpoint.s3.id
}
