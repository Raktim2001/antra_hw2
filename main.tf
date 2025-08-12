terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
  }
}

provider "aws" {
  region = var.region
}

############################
# Variables
############################
variable "project"      { type = string  default = "iot-pipeline" }
variable "region"       { type = string  default = "us-east-1" }
variable "bucket_name"  { type = string  default = null } # if null we’ll build one
variable "xgboost_image_uri" {
  type        = string
  description = "SageMaker XGBoost training image URI for your region (see README for the exact URI)."
  default     = "" # e.g. 683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.5-1
}
variable "sm_endpoint_instance_type" {
  type    = string
  default = "ml.t2.medium" # smallest common hosting instance
}

locals {
  bucket = coalesce(var.bucket_name, "${var.project}-${var.region}-${random_id.rand.hex}")
  scripts_prefix = "scripts"
  raw_prefix     = "raw/"
  clean_prefix   = "clean/"
  agg_prefix     = "aggregated/"
  model_prefix   = "model-artifacts/"
  endpoint_name  = "${var.project}-endpoint"
}

resource "random_id" "rand" {
  byte_length = 3
}

############################
# S3 for data + scripts
############################
resource "aws_s3_bucket" "data" {
  bucket        = local.bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "v" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration { status = "Disabled" }
}

# Glue scripts uploaded to S3
resource "aws_s3_object" "job1_script" {
  bucket       = aws_s3_bucket.data.id
  key          = "${local.scripts_prefix}/job1_clean.py"
  content_type = "text/x-python"
  content      = file("${path.module}/glue/job1_clean.py")
}

resource "aws_s3_object" "job2_script" {
  bucket       = aws_s3_bucket.data.id
  key          = "${local.scripts_prefix}/job2_aggregate.py"
  content_type = "text/x-python"
  content      = file("${path.module}/glue/job2_aggregate.py")
}

############################
# IAM for Glue
############################
data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect = "Allow"
    principals { type = "Service" identifiers = ["glue.amazonaws.com"] }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "glue_role" {
  name               = "${var.project}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

# Minimal S3 + Glue permissions for the bucket
data "aws_iam_policy_document" "glue_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.data.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject","s3:PutObject","s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.data.arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "glue:GetJob","glue:GetJobRun","glue:GetJobRuns","glue:StartJobRun"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_bucket" {
  name   = "${var.project}-glue-s3-policy"
  policy = data.aws_iam_policy_document.glue_policy.json
}

resource "aws_iam_role_policy_attachment" "glue_managed" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}
resource "aws_iam_role_policy_attachment" "glue_bucket_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.glue_bucket.arn
}

############################
# Glue Jobs
############################
resource "aws_glue_job" "job1" {
  name              = "${var.project}-job1-clean"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X" # smallest per requirement

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data.id}/${aws_s3_object.job1_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"  = "python"
    "--enable-metrics"= "true"
    "--raw_path"      = "s3://${aws_s3_bucket.data.id}/${local.raw_prefix}"
    "--clean_path"    = "s3://${aws_s3_bucket.data.id}/${local.clean_prefix}"
  }
}

resource "aws_glue_job" "job2" {
  name              = "${var.project}-job2-aggregate"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data.id}/${aws_s3_object.job2_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"   = "python"
    "--enable-metrics" = "true"
    "--clean_path"     = "s3://${aws_s3_bucket.data.id}/${local.clean_prefix}"
    "--agg_path"       = "s3://${aws_s3_bucket.data.id}/${local.agg_prefix}"
  }
}

# Trigger: run job2 after job1 SUCCESS
resource "aws_glue_trigger" "after_job1" {
  name     = "${var.project}-after-job1"
  type     = "CONDITIONAL"
  actions  { job_name = aws_glue_job.job2.name }
  predicate {
    conditions {
      job_name = aws_glue_job.job1.name
      state    = "SUCCEEDED"
    }
  }
  enabled = true
}

################################
# SageMaker via Step Functions
################################
# EventBridge rule: fire when aggregated data is created
resource "aws_cloudwatch_event_rule" "s3_agg_rule" {
  name        = "${var.project}-agg-created"
  description = "Trigger SFN when new aggregated objects land in S3"
  event_pattern = jsonencode({
    "source": ["aws.s3"],
    "detail-type": ["Object Created"],
    "detail": {
      "bucket": { "name": [aws_s3_bucket.data.bucket] },
      "object": { "key": [{ "prefix": local.agg_prefix }] }
    }
  })
}

# IAM for Step Functions to call SageMaker & read/write S3
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect = "Allow"
    principals { type = "Service" identifiers = ["states.${var.region}.amazonaws.com"] }
    actions = ["sts:AssumeRole"]
  }
}
resource "aws_iam_role" "sfn_role" {
  name               = "${var.project}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "sfn_policy" {
  statement {
    effect = "Allow"
    actions = [
      "sagemaker:CreateTrainingJob",
      "sagemaker:CreateModel",
      "sagemaker:CreateEndpointConfig",
      "sagemaker:CreateEndpoint",
      "sagemaker:DescribeEndpoint",
      "sagemaker:UpdateEndpoint",
      "sagemaker:DescribeTrainingJob",
      "iam:PassRole"
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = ["s3:GetObject","s3:PutObject","s3:ListBucket"]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*"
    ]
  }
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "sfn_inline" {
  name   = "${var.project}-sfn-policy"
  policy = data.aws_iam_policy_document.sfn_policy.json
}
resource "aws_iam_role_policy_attachment" "sfn_attach" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = aws_iam_policy.sfn_inline.arn
}

# SageMaker execution role for training & hosting
data "aws_iam_policy_document" "sm_assume" {
  statement {
    effect = "Allow"
    principals { type = "Service" identifiers = ["sagemaker.amazonaws.com"] }
    actions = ["sts:AssumeRole"]
  }
}
resource "aws_iam_role" "sm_role" {
  name               = "${var.project}-sagemaker-exec"
  assume_role_policy = data.aws_iam_policy_document.sm_assume.json
}
data "aws_iam_policy_document" "sm_policy" {
  statement {
    effect   = "Allow"
    actions  = ["s3:GetObject","s3:PutObject","s3:ListBucket"]
    resources = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents",
      "ecr:GetAuthorizationToken","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"
    ]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "sm_inline" {
  name   = "${var.project}-sagemaker-s3-logs"
  policy = data.aws_iam_policy_document.sm_policy.json
}
resource "aws_iam_role_policy_attachment" "sm_attach" {
  role       = aws_iam_role.sm_role.name
  policy_arn = aws_iam_policy.sm_inline.arn
}

# Step Functions definition: Train XGBoost -> CreateModel -> CreateEndpointConfig -> CreateEndpoint
locals {
  training_output_path = "s3://${aws_s3_bucket.data.id}/${local.model_prefix}"
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.project}-ml-pipeline"
  role_arn = aws_iam_role.sfn_role.arn

  definition = jsonencode({
    Comment = "Train and deploy model on new aggregated data"
    StartAt = "TrainJob"
    States = {
      TrainJob = {
        Type = "Task"
        Resource = "arn:aws:states:::sagemaker:createTrainingJob.sync"
        Parameters = {
          TrainingJobName = "${var.project}-xgb-#{States.Timestamp()}"
          AlgorithmSpecification = {
            TrainingImage = var.xgboost_image_uri
            TrainingInputMode = "File"
          }
          RoleArn = aws_iam_role.sm_role.arn
          OutputDataConfig = { S3OutputPath = local.training_output_path }
          ResourceConfig = {
            InstanceType = "ml.m5.large"
            InstanceCount = 1
            VolumeSizeInGB = 10
          }
          StoppingCondition = { MaxRuntimeInSeconds = 600 }
          HyperParameters = {
            "objective" = "reg:squarederror"
            "num_round" = "10"
          }
          InputDataConfig = [
            {
              ChannelName = "train"
              DataSource = {
                S3DataSource = {
                  S3DataType = "S3Prefix"
                  S3Uri      = "s3://${aws_s3_bucket.data.id}/${local.agg_prefix}"
                  S3DataDistributionType = "FullyReplicated"
                }
              }
              ContentType = "text/csv"
              CompressionType = "None"
              RecordWrapperType = "None"
            }
          ]
        }
        Next = "CreateModel"
      },
      CreateModel = {
        Type = "Task"
        Resource = "arn:aws:states:::sagemaker:createModel"
        Parameters = {
          ExecutionRoleArn = aws_iam_role.sm_role.arn
          ModelName = "${var.project}-model-#{States.Timestamp()}"
          PrimaryContainer = {
            Image      = var.xgboost_image_uri
            Mode       = "SingleModel"
            ModelDataUrl = "#{$.TrainingJob.ModelArtifacts.S3ModelArtifacts}"
          }
        }
        ResultPath = "$.Model"
        Next = "CreateEndpointConfig"
      },
      CreateEndpointConfig = {
        Type = "Task"
        Resource = "arn:aws:states:::sagemaker:createEndpointConfig"
        Parameters = {
          EndpointConfigName = "${var.project}-cfg-#{States.Timestamp()}"
          ProductionVariants = [
            {
              InitialInstanceCount = 1
              InstanceType         = var.sm_endpoint_instance_type
              ModelName            = "#{$.Model.ModelName}"
              VariantName          = "AllTraffic"
              InitialVariantWeight = 1.0
            }
          ]
        }
        ResultPath = "$.EndpointConfig"
        Next = "CreateEndpoint"
      },
      CreateEndpoint = {
        Type = "Task"
        Resource = "arn:aws:states:::sagemaker:createEndpoint"
        Parameters = {
          EndpointName       = local.endpoint_name
          EndpointConfigName = "#{$.EndpointConfig.EndpointConfigName}"
        }
        End = true
      }
    }
  })
}

# EventBridge permission + target to start the state machine
resource "aws_iam_role" "events_invoke_sfn" {
  name = "${var.project}-events-invoke-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "events.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events_invoke_sfn_policy" {
  name = "${var.project}-events-invoke-sfn-policy"
  role = aws_iam_role.events_invoke_sfn.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = ["states:StartExecution"],
      Resource = aws_sfn_state_machine.pipeline.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "s3_to_sfn" {
  rule      = aws_cloudwatch_event_rule.s3_agg_rule.name
  target_id = "StartMLPipeline"
  arn       = aws_sfn_state_machine.pipeline.arn
  role_arn  = aws_iam_role.events_invoke_sfn.arn
}

############################
# Outputs
############################
output "s3_bucket"             { value = aws_s3_bucket.data.bucket }
output "raw_prefix"            { value = local.raw_prefix }
output "clean_prefix"          { value = local.clean_prefix }
output "aggregated_prefix"     { value = local.agg_prefix }
output "endpoint_name"         { value = local.endpoint_name }
