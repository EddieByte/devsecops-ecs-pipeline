# ──────────────────────────────────────────────────────────────────────────────
# scripts/patch_task_memory.ps1
#
# Registers a new ECS task definition revision with reduced memory (1536 MiB)
# to fix RESOURCE:MEMORY placement failures on t3.small instances.
#
# Run once manually after authenticating to AWS:
#   .\scripts\patch_task_memory.ps1
# ──────────────────────────────────────────────────────────────────────────────

param(
    [string]$Cluster       = "petclinic-cluster",
    [string]$Service       = "petclinic-svc",
    [string]$TaskFamily    = "petclinic",
    [string]$Region        = "us-east-1",
    [int]   $DesiredCount  = 1,
    [int]   $TaskMemory    = 2048,
    [int]   $TaskCpu       = 1024
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Verify credentials ────────────────────────────────────────────────────────
Write-Host "Verifying AWS credentials..." -ForegroundColor Cyan
$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
Write-Host "  Account: $($identity.Account)" -ForegroundColor Green

# ── Fetch current task definition ─────────────────────────────────────────────
Write-Host "Fetching task definition: $TaskFamily..." -ForegroundColor Cyan
$td = aws ecs describe-task-definition `
    --task-definition $TaskFamily `
    --region $Region `
    --query "taskDefinition" `
    --output json | ConvertFrom-Json

Write-Host "  Current memory : $($td.memory) MiB"
Write-Host "  Current cpu    : $($td.cpu)"

# ── Patch values ──────────────────────────────────────────────────────────────
Write-Host "Patching to memory=$TaskMemory, cpu=$TaskCpu..." -ForegroundColor Cyan

# Task-level memory and cpu are strings in the ECS API
$td | Add-Member -Force -MemberType NoteProperty -Name "memory" -Value "$TaskMemory"
$td | Add-Member -Force -MemberType NoteProperty -Name "cpu"    -Value "$TaskCpu"

# Container-level values are integers
$td.containerDefinitions[0] | Add-Member -Force -MemberType NoteProperty -Name "memory" -Value $TaskMemory
$td.containerDefinitions[0] | Add-Member -Force -MemberType NoteProperty -Name "cpu"    -Value $TaskCpu

# ── Strip read-only fields ────────────────────────────────────────────────────
$readOnly = @(
    'taskDefinitionArn', 'revision', 'status',
    'registeredAt', 'registeredBy',
    'compatibilities', 'requiresAttributes'
)
foreach ($k in $readOnly) {
    $td.PSObject.Properties.Remove($k)
}

# ── Write patched JSON (ASCII — AWS CLI rejects UTF-8 BOM) ───────────────────
$patchedPath = "$env:TEMP\taskdef-patched.json"
$json = $td | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($patchedPath, $json, [System.Text.Encoding]::ASCII)
Write-Host "  Written to: $patchedPath" -ForegroundColor Green

# ── Register new task definition revision ─────────────────────────────────────
Write-Host "Registering new task definition revision..." -ForegroundColor Cyan
$result = aws ecs register-task-definition `
    --cli-input-json "file://$patchedPath" `
    --region $Region `
    --output json | ConvertFrom-Json

$newArn = $result.taskDefinition.taskDefinitionArn
Write-Host "  Registered: $newArn" -ForegroundColor Green

# ── Update ECS service ────────────────────────────────────────────────────────
Write-Host "Updating service to desired-count=$DesiredCount..." -ForegroundColor Cyan
aws ecs update-service `
    --cluster $Cluster `
    --service $Service `
    --task-definition $TaskFamily `
    --desired-count $DesiredCount `
    --region $Region | Out-Null

Write-Host ""
Write-Host "Done. Service updated to use $newArn" -ForegroundColor Green
Write-Host "Monitor progress:"
Write-Host "  aws ecs describe-services --cluster $Cluster --services $Service --query 'services[0].{running:runningCount,pending:pendingCount,desired:desiredCount}'"
