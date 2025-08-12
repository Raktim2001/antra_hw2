# IoT Mini Pipeline (Terraform + Glue + SageMaker)

**What this does**

- Creates a single S3 bucket for data and scripts.
- Two AWS Glue jobs:
  1. **job1_clean** – parses/cleans raw CSV → writes Parquet to `clean/`
  2. **job2_aggregate** – 5‑minute windowed averages → writes CSV/Parquet to `aggregated/`
- A **Glue Trigger** runs _job2_ automatically after _job1_ succeeds.
- An **EventBridge rule** fires when new data lands in `aggregated/`, starting a **Step Functions** state machine that:
  - runs a **SageMaker training job** (XGBoost),
  - creates a **SageMaker Model**, **EndpointConfig**, and a live **Endpoint** (on `ml.t2.medium`).

> Smallest sizes used per requirements: Glue `G.1X` with **2 workers**; SageMaker endpoint on **ml.t2.medium**. Training runs on `ml.m5.large` (small, widely available for XGBoost). You can change via Terraform variables.

---

## 0) Prereqs

- Terraform ≥ 1.6
- AWS CLI configured (`aws configure`) with permissions for S3, Glue, Step Functions, SageMaker, IAM, EventBridge.
- Python/PySpark not required locally; Glue runs them in AWS.

---

## 1) Clone & set variables
# in the folder with main.tf and glue/ scripts
terraform init

Pick the correct XGBoost image URI for your region and pass it in. (AWS keeps region‑specific URIs.)

Find your region’s URI under AWS Docs → SageMaker → Docker Registry Paths → XGBoost. Example (us‑east‑1):

683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.5-1
Apply:

terraform apply \
  -var="region=us-east-1" \
  -var="xgboost_image_uri=683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.5-1"
