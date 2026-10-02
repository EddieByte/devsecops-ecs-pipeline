# ──────────────────────────────────────────────────────────────────────────────
# vpc.tf — Air-Gapped, NAT-less VPC
#
# Architecture:
#   • Public subnets  → ALB only (internet-facing ingress)
#   • Private subnets → ECS EC2 instances + RDS (zero outbound internet routes)
#   • No NAT Gateway, no Elastic IP — eliminates $0.045/GB data processing cost
#   • All AWS service traffic routes through VPC Endpoints (see vpc_endpoints.tf)
#   • S3 Gateway Endpoint is FREE and required for ECR image layer downloads
# ──────────────────────────────────────────────────────────────────────────────

# ── VPC ───────────────────────────────────────────────────────────────────────
# DNS hostnames must be enabled — required for Interface Endpoint private DNS.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.project_name}-vpc" })
}

# ── Public Subnets (ALB only) ─────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
    Tier = "public"
  })
}

# ── Private Subnets (ECS EC2 + RDS — air-gapped) ─────────────────────────────

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
    Tier = "private"
  })
}

# ── Internet Gateway (ALB public ingress only) ────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.project_name}-igw" })
}

# ── Public Route Table ────────────────────────────────────────────────────────
# Only the public subnets (ALB) have an internet route.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private Route Table (NO default internet route) ───────────────────────────
# Intentionally contains no 0.0.0.0/0 entry.
# Traffic to AWS services reaches them exclusively via VPC Endpoints.
# The S3 Gateway Endpoint association is declared below.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # No internet route — air-gapped by design.

  tags = merge(var.tags, { Name = "${var.project_name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── S3 Gateway Endpoint (FREE) ────────────────────────────────────────────────
# ECR stores Docker image layer blobs in S3. Without this endpoint, ECS
# instances cannot pull images — there is no other path out of the private
# subnet. Gateway Endpoints are free and route traffic over the AWS backbone.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${var.project_name}-s3-gateway-endpoint" })
}

# ── Security Group: Application Load Balancer ─────────────────────────────────
# Accepts inbound HTTP on port 80 from the internet.

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound to ALB from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Forward to ECS EC2 instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-alb-sg" })
}

# ── Security Group: ECS EC2 Instances ─────────────────────────────────────────
# Ingress: dynamic host ports from ALB only.
# Egress:  HTTPS (443) to VPC CIDR only — reaches all Interface Endpoints.
#          No 0.0.0.0/0 outbound route; enforces the air-gap at SG level too.

resource "aws_security_group" "ecs_ec2" {
  name        = "${var.project_name}-ecs-ec2-sg"
  description = "ECS EC2 instances - inbound from ALB, outbound to VPC endpoints only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Dynamic port range from ALB (bridge mode)"
    from_port       = 32768
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # HTTPS to VPC Endpoints (ECR, ECS agent, Secrets Manager, CloudWatch, SSM)
  egress {
    description = "HTTPS to VPC Interface Endpoints and S3 Gateway Endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # MySQL to RDS within the VPC
  egress {
    description = "MySQL to RDS"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-ecs-ec2-sg" })
}

# ── Security Group: VPC Interface Endpoints ───────────────────────────────────
# Accepts inbound HTTPS from any resource inside the VPC.
# Used by all Interface Endpoints declared in vpc_endpoints.tf.

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from within the VPC to Interface Endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-vpc-endpoints-sg" })
}

# ── Security Group: RDS MySQL ─────────────────────────────────────────────────
# Accepts MySQL traffic on 3306 exclusively from the ECS EC2 SG (zero-trust).

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow MySQL inbound from ECS EC2 instances only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from ECS EC2 instances"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_ec2.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-rds-sg" })
}

# ── Application Load Balancer ─────────────────────────────────────────────────
# Deployed in public subnets — the only internet-facing component.

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = merge(var.tags, { Name = "${var.project_name}-alb" })
}

# ── ALB Target Group (bridge mode — dynamic port mapping) ─────────────────────

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/actuator/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(var.tags, { Name = "${var.project_name}-tg" })
}

# ── ALB Listener: port 80 → target group ──────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = var.alb_listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets (ALB)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets (ECS + RDS, air-gapped)"
  value       = aws_subnet.private[*].id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_target_group_arn" {
  description = "ARN of the ALB target group"
  value       = aws_lb_target_group.app.arn
}

output "ecs_ec2_security_group_id" {
  description = "Security group ID for ECS EC2 instances"
  value       = aws_security_group.ecs_ec2.id
}

output "rds_security_group_id" {
  description = "Security group ID for RDS"
  value       = aws_security_group.rds.id
}

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC Interface Endpoints"
  value       = aws_security_group.vpc_endpoints.id
}
