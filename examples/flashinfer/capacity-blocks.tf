# =============================================================================
# Capacity Block Manager for FlashInfer CI
# =============================================================================
# This module manages AWS Capacity Block reservations for Blackwell/Hopper GPUs.
#
# The CB Manager Lambda:
# - Checks for active Capacity Blocks
# - Purchases new CBs when needed (on-demand)
# - Prevents duplicate purchases via SSM-based locking
# - Tracks CB state in SSM for visibility
#
# This is FlashInfer-specific and designed to be easily separated from the
# upstream terraform-aws-github-runner module.
# =============================================================================

locals {
  cb_manager_name = "${local.environment}-cb-manager"

  # Capacity Block configuration
  cb_config = {
    # P6 Blackwell (B200)
    p6_blackwell = {
      instance_type  = "p6-b200.48xlarge"
      duration_hours = 24  # Minimum 1 day
      enabled        = true
    }
    # P5 Hopper (H100) - for future use
    p5_hopper = {
      instance_type  = "p5.48xlarge"
      duration_hours = 24
      enabled        = false  # Enable when needed
    }
  }
}

# =============================================================================
# CB Manager Lambda
# =============================================================================

data "archive_file" "cb_manager" {
  type        = "zip"
  source_file = "${path.module}/lambdas/cb-manager/index.py"
  output_path = "${path.module}/lambdas/cb-manager/cb-manager.zip"
}

resource "aws_lambda_function" "cb_manager" {
  function_name = local.cb_manager_name
  description   = "Manages Capacity Block reservations for FlashInfer CI"

  filename         = data.archive_file.cb_manager.output_path
  source_code_hash = data.archive_file.cb_manager.output_base64sha256

  handler = "index.handler"
  runtime = "python3.11"
  timeout = 60

  role = aws_iam_role.cb_manager.arn

  environment {
    variables = {
      INSTANCE_TYPE     = local.cb_config.p6_blackwell.instance_type
      DURATION_HOURS    = tostring(local.cb_config.p6_blackwell.duration_hours)
      SSM_PREFIX        = "/flashinfer/capacity-blocks"
      SUBNET_IDS        = join(",", module.base.vpc.private_subnets)
      LOG_LEVEL         = "INFO"
    }
  }

  tags = {
    Name        = local.cb_manager_name
    Project     = "FlashInfer"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }
}

# =============================================================================
# IAM Role for CB Manager Lambda
# =============================================================================

resource "aws_iam_role" "cb_manager" {
  name = "${local.cb_manager_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${local.cb_manager_name}-role"
    Project     = "FlashInfer"
    Environment = local.environment
  }
}

resource "aws_iam_role_policy" "cb_manager" {
  name = "${local.cb_manager_name}-policy"
  role = aws_iam_role.cb_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      # EC2 Capacity Block operations
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeCapacityBlockOfferings",
          "ec2:PurchaseCapacityBlock"
        ]
        Resource = "*"
      },
      # EC2 Subnet info (for AZ detection)
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
      },
      # EC2 tagging for purchased CBs
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*:*:capacity-reservation/*"
      },
      # SSM for state tracking and locking
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/flashinfer/capacity-blocks/*"
      }
    ]
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "cb_manager" {
  name              = "/aws/lambda/${local.cb_manager_name}"
  retention_in_days = 30

  tags = {
    Name        = "${local.cb_manager_name}-logs"
    Project     = "FlashInfer"
    Environment = local.environment
  }
}

# =============================================================================
# EventBridge Rule - Dynamic Trigger on Job Request
# =============================================================================
# This rule triggers CB Manager when a job with sm100/blackwell labels is queued.
# The CB Manager runs BEFORE scale-up (which has delay_webhook_event delay).

# Get the EventBridge bus created by the runner module
data "aws_cloudwatch_event_bus" "runners" {
  name = "${local.environment}-runners"  # Created by module.runners.webhook.eventbridge
}

# Rule: Trigger CB Manager for Blackwell job requests
resource "aws_cloudwatch_event_rule" "cb_preflight" {
  name           = "${local.cb_manager_name}-preflight"
  description    = "Trigger CB Manager when Blackwell/Hopper job is requested"
  event_bus_name = data.aws_cloudwatch_event_bus.runners.name

  # Match workflow_job events with sm100, b200, or blackwell labels
  event_pattern = jsonencode({
    detail-type = ["workflow_job"]
    detail = {
      workflow_job = {
        labels = [
          { "equals-ignore-case" = "sm100" },
        ]
      }
    }
  })

  tags = {
    Name        = "${local.cb_manager_name}-preflight"
    Project     = "FlashInfer"
    Environment = local.environment
  }
}

# Alternative rule pattern if the above doesn't match
# (GitHub webhook format may vary)
resource "aws_cloudwatch_event_rule" "cb_preflight_alt" {
  name           = "${local.cb_manager_name}-preflight-alt"
  description    = "Alternative trigger pattern for Blackwell jobs"
  event_bus_name = data.aws_cloudwatch_event_bus.runners.name

  event_pattern = jsonencode({
    detail = {
      "requestedLabels" = [
        { "equals-ignore-case" = "sm100" }
      ]
    }
  })

  tags = {
    Name        = "${local.cb_manager_name}-preflight-alt"
    Project     = "FlashInfer"
    Environment = local.environment
  }
}

# Target: CB Manager Lambda
resource "aws_cloudwatch_event_target" "cb_manager" {
  rule           = aws_cloudwatch_event_rule.cb_preflight.name
  event_bus_name = data.aws_cloudwatch_event_bus.runners.name
  target_id      = "cb-manager"
  arn            = aws_lambda_function.cb_manager.arn

  # Transform the event to CB Manager format
  input_transformer {
    input_paths = {
      labels = "$.detail.workflow_job.labels"
    }
    input_template = <<EOF
{
  "action": "ensure",
  "instance_type": "${local.cb_config.p6_blackwell.instance_type}",
  "source": "eventbridge",
  "labels": <labels>
}
EOF
  }
}

resource "aws_cloudwatch_event_target" "cb_manager_alt" {
  rule           = aws_cloudwatch_event_rule.cb_preflight_alt.name
  event_bus_name = data.aws_cloudwatch_event_bus.runners.name
  target_id      = "cb-manager-alt"
  arn            = aws_lambda_function.cb_manager.arn

  input = jsonencode({
    action        = "ensure"
    instance_type = local.cb_config.p6_blackwell.instance_type
    source        = "eventbridge-alt"
  })
}

# Permission for EventBridge to invoke CB Manager
resource "aws_lambda_permission" "eventbridge_cb_manager" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cb_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cb_preflight.arn
}

resource "aws_lambda_permission" "eventbridge_cb_manager_alt" {
  statement_id  = "AllowEventBridgeInvokeAlt"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cb_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cb_preflight_alt.arn
}

# =============================================================================
# Manual Invocation Examples
# =============================================================================
#
# Check CB status:
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "status", "instance_type": "p6-b200.48xlarge"}' \
#     response.json
#
# Ensure CB exists (purchase if needed):
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "ensure", "instance_type": "p6-b200.48xlarge"}' \
#     response.json
#
# Force purchase new CB:
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "purchase", "instance_type": "p6-b200.48xlarge"}' \
#     response.json
# =============================================================================

# =============================================================================
# Outputs
# =============================================================================

output "cb_manager_function_name" {
  description = "Name of the CB Manager Lambda function"
  value       = aws_lambda_function.cb_manager.function_name
}

output "cb_manager_function_arn" {
  description = "ARN of the CB Manager Lambda function"
  value       = aws_lambda_function.cb_manager.arn
}

output "cb_manager_invoke_example" {
  description = "Example command to invoke CB Manager"
  value       = <<-EOT
    # Check status:
    aws lambda invoke --function-name ${aws_lambda_function.cb_manager.function_name} \
      --payload '{"action": "status"}' response.json && cat response.json

    # Ensure CB exists:
    aws lambda invoke --function-name ${aws_lambda_function.cb_manager.function_name} \
      --payload '{"action": "ensure"}' response.json && cat response.json
  EOT
}
