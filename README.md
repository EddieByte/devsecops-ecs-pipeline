# DevSecOps ECS Pipeline — GitHub Actions, Terraform & AWS

> A production-ready DevSecOps pipeline delivering a Java Spring Boot application to an **air-gapped Amazon ECS on EC2 cluster**, with automated security scanning, zero static credentials, and no NAT Gateway.

---

## Situation

A Java-based web application (vProfile) was being deployed manually through the AWS console — a process that was slow, error-prone, and insecure. Credentials were hardcoded into deployment scripts, infrastructure existed only as undocumented console clicks, and there was no automated security testing.

Beyond the operational risk, the networking design exposed private workloads unnecessarily. A NAT Gateway was the only path out of the private subnet — routing all container traffic through the public internet at **$0.045 per GB** in data processing fees, with no controls over what external endpoints containers could reach.

The team needed to eliminate these risks without sacrificing engineering velocity, and do it in a way that was reproducible, auditable, and cost-efficient.

---

## Task

Design and implement a fully automated DevSecOps pipeline that:

- **Removes all static AWS credentials** from the CI/CD system
- **Enforces automated security gates** before any artifact reaches production
- **Provisions all infrastructure via code** so environments are reproducible and auditable
- **Eliminates the NAT Gateway** — replacing it with VPC Endpoints to keep private subnet traffic entirely within the AWS backbone
- **Automates the full delivery lifecycle** from code commit to running ECS service with no manual steps

---

## Action

### 1. Identity Federation with OIDC
Eliminated long-lived IAM Access Keys entirely. GitHub Actions authenticates to AWS using OpenID Connect (OIDC), assuming a least-privilege IAM role via short-lived tokens. No static AWS secrets exist anywhere in the pipeline.

### 2. Shift-Left Security — Two Automated Gates

**Gate 1 — SAST & Quality (SonarCloud)**
Every push triggers a Maven build with JaCoCo coverage and Checkstyle reporting. SonarCloud evaluates results against a Quality Gate that fails the pipeline if the bug count exceeds 35. No code advances to containerisation until this passes.

**Gate 2 — Container Image Scanning (Trivy)**
After the Docker image is built, Trivy scans it with `--exit-code 1 --severity CRITICAL --ignore-unfixed`. Any unpatched critical CVE in the OS or application layers blocks the ECR push. Scan results are saved as JSON pipeline artifacts for audit. Only clean images are promoted.

### 3. Air-Gapped, NAT-less VPC Architecture

The central architectural decision is the **complete removal of the NAT Gateway**. All external internet interactions — Maven dependency resolution, Trivy vulnerability database downloads, base image pulls — happen inside GitHub Actions on internet-connected runners *before* anything touches AWS. Once an image is pushed to ECR, the AWS infrastructure never needs to reach the public internet again.

```
                          [ PUBLIC INTERNET ]
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │    GitHub Actions (Runner)    │
                    │  • mvn package               │
                    │  • Trivy image scan          │
                    │  • docker build + push → ECR │
                    └──────────────┬───────────────┘
                                   │ ECR push only
                                   ▼
┌──────────────────────────────────────────────────────────────────┐
│ AWS VPC  (10.0.0.0/16)                                           │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Public Subnets (10.0.1.0/24, 10.0.2.0/24)                 │  │
│  │   └── Application Load Balancer  ← HTTP :80 from internet  │  │
│  └───────────────────────┬────────────────────────────────────┘  │
│                          │ forwards to dynamic host ports        │
│  ┌───────────────────────▼────────────────────────────────────┐  │
│  │ Private Subnets (10.0.11.0/24, 10.0.12.0/24)              │  │
│  │            *** NO INTERNET ROUTE ***                       │  │
│  │                                                            │  │
│  │  ECS EC2 t3.small (Amazon Linux 2023 ECS-Optimized)        │  │
│  │    └── Spring Boot containers  (Bridge / Dynamic Port)     │  │
│  │                                                            │  │
│  │  ┌──────────────┐   ┌────────────────────────────────────┐ │  │
│  │  │ RDS MySQL    │   │ VPC Endpoints (PrivateLink)        │ │  │
│  │  │ 8.0.35       │   │  Gateway (free):  S3               │ │  │
│  │  │ db.t3.micro  │   │  Interface:  ECR api + dkr         │ │  │
│  │  │ private only │   │             ECS + agent + telemetry│ │  │
│  │  └──────────────┘   │             CloudWatch Logs        │ │  │
│  │                     │             Secrets Manager        │ │  │
│  │                     │             SSM + SSMMessages      │ │  │
│  │                     └────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

Private subnet route tables contain **no `0.0.0.0/0` entry**. This is verified at the Terraform layer — the `aws_route_table.private` resource has no internet route block. The ECS EC2 security group egress is locked to port 443 toward the VPC CIDR (for PrivateLink) and port 3306 toward the VPC CIDR (for RDS only).

### 4. VPC Endpoints — The Replacement for NAT

Two types of endpoints replace all NAT traffic:

| Endpoint | Type | Cost | Purpose |
|---|---|---|---|
| S3 | Gateway | **Free** | ECR image layer blob downloads (the bulk of pull traffic) |
| `ecr.api` | Interface | ~$0.01/hr/AZ | Docker auth and manifest API |
| `ecr.dkr` | Interface | ~$0.01/hr/AZ | `docker pull` layer queries |
| `ecs` | Interface | ~$0.01/hr/AZ | ECS control plane |
| `ecs-agent` | Interface | ~$0.01/hr/AZ | Container instance registration |
| `ecs-telemetry` | Interface | ~$0.01/hr/AZ | Metrics and status updates |
| `logs` | Interface | ~$0.01/hr/AZ | CloudWatch container log delivery |
| `secretsmanager` | Interface | ~$0.01/hr/AZ | Runtime credential injection |
| `ssm` / `ssmmessages` | Interface | ~$0.01/hr/AZ | Session Manager — no SSH, no Bastion |

`private_dns_enabled = true` on every Interface Endpoint means the standard AWS SDK hostnames (e.g. `ecr.us-east-1.amazonaws.com`) resolve to private ENI IPs automatically — no application or agent config changes needed.

### 5. Infrastructure as Code (Terraform)

Every AWS resource is declared in Terraform — nothing exists outside version control:

| File | What it provisions |
|---|---|
| `vpc.tf` | VPC, public/private subnets, IGW, public route table, **air-gapped private route table**, S3 Gateway Endpoint, all security groups, ALB |
| `vpc_endpoints.tf` | 9 Interface Endpoints via `for_each`, placed in both private AZs |
| `main.tf` | ECR repository, IAM roles, ECS-Optimized AL2023 Launch Template, ASG, ECS Cluster, Capacity Provider, Task Definition, ECS Service |
| `rds.tf` | MySQL 8.0.35 on `db.t3.micro`, encrypted, private, deletion-protected |
| `variables.tf` | All environment-specific configuration in one place |

### 6. Secrets Management — Zero Plaintext Credentials
The ECS Task Definition pulls `JDBC_USERNAME` and `JDBC_PASSWORD` directly from AWS Secrets Manager at container startup via the `secrets` block. The Secrets Manager Interface Endpoint ensures this call never leaves the VPC. Spring Boot consumes them as environment variables — no credentials exist at any image layer.

### 7. Three-Stage GitHub Actions Pipeline

```
Push to main
     │
     ▼
┌─────────────┐     fail
│    TEST     │──────────────► ✗ Block
│ Maven + SAST│               (Bugs > 35 or test failure)
└──────┬──────┘
       │ pass
       ▼
┌──────────────────┐   fail
│ BUILD_AND_PUBLISH│──────────► ✗ Block
│ Docker + Trivy   │           (Critical CVE detected)
└────────┬─────────┘
         │ pass → push to ECR
         ▼
┌──────────────┐
│    DEPLOY    │
│  OIDC auth   │──────────────► ✓ Live on ECS
│  ECS update  │
└──────────────┘
```

---

## Result

| Metric | Before | After |
|---|---|---|
| AWS credential exposure | Static IAM keys in GitHub Secrets | Zero — OIDC short-lived tokens only |
| Deployment method | Manual console clicks | Fully automated on every push to `main` |
| Security testing | None | SAST (SonarCloud) + image scan (Trivy) on every build |
| Infrastructure state | Undocumented, console-only | 100% Terraform — versioned, reproducible |
| Secret handling | Plaintext injection via `sed` | AWS Secrets Manager via PrivateLink at runtime |
| Internet exposure of private workloads | NAT Gateway — all traffic via public internet | Zero — private subnets have no internet route |
| NAT Gateway cost | $0.045/GB data processing | **$0 — eliminated entirely** |
| Operational access to EC2 | SSH with open port 22 or Bastion host | AWS SSM Session Manager via VPC Endpoint |
| Audit trail | None | GitHub Actions logs + CloudWatch + Trivy JSON reports |

The pipeline enforces a "Zero Critical Vulnerabilities" policy programmatically — no human approval step can bypass it. The private subnets are provably air-gapped: inspecting the Terraform route table confirms no `0.0.0.0/0` route exists. All AWS service calls travel over the private AWS backbone via PrivateLink. Infrastructure is destroyed and recreated identically in minutes.

---

## Repository Structure

```
.
├── .github/workflows/
│   └── main.yml                    # DevSecOps pipeline (OIDC + Trivy + SonarCloud)
├── aws-files/
│   └── taskdeffile.json            # ECS Task Definition with Secrets Manager mapping
├── terraform/
│   ├── main.tf                     # ECS Cluster, Capacity Provider, IAM, ECR, Service
│   ├── vpc.tf                      # VPC, subnets, ALB, security groups, S3 endpoint
│   ├── vpc_endpoints.tf            # 9 PrivateLink Interface Endpoints
│   ├── rds.tf                      # MySQL 8.0.35 RDS instance
│   └── variables.tf                # All configurable inputs
├── src/
│   └── main/
│       ├── java/org/springframework/samples/petclinic/
│       │   └── ...                 # Spring PetClinic application source
│       └── resources/
│           ├── application.properties        # Base config (H2 default for CI tests)
│           ├── application-mysql.properties  # MySQL profile (activated in ECS)
│           ├── db/mysql/
│           │   ├── schema.sql      # PetClinic DDL — auto-run by Spring Boot on startup
│           │   └── data.sql        # Seed data — auto-run by Spring Boot on startup
│           └── db_backup.sql       # One-time RDS bootstrap (DB + user + schema + data)
├── Dockerfile                      # Java 17 multi-stage build (Temurin JDK → JRE)
└── pom.xml                         # Maven — Spring Boot 3.2.4, JaCoCo, Checkstyle, Sonar
```

---

## Application — Spring PetClinic

The application is [Spring PetClinic](https://github.com/spring-projects/spring-petclinic) — the official Spring Framework demo app. It is a Java 17 Spring Boot web application with a MySQL backend managing veterinary clinic records (owners, pets, vets, visits).

### How it fits into this pipeline

| Concern | How it's handled |
|---|---|
| **Source** | Clone `https://github.com/spring-projects/spring-petclinic` and copy the `src/` tree into this repo |
| **Build** | `mvn package -DskipTests` produces `target/spring-petclinic.jar` (executable JAR with embedded Tomcat) |
| **CI tests** | Default profile uses H2 in-memory DB — no RDS needed during the TEST job |
| **Production profile** | `SPRING_PROFILES_ACTIVE=mysql` activates `application-mysql.properties` in ECS |
| **DB connection** | PetClinic reads `MYSQL_URL`, `MYSQL_USER`, `MYSQL_PASS` — injected by ECS from Secrets Manager |
| **Schema init** | `spring.sql.init.mode=always` — Spring Boot auto-runs `db/mysql/schema.sql` + `data.sql` on startup |
| **First-time RDS setup** | Run `db_backup.sql` once against RDS before first deployment |
| **Health check** | ALB and ECS container health check hits `/actuator/health` (returns HTTP 200) |

### Getting the application source

```powershell
# Clone PetClinic separately
git clone https://github.com/spring-projects/spring-petclinic.git

# Copy the src tree into this pipeline repo (overwrites the placeholder src/)
Copy-Item -Recurse -Force spring-petclinic\src `
  d:\eddie-register-app\Project\devsecops-ecs-pipeline\src
```

**Do not copy** PetClinic's `pom.xml` or `Dockerfile` — ours are purpose-built for this pipeline with the DevSecOps plugins (JaCoCo, Checkstyle, SonarCloud) and the secure multi-stage Docker build.

### Environment variables (ECS Task Definition)

| Variable | Type | Source | Purpose |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | Plain env var | Task def | Activates `mysql` profile |
| `MYSQL_URL` | Plain env var | Task def | Full JDBC URL pointing to RDS endpoint |
| `MYSQL_USER` | Secret | Secrets Manager → `prod/app/rds:RDS_USER` | DB username |
| `MYSQL_PASS` | Secret | Secrets Manager → `prod/app/rds:RDS_PASS` | DB password |

### One-time RDS database bootstrap

Before the first deployment, run this against your RDS instance:

```powershell
mysql -h <terraform_output_rds_address> -u admin -p `
  < src\main\resources\db_backup.sql
```

This creates the `petclinic` database, the `petclinic` user, all 7 tables, and the seed data. After this, `spring.sql.init.mode=always` keeps schema and data idempotently in sync on every container restart.

---

## Required GitHub Secrets

| Secret | Description |
|---|---|
| `AWS_ROLE_TO_ASSUME` | ARN of the OIDC IAM role — no static keys |
| `AWS_REGION` | Target AWS region (e.g. `us-east-1`) |
| `REGISTRY` | ECR registry URI |
| `SONAR_TOKEN` | SonarCloud authentication token |
| `SONAR_PROJECT_KEY` | SonarCloud project identifier |
| `SONAR_ORGANIZATION` | SonarCloud organisation name |

---

## Tech Stack

- **CI/CD:** GitHub Actions
- **Security Scanning:** SonarCloud (SAST), Trivy (container CVE)
- **IaC:** Terraform ≥ 1.6
- **Runtime:** Java 17 (Temurin), Spring Boot 3.2.4, Apache Tomcat 9
- **Containers:** Docker, Amazon ECR
- **Orchestration:** Amazon ECS on EC2 — Bridge mode, Dynamic Port Mapping
- **Networking:** AWS VPC, ALB, VPC PrivateLink (9 Interface Endpoints + S3 Gateway)
- **Database:** Amazon RDS MySQL 8.0.35
- **Secrets:** AWS Secrets Manager (via PrivateLink)
- **Access:** AWS SSM Session Manager (no SSH, no Bastion)
- **Observability:** Amazon CloudWatch Logs, ECS Container Insights
