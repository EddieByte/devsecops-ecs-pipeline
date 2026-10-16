# ------------------------------------------------------------------------------
# scripts/teardown.ps1 - Graceful pre-destroy sequencing for ECS on EC2
#
# Run this BEFORE `terraform destroy` to avoid two known failure modes:
#
#   1. ECS service stuck in DRAINING for 20+ minutes (and timing out)
#      Root cause: managed_termination_protection = ENABLED on the capacity
#      provider prevents the ASG from terminating EC2 instances, so tasks
#      have nowhere to drain to - they hang indefinitely.
#
#   2. IGW DependencyViolation - "Network has some mapped public address(es)"
#      Root cause: ASG EC2 instances hold Elastic IPs. The IGW cannot detach
#      from the VPC until those instances terminate and release their IPs.
#      This is a cascading failure from problem 1.
#
# Correct teardown sequence:
#   1. Scale ECS service to 0        -> tasks stop immediately, no drain wait
#   2. Disable termination protection -> ASG can now terminate EC2 instances
#   3. Scale ASG down to 0           -> EC2 instances terminate, EIPs released
#   4. terraform destroy             -> everything else deletes cleanly
#
# Usage (from project root):
#   .\scripts\teardown.ps1
#   .\scripts\teardown.ps1 -Region eu-west-1 -Cluster my-cluster -Service my-svc -Asg my-asg
# ------------------------------------------------------------------------------

param(
  [string]$Region  = "us-east-1",
  [string]$Cluster = "github-actions-app",
  [string]$Service = "github-actions-svc",
  [string]$Asg     = "github-actions-ecs-asg"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Step($msg) {
  Write-Host ""
  Write-Host "==> $msg" -ForegroundColor Cyan
}

function Done($msg) {
  Write-Host "    $msg" -ForegroundColor Green
}

# -- Verify AWS connectivity ---------------------------------------------------

Step "Verifying AWS credentials..."
$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
Done "Account: $($identity.Account)  |  ARN: $($identity.Arn)"

# -- Step 1: Scale ECS service to 0 -------------------------------------------
# Setting desired count to 0 stops all running tasks immediately.
# The service enters DRAINING briefly but completes in seconds - not minutes -
# because there are no new tasks to wait for.

Step "Scaling ECS service '$Service' to 0 tasks..."
aws ecs update-service `
  --cluster $Cluster `
  --service $Service `
  --desired-count 0 `
  --region $Region | Out-Null

# Wait until the running count reaches 0
Write-Host "    Waiting for tasks to stop..." -NoNewline
$maxWait = 120  # seconds
$elapsed = 0
do {
  Start-Sleep -Seconds 5
  $elapsed += 5
  $running = aws ecs describe-services `
    --cluster $Cluster `
    --services $Service `
    --region $Region `
    --query "services[0].runningCount" `
    --output text
  Write-Host "." -NoNewline
} while ($running -ne "0" -and $elapsed -lt $maxWait)

if ($running -eq "0") {
  Write-Host ""
  Done "All tasks stopped."
} else {
  Write-Host ""
  Write-Warning "Tasks did not stop within ${maxWait}s (running: $running). Continuing anyway."
}

# -- Step 2: Disable ASG termination protection -------------------------------
# managed_termination_protection = ENABLED on the capacity provider sets
# instance-level scale-in protection on every EC2 in the ASG. Terraform cannot
# delete the capacity provider while this is active, and the ASG cannot
# terminate instances either. We disable it here before destroy runs.

Step "Disabling scale-in protection on all instances in ASG '$Asg'..."
$instanceIds = aws autoscaling describe-auto-scaling-groups `
  --auto-scaling-group-names $Asg `
  --region $Region `
  --query "AutoScalingGroups[0].Instances[*].InstanceId" `
  --output text

if ($instanceIds -and $instanceIds -ne "None") {
  $ids = $instanceIds -split "`t"
  foreach ($id in $ids) {
    aws autoscaling set-instance-protection `
      --instance-ids $id `
      --auto-scaling-group-name $Asg `
      --no-protected-from-scale-in `
      --region $Region | Out-Null
    Done "Removed protection from $id"
  }
} else {
  Done "No instances found in ASG - already scaled down or not yet created."
}

# -- Step 3: Scale ASG down to 0 ----------------------------------------------
# Terminates all EC2 instances, which releases any Elastic IPs they hold.
# The IGW DependencyViolation error occurs because EIPs are still mapped
# when Terraform tries to detach the IGW. Scaling to 0 first prevents this.

Step "Scaling ASG '$Asg' to 0 instances..."
aws autoscaling update-auto-scaling-group `
  --auto-scaling-group-name $Asg `
  --min-size 0 `
  --max-size 0 `
  --desired-capacity 0 `
  --region $Region | Out-Null

# Wait for instances to terminate
Write-Host "    Waiting for EC2 instances to terminate..." -NoNewline
$elapsed = 0
$maxWait = 300  # RDS-grade wait - EC2 termination is usually <60s
do {
  Start-Sleep -Seconds 10
  $elapsed += 10
  $count = aws autoscaling describe-auto-scaling-groups `
    --auto-scaling-group-names $Asg `
    --region $Region `
    --query "length(AutoScalingGroups[0].Instances)" `
    --output text
  Write-Host "." -NoNewline
} while ($count -ne "0" -and $elapsed -lt $maxWait)

if ($count -eq "0") {
  Write-Host ""
  Done "All EC2 instances terminated."
} else {
  Write-Host ""
  Write-Warning "Instances did not terminate within ${maxWait}s (count: $count). Continuing anyway."
}

# -- Done ---------------------------------------------------------------------

Write-Host ""
Write-Host "Pre-destroy sequence complete." -ForegroundColor Green
Write-Host ""
Write-Host "Run next (from terraform/ directory):" -ForegroundColor Cyan
Write-Host "  cd terraform"
Write-Host "  terraform destroy"
Write-Host ""
