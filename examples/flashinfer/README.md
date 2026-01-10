# FlashInfer GitHub Actions Runners

This Terraform configuration deploys self-hosted GitHub Actions runners for the FlashInfer project on AWS EC2.

## Features

- **Multi-runner support**: CPU (x64, ARM64) and GPU (T4, A10G) runners
- **Spot instances with failover**: Automatically falls back to on-demand if spot unavailable
- **Reuse mode**: Runners are reused across jobs for faster startup
- **Warm pool**: Keeps runners available during work hours
- **Full observability**: Tracing, metrics, and CloudWatch logging

## Prerequisites

1. AWS account with appropriate permissions
2. GitHub App configured for the `flashinfer-ai` organization
3. Terraform >= 1.3.0
4. Lambda zip files downloaded (see below)

## Quick Start

### 1. Download Lambda Packages

```bash
cd ../lambdas-download
terraform init
terraform apply -var=module_version=<VERSION>
cd ../flashinfer
```

### 2. Set Environment Variables (Recommended)

Use environment variables for secrets - this keeps sensitive data out of files:

```bash
# Copy and edit the setup script
cp setup-env.sh.example setup-env.sh

# Edit setup-env.sh with your GitHub App credentials, then:
source setup-env.sh
```

Or set variables directly:

```bash
export TF_VAR_github_app_id="YOUR_APP_ID"
export TF_VAR_github_app_key_base64="$(base64 -i /path/to/your-app.private-key.pem)"
export TF_VAR_webhook_secret="$(openssl rand -hex 32)"
```

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 4. Configure GitHub App Webhook

After deployment:

```bash
# Get webhook URL
terraform output webhook_endpoint

# Get webhook secret
terraform output -raw webhook_secret
```

Configure in GitHub App settings:
- Webhook URL: `<webhook_endpoint output>`
- Webhook Secret: `<webhook_secret output>`
- Content Type: `application/json`
- Events: Subscribe to **Workflow Job** only

## Runner Types

| Type | Labels | Instance Types | Use Case |
|------|--------|----------------|----------|
| CPU x64 | `self-hosted, linux, x64, cpu` | m5.large, c5.large | Lint, AOT builds |
| CPU ARM64 | `self-hosted, linux, arm64, cpu` | c6g.large, t4g.large | ARM builds |
| GPU G4dn | `self-hosted, linux, x64, gpu, sm75` | g4dn.xlarge | T4 tests |
| GPU G5 | `self-hosted, linux, x64, gpu, sm86` | g5.xlarge | A10G tests |

## Workflow Usage

```yaml
jobs:
  lint:
    runs-on: [self-hosted, linux, x64, cpu]
    
  gpu-test:
    runs-on: [self-hosted, linux, x64, gpu, sm86]
```

## Adding New GPU Types

See [templates/GPU_TYPES.md](templates/GPU_TYPES.md) for instructions on adding H100, B200, etc.

## Troubleshooting

### Check Lambda Logs

```bash
aws logs tail /aws/lambda/flashinfer-webhook --follow
aws logs tail /aws/lambda/flashinfer-scale-up --follow
```

### Connect to Runner

```bash
aws ssm start-session --target i-INSTANCE_ID
```

### View Runner Logs

```bash
cat /var/log/user-data.log
```

## Cost Optimization

- Spot instances with on-demand failover
- Scale down to 0 outside work hours
- Warm pool only during PST business hours
- GPU instances have 15-minute minimum runtime

## Architecture

```
GitHub webhook → API Gateway → Lambda (webhook) → SQS → Lambda (scale-up) → EC2
                                                                              ↓
                                                                         GitHub Runner
```

## Cleanup

```bash
terraform destroy
```

## Related Documentation

- [Phase 3 Implementation Plan](../../PHASE3_TERRAFORM_CONFIGURATION.md)
- [terraform-aws-github-runner docs](https://github-aws-runners.github.io/terraform-aws-github-runner/)
