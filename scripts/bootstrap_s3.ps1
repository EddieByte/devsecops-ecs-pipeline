# ------------------------------------------------------------------------------
# bootstrap.ps1 - One-time backend setup
#
# Run this ONCE before the first `terraform init` in a new AWS account.
# It creates the S3 bucket that stores Terraform remote state.
#
# The bucket cannot be managed by Terraform itself (you can't store state
# about the thing that stores your state), so this script handles it.
#
# After this script succeeds, never run it again - use terraform apply
# for all subsequent infrastructure changes.
#
# Usage:
#   .\bootstrap.ps1
#   .\bootstrap.ps1 -Region eu-west-1   # override region
# ------------------------------------------------------------------------------

param(
  [string]$Region = "us-east-1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Derive values -------------------------------------------------------------

$AccountId = aws sts get-caller-identity --query Account --output text
if (-not $AccountId) {
  Write-Error "Could not determine AWS account ID. Check your AWS credentials."
  exit 1
}

$BucketName = "github-actions-tfstate-$AccountId"

Write-Host ""
Write-Host "Account : $AccountId"
Write-Host "Bucket  : $BucketName"
Write-Host "Region  : $Region"
Write-Host ""

# -- Check if bucket already exists -------------------------------------------

$exists = aws s3api head-bucket --bucket $BucketName 2>&1
if ($LASTEXITCODE -eq 0) {
  Write-Host "Bucket already exists - skipping creation." -ForegroundColor Yellow
} else {
  # -- Create bucket ---------------------------------------------------------
  Write-Host "Creating S3 bucket..." -ForegroundColor Cyan
  aws s3api create-bucket `
    --bucket $BucketName `
    --region $Region

  # -- Enable versioning -----------------------------------------------------
  Write-Host "Enabling versioning..." -ForegroundColor Cyan
  aws s3api put-bucket-versioning `
    --bucket $BucketName `
    --versioning-configuration Status=Enabled

  # -- Enable server-side encryption -----------------------------------------
  Write-Host "Enabling encryption..." -ForegroundColor Cyan
  $encryptionConfig = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-encryption `
    --bucket $BucketName `
    --server-side-encryption-configuration $encryptionConfig

  # -- Block all public access -----------------------------------------------
  Write-Host "Blocking public access..." -ForegroundColor Cyan
  aws s3api put-public-access-block `
    --bucket $BucketName `
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  Write-Host "Bucket created successfully." -ForegroundColor Green
}

# -- Verify backend.tf is aligned ---------------------------------------------

$backendFile = Join-Path $PSScriptRoot "..\terraform\backend.tf"
$backendContent = Get-Content $backendFile -Raw

if ($backendContent -notmatch [regex]::Escape($BucketName)) {
  Write-Host ""
  Write-Host "WARNING: backend.tf does not reference bucket '$BucketName'." -ForegroundColor Yellow
  Write-Host "         Update the bucket name in terraform\backend.tf before running terraform init." -ForegroundColor Yellow
} else {
  Write-Host "backend.tf is aligned with bucket name." -ForegroundColor Green
}

# -- Next steps ----------------------------------------------------------------

Write-Host ""
Write-Host "Bootstrap complete. Run next:" -ForegroundColor Green
Write-Host ""
Write-Host "  cd terraform"
Write-Host "  terraform init"
Write-Host "  terraform plan"
Write-Host "  terraform apply"
Write-Host ""
Write-Host "After apply, set this in GitHub Secrets as AWS_ROLE_TO_ASSUME:" -ForegroundColor Cyan
Write-Host "  terraform output github_actions_role_arn"
Write-Host ""
