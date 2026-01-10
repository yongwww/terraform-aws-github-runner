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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.21 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_base"></a> [base](#module\_base) | ../base | n/a |
| <a name="module_runners"></a> [runners](#module\_runners) | ../../modules/multi-runner | n/a |
| <a name="module_webhook_github_app"></a> [webhook\_github\_app](#module\_webhook\_github\_app) | ../../modules/webhook-github-app | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy to | `string` | `"us-west-2"` | no |
| <a name="input_github_app_id"></a> [github\_app\_id](#input\_github\_app\_id) | GitHub App ID | `string` | n/a | yes |
| <a name="input_github_app_key_base64"></a> [github\_app\_key\_base64](#input\_github\_app\_key\_base64) | GitHub App private key (base64 encoded). Generate with: base64 -i your-app.private-key.pem | `string` | n/a | yes |
| <a name="input_webhook_secret"></a> [webhook\_secret](#input\_webhook\_secret) | Webhook secret for GitHub App. Generate with: openssl rand -hex 32 | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | Private subnet IDs where runners are launched |
| <a name="output_runners_map"></a> [runners\_map](#output\_runners\_map) | Map of runner configurations and their details |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID where runners are deployed |
| <a name="output_webhook_endpoint"></a> [webhook\_endpoint](#output\_webhook\_endpoint) | Webhook endpoint URL for GitHub App configuration |
| <a name="output_webhook_secret"></a> [webhook\_secret](#output\_webhook\_secret) | Webhook secret for GitHub App configuration. Use: terraform output -raw webhook\_secret |
<!-- END_TF_DOCS -->