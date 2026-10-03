# ──────────────────────────────────────────────────────────────────────────────
# main.tf — ECS Cluster, EC2 Launch Template, ASG, Capacity Provider,
#            ECS Task Definition, ECS Service, ECR Repository, IAM Roles,
#            CloudWatch Log Group, and AWS Secrets Manager reference.
# ──────────────────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.aws_region
}

# ── Data Sources ──────────────────────────────────────────────────────────────

# Latest ECS-Optimized Amazon Linux 2023 AMI
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_caller_identity" "current" {}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs_app" {
  name              = "/ecs/${var.ecs_cluster_name}"
  retention_in_days = 30

  tags = var.tags
}

# ── IAM: ECS Task Execution Role ──────────────────────────────────────────────
# Grants ECS agent permission to pull images and write logs.

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Inline policy to read secrets from Secrets Manager
resource "aws_iam_role_policy" "ecs_secrets" {
  name = "${var.project_name}-ecs-secrets-policy"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "kms:Decrypt"
      ]
      Resource = "*"
    }]
  })
}

# ── IAM: ECS Instance Role (for EC2 container instances) ─────────────────────

resource "aws_iam_role" "ecs_instance" {
  name = "${var.project_name}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_instance_managed" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.project_name}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# ── EC2 Launch Template ───────────────────────────────────────────────────────
# Uses the ECS-Optimized Amazon Linux 2023 AMI.
# User-data registers the instance to the ECS cluster automatically.

resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-ecs-lt-"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = var.ec2_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_ec2.id]

  # Registers EC2 instance to the ECS cluster on boot
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${var.ecs_cluster_name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_CONTAINER_METADATA=true >> /etc/ecs/ecs.config
  EOF
  )

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.project_name}-ecs-instance" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────

resource "aws_autoscaling_group" "ecs" {
  name                = "${var.project_name}-ecs-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  protect_from_scale_in = true

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, { Name = var.ecs_cluster_name })
}

# ── ECS Capacity Provider (links ASG to cluster) ──────────────────────────────

resource "aws_ecs_capacity_provider" "asg" {
  name = "${var.project_name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      maximum_scaling_step_size = 2
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 80
    }
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.asg.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.asg.name
    weight            = 1
    base              = 1
  }
}

# ── ECS Task Definition ───────────────────────────────────────────────────────
# Bridge mode with dynamic host port mapping (hostPort = 0).
# Secrets are pulled from AWS Secrets Manager at runtime — no plaintext creds.

resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      cpu       = 1024
      memory    = 2048

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = 0       # Dynamic port mapping (bridge mode)
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "mysql" },
        # PetClinic mysql profile reads MYSQL_URL directly — full JDBC URL as one variable.
        { name = "MYSQL_URL", value = "jdbc:mysql://${aws_db_instance.main.address}:${aws_db_instance.main.port}/petclinic?useSSL=true&requireSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true" }
      ]

      secrets = [
        {
          # PetClinic native env var name for the DB username
          name      = "MYSQL_USER"
          valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dev/app/rds:RDS_USER::"
        },
        {
          # PetClinic native env var name for the DB password
          name      = "MYSQL_PASS"
          valueFrom = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dev/app/rds:RDS_PASS::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/actuator/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = var.tags
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "app" {
  name            = var.ecs_service_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.ecs_task_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.asg.name
    weight            = 1
    base              = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  # 30-second grace period lets the JVM start before ALB health checks begin
  health_check_grace_period_seconds = 30

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_task_execution_managed
  ]

  tags = merge(var.tags, { Name = var.ecs_service_name })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.app.name
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution IAM role"
  value       = aws_iam_role.ecs_task_execution.arn
}

# ── Secrets Manager: Pipeline Infrastructure Values ───────────────────────────
# Terraform writes the RDS endpoint and RDS security group ID into Secrets
# Manager after provisioning. The GitHub Actions db-migrate workflow reads
# these at runtime — no hardcoded values in GitHub Secrets needed.

resource "aws_secretsmanager_secret" "pipeline_infra" {
  name                    = "dev/pipeline/infra"
  description             = "Infrastructure values written by Terraform for use in GitHub Actions"
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "pipeline_infra" {
  secret_id = aws_secretsmanager_secret.pipeline_infra.id

  secret_string = jsonencode({
    RDS_HOST  = aws_db_instance.main.address
    RDS_PORT  = tostring(aws_db_instance.main.port)
    RDS_SG_ID = aws_security_group.rds.id
    ALB_DNS   = aws_lb.main.dns_name
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "pipeline_infra_secret_arn" {
  description = "ARN of the Secrets Manager secret containing pipeline infra values"
  value       = aws_secretsmanager_secret.pipeline_infra.arn
}
