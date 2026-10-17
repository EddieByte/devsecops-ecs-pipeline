variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resource names"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

# -- Networking -----------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ, hosts the ALB)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ, hosts RDS and ECS instances)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "availability_zones" {
  description = "List of AZs for multi-AZ deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# -- ECS / EC2 Compute ----------------------------------------------------------

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
  default     = "petclinic-cluster"
}

variable "ecs_service_name" {
  description = "Name of the ECS service"
  type        = string
  default     = "petclinic-svc"
}

variable "ec2_instance_type" {
  description = "EC2 instance type for ECS container instances. t3.medium provides 4 GiB RAM — required to run a Spring Boot JVM task (2048 MiB) with headroom for the OS and ECS agent."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = contains(["t3.medium", "t3.large", "t3.xlarge", "m5.large", "m5.xlarge"], var.ec2_instance_type)
    error_message = "Instance type must be t3.medium or larger. t3.small cannot fit a 2048 MiB ECS task alongside OS and ECS agent overhead."
  }
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances in the Auto Scaling Group"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances in the Auto Scaling Group"
  type        = number
  default     = 3
}

variable "asg_desired_capacity" {
  description = "Desired number of EC2 instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "ecs_task_desired_count" {
  description = "Number of ECS task instances to run"
  type        = number
  default     = 2
}

variable "container_port" {
  description = "Port the application container listens on"
  type        = number
  default     = 8080
}

variable "alb_listener_port" {
  description = "Port the ALB listens on for inbound traffic"
  type        = number
  default     = 80
}

# -- Container / ECR -----------------------------------------------------------

variable "ecr_repository_name" {
  description = "Name of the Amazon ECR repository"
  type        = string
  default     = "petclinic"
}

variable "container_name" {
  description = "Name of the container inside the ECS task definition"
  type        = string
  default     = "petclinic-app"
}

# -- RDS MySQL -----------------------------------------------------------------

variable "db_identifier" {
  description = "Unique identifier for the RDS instance"
  type        = string
  default     = "petclinic-db"
}

variable "db_engine_version" {
  description = "MySQL engine version"
  type        = string
  default     = "8.0.46"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage for the RDS instance (GiB)"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the initial database"
  type        = string
  default     = "accounts"
}

variable "db_username" {
  description = "Master username for the RDS instance (store actual value in Secrets Manager)"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "db_password" {
  description = "Master password for the RDS instance (store actual value in Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "db_backup_retention_days" {
  description = "Number of days to retain automated RDS backups"
  type        = number
  default     = 7
}

# -- Secrets Manager -----------------------------------------------------------

variable "secrets_manager_arn" {
  description = "ARN of the AWS Secrets Manager secret containing RDS credentials"
  type        = string
  default     = ""
}

# -- GitHub OIDC ---------------------------------------------------------------

variable "github_org_id" {
  description = "GitHub organisation or user numeric ID (from OIDC token sub claim)"
  type        = string
}

variable "github_repo_id" {
  description = "GitHub repository numeric ID (from OIDC token sub claim)"
  type        = string
}

variable "github_org" {
  description = "GitHub organisation or user account (e.g. 'my-org'). Used to scope the OIDC trust policy."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without the org prefix (e.g. 'devsecops-ecs-pipeline'). Used to scope the OIDC trust policy."
  type        = string
}

# -- Tagging -------------------------------------------------------------------

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "petclinic"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
