# ──────────────────────────────────────────────────────────────────────────────
# scripts/drain_tasks.ps1
#
# Stops all running and pending ECS tasks on the cluster so that
# stuck deployments clear out and memory is freed for new placements.
#
# Usage:
#   .\scripts\drain_tasks.ps1
# ──────────────────────────────────────────────────────────────────────────────

param(
    [string]$Cluster = "github-actions-app",
    [string]$Region  = "us-east-1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($status in @("RUNNING", "PENDING")) {
    $tasks = aws ecs list-tasks `
        --cluster $Cluster `
        --desired-status $status `
        --region $Region `
        --query "taskArns" `
        --output json | ConvertFrom-Json

    if ($tasks.Count -eq 0) {
        Write-Host "No $status tasks found." -ForegroundColor Yellow
        continue
    }

    foreach ($task in $tasks) {
        Write-Host "Stopping $status task: $task" -ForegroundColor Cyan
        aws ecs stop-task --cluster $Cluster --task $task --region $Region | Out-Null
    }
}

Write-Host ""
Write-Host "Waiting 30s for tasks to drain..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Show remaining memory
$instances = aws ecs list-container-instances `
    --cluster $Cluster `
    --region $Region `
    --query "containerInstanceArns" `
    --output json | ConvertFrom-Json

Write-Host ""
Write-Host "Memory available per instance:" -ForegroundColor Green
aws ecs describe-container-instances `
    --cluster $Cluster `
    --container-instances $instances `
    --region $Region `
    --query "containerInstances[*].{EC2:ec2InstanceId, RemainingMem:remainingResources[?name=='MEMORY'].integerValue|[0]}" `
    --output table

Write-Host ""
Write-Host "Check service status:" -ForegroundColor Cyan
aws ecs describe-services `
    --cluster $Cluster `
    --services github-actions-svc `
    --region $Region `
    --query "services[0].{running:runningCount,pending:pendingCount,desired:desiredCount}" `
    --output table
