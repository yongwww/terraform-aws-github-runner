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
  # Note: Instance type selection is now dynamic based on job labels.
  # The Lambda maps labels -> instance types (see LABEL_TO_INSTANCE_TYPE in index.py)
  cb_config = {
    # Default settings (used when no specific instance type is determined)
    default_duration_hours = 24 # Minimum 1 day for CBs
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
      # INSTANCE_TYPE is now determined dynamically from job labels
      # See LABEL_TO_INSTANCE_TYPE mapping in index.py
      DURATION_HOURS = tostring(local.cb_config.default_duration_hours)
      SSM_PREFIX     = "/flashinfer/capacity-blocks"
      SUBNET_IDS     = join(",", module.base.vpc.private_subnets)
      LOG_LEVEL      = "INFO"
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

  # READ-ONLY policy - CB purchase is DISABLED
  # CBs must be purchased manually via AWS Console
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
      # EC2 Capacity Block read-only operations
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeCapacityReservations"
          # REMOVED: ec2:DescribeCapacityBlockOfferings (purchase disabled)
          # REMOVED: ec2:PurchaseCapacityBlock (purchase disabled)
        ]
        Resource = "*"
      }
      # REMOVED: ec2:DescribeSubnets (not needed for read-only)
      # REMOVED: ec2:CreateTags (purchase disabled)
      # REMOVED: SSM permissions (purchase/locking disabled)
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
# DISABLED: Automatic CB purchase is disabled to prevent accidental duplicate
# purchases. CBs must be purchased manually via AWS Console or CLI.
#
# To re-enable, set is_enabled = true below or remove the state = "DISABLED"

# Get the EventBridge bus created by the runner module
data "aws_cloudwatch_event_bus" "runners" {
  name = "${local.environment}-runners" # Created by module.runners.webhook.eventbridge
}

# Rule: Trigger CB Manager for Capacity Block job requests (Blackwell or Hopper)
# DISABLED - automatic CB purchase is too risky
resource "aws_cloudwatch_event_rule" "cb_preflight" {
  name           = "${local.cb_manager_name}-preflight"
  description    = "Trigger CB Manager when Blackwell/Hopper job is requested (DISABLED)"
  event_bus_name = data.aws_cloudwatch_event_bus.runners.name
  state          = "DISABLED" # DISABLED to prevent automatic CB purchases

  # Match workflow_job events with any CB-requiring labels
  # Labels: b200, sm100, blackwell (Blackwell) or h100, sm90, hopper (Hopper)
  event_pattern = jsonencode({
    detail-type = ["workflow_job"]
    detail = {
      workflow_job = {
        labels = [
          # Blackwell labels
          { "equals-ignore-case" = "b200" },
          { "equals-ignore-case" = "sm100" },
          { "equals-ignore-case" = "blackwell" },
          # Hopper labels
          { "equals-ignore-case" = "h100" },
          { "equals-ignore-case" = "sm90" },
          { "equals-ignore-case" = "hopper" },
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
# DISABLED - automatic CB purchase is too risky
resource "aws_cloudwatch_event_rule" "cb_preflight_alt" {
  name           = "${local.cb_manager_name}-preflight-alt"
  description    = "Alternative trigger pattern for CB jobs (DISABLED)"
  event_bus_name = data.aws_cloudwatch_event_bus.runners.name
  state          = "DISABLED" # DISABLED to prevent automatic CB purchases

  event_pattern = jsonencode({
    detail = {
      "requestedLabels" = [
        # Blackwell labels
        { "equals-ignore-case" = "b200" },
        { "equals-ignore-case" = "sm100" },
        { "equals-ignore-case" = "blackwell" },
        # Hopper labels
        { "equals-ignore-case" = "h100" },
        { "equals-ignore-case" = "sm90" },
        { "equals-ignore-case" = "hopper" },
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
  # Lambda determines instance_type from labels (no hardcoding here)
  input_transformer {
    input_paths = {
      labels = "$.detail.workflow_job.labels"
    }
    input_template = <<EOF
{
  "action": "ensure",
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

  # Pass requestedLabels for the alt pattern
  input_transformer {
    input_paths = {
      labels = "$.detail.requestedLabels"
    }
    input_template = <<EOF
{
  "action": "ensure",
  "source": "eventbridge-alt",
  "labels": <labels>
}
EOF
  }
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
# Check CB status (using labels - Lambda determines instance type):
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "status", "labels": ["b200"]}' \
#     response.json
#
# Check CB status (explicit instance type):
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "status", "instance_type": "p5.48xlarge"}' \
#     response.json
#
# Ensure CB exists for Blackwell (purchase if needed):
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "ensure", "labels": ["b200"]}' \
#     response.json
#
# Ensure CB exists for Hopper (purchase if needed):
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "ensure", "labels": ["h100"]}' \
#     response.json
#
# Force purchase new CB (explicit instance type):
#   aws lambda invoke --function-name flashinfer-cb-manager \
#     --payload '{"action": "purchase", "instance_type": "p6-b200.48xlarge"}' \
#     response.json
#
# Supported labels -> instance types:
#   b200, sm100, blackwell -> p6-b200.48xlarge
#   h100, sm90, hopper     -> p5.48xlarge
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
