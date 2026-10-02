# ──────────────────────────────────────────────────────────────────────────────
# RDS MySQL 8.0.35
# Provisions: DB subnet group, parameter group, and the RDS instance.
# publicly_accessible = false — accessible only from ECS EC2 SG via port 3306.
# ──────────────────────────────────────────────────────────────────────────────

# ── DB Subnet Group (private subnets only) ────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnet-group"
  description = "Private subnets for RDS MySQL - not internet accessible"
  subnet_ids  = aws_subnet.private[*].id

  tags = merge(var.tags, { Name = "${var.project_name}-db-subnet-group" })
}

# ── MySQL 8.0 Parameter Group ─────────────────────────────────────────────────

resource "aws_db_parameter_group" "mysql8" {
  name        = "${var.project_name}-mysql8-params"
  family      = "mysql8.0"
  description = "Custom parameter group for MySQL 8.0.35"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "max_connections"
    value = "100"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  tags = merge(var.tags, { Name = "${var.project_name}-mysql8-params" })
}

# ── RDS MySQL 8.0.35 Instance ─────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = var.db_identifier

  # Engine
  engine               = "mysql"
  engine_version       = var.db_engine_version   # 8.0.35
  instance_class       = var.db_instance_class   # db.t3.micro

  # Storage
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = 100
  storage_type          = "gp2"
  storage_encrypted     = true

  # Credentials — source of truth is Secrets Manager; these bootstrap the instance.
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  # Configuration
  parameter_group_name = aws_db_parameter_group.mysql8.name
  port                 = 3306

  # Backup & Maintenance
  backup_retention_period   = var.db_backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade = true
  deletion_protection       = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.db_identifier}-final-snapshot"

  # Monitoring — enhanced monitoring disabled for dev (requires a separate IAM role)
  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = merge(var.tags, { Name = "${var.project_name}-mysql-db" })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS instance endpoint (hostname:port)"
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "RDS instance hostname"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDS instance port"
  value       = aws_db_instance.main.port
}

output "rds_db_name" {
  description = "Name of the initial database"
  value       = aws_db_instance.main.db_name
}
