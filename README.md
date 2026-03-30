# Amazon Q Developer Monthly Usage Report Automation (Lambda + EventBridge)

An automated batch system that processes daily Amazon Q Developer usage data stored in S3 using Lambda, generating monthly reports on the 1st of each month at 10:00 AM.

> **💡 Who is this for?**  
> This solution is designed for **organizations using Amazon Q Developer with AWS Organizations**. It supports various account configurations:
> - **Single Account**: IAM Identity Center, Amazon Q, and S3 in the same account
> - **Multi-Account**: IAM Identity Center in Management Account (Payer), Amazon Q and S3 in member accounts

[한국어 문서](README_KR.md)

## 📋 Table of Contents

- [Architecture](#architecture)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation & Deployment](#installation--deployment)
- [Configuration](#configuration)
- [Usage](#usage)
- [Output Files](#output-files)
- [Troubleshooting](#troubleshooting)

## 🏗️ Architecture

![](./generated-diagrams/amazon_q_monthly_report_architecture.png)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AWS Account (Lambda Execution)                       │
│                                                                              │
│  ┌──────────────────┐                                                       │
│  │  EventBridge     │                                                       │
│  │  Schedule Rule   │                                                       │
│  │                  │                                                       │
│  │ cron(0 10 1 * ?) │  Trigger (Monthly 1st 10:00 AM)                      │
│  └────────┬─────────┘                                                       │
│           │                                                                  │
│           ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐          │
│  │           Lambda Function                                     │          │
│  │     amazon-q-monthly-report                                  │          │
│  │                                                               │          │
│  │  Environment Variables:                                      │          │
│  │  - IDENTITY_PROFILE_ACCOUNT_ID                              │          │
│  │  - IDENTITY_ACCOUNT_ROLE_NAME                               │          │
│  │  - S3_BUCKET, S3_BUCKET_REGION                              │          │
│  │  - IDENTITY_REGION, OUTPUT_BUCKET                           │          │
│  └───┬──────────────────────────┬──────────────────────────┬───┘          │
│      │                          │                          │               │
│      │ ① Download CSV           │ ② Get User Info         │ ③ Upload      │
│      │                          │   (AssumeRole)          │   Reports     │
└──────┼──────────────────────────┼──────────────────────────┼───────────────┘
       │                          │                          │
       │                          │                          │
       ▼                          ▼                          ▼
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│  AWS Account         │  │  AWS Account         │  │  AWS Account         │
│  (Data Source)       │  │  (Identity Center)   │  │  (Lambda)            │
│                      │  │                      │  │                      │
│  ┌────────────────┐ │  │  ┌────────────────┐ │  │  ┌────────────────┐ │
│  │  S3 Bucket     │ │  │  │ Identity Center│ │  │  │  S3 Bucket     │ │
│  │                │ │  │  │                │ │  │  │                │ │
│  │  Source CSV    │ │  │  │  User Info     │ │  │  │  Output        │ │
│  │  Files         │ │  │  │  - DisplayName │ │  │  │  Reports       │ │
│  │                │ │  │  │  - Email       │ │  │  │                │ │
│  │  Structure:    │ │  │  │  - UserId      │ │  │  │  Structure:    │ │
│  │  daily-report/ │ │  │  └────────────────┘ │  │  │  YYYYMM/       │ │
│  │    └─AWSLogs/  │ │  │                      │  │  │    ├─final_    │ │
│  │      └─{acct}/ │ │  │  IAM Role:           │  │  │    │  report_  │ │
│  │        └─Kiro/ │ │  │  IdentityCenter-     │  │  │    │  YYYYMM   │ │
│  │          QDev/ │ │  │  ReadOnly-Role       │  │  │    │  .csv     │ │
│  │          Logs/ │ │  │                      │  │  │    └─monthly_  │ │
│  │          └─by_ │ │  │  Permissions:        │  │  │       summary_ │ │
│  │            user│ │  │  - ListUsers         │  │  │       YYYYMM   │ │
│  │            _ana│ │  │  - ListInstances     │  │  │       .csv     │ │
│  │            lyt/│ │  │                      │  │  └────────────────┘ │
│                      │  │                      │  │                      │
└──────────────────────┘  └──────────────────────┘  │  Permissions:        │
                                                     │  - s3:PutObject      │
                                                     │                      │
                                                     └──────────────────────┘
```

**Processing Flow:**
1. EventBridge triggers Lambda on 1st of every month at 10:00 AM
2. Lambda calculates previous month (YYYY-MM)
3. Lambda downloads CSV files from Source S3 (same account, no AssumeRole needed)
4. Lambda assumes role in Identity Center account to fetch user information
5. Lambda merges CSV data with user information (DisplayName, Email)
6. Lambda generates two reports:
   - `final_report_YYYYMM.csv` (daily detailed data)
   - `monthly_summary_YYYYMM.csv` (monthly aggregated data)
7. Lambda uploads reports to Output S3 in YYYYMM/ folder
8. Process completes, logs written to CloudWatch

## 🎯 Features

1. **Automatic Scheduling**: EventBridge triggers Lambda automatically on the 1st of each month at 10:00 AM
2. **Cross-Account Access**: Access resources in different accounts via AssumeRole
3. **Automatic Date Calculation**: Automatically calculates the previous month based on execution time
4. **S3 Folder Structure**: Automatically creates monthly folders (e.g., `202501/`)
5. **CSV Merge & Enhancement**: Automatically maps Identity Store information
6. **Monthly Summary Report**: Automatically aggregates monthly usage per user

## 📦 Prerequisites

### Amazon Q Developer Setup

**Before using this solution, you must:**

1. **Enable User Activity Reports in Amazon Q Developer**
   - Navigate to Amazon Q Developer console
   - Enable "User Activity Reports" feature
   - Configure S3 bucket for report storage

2. **S3 Bucket Configuration**
   - The S3 bucket must have a `daily-report/` prefix configured
   - Amazon Q will automatically create the following structure:
     ```
     s3://your-bucket/
       └── daily-report/
           └── AWSLogs/
               └── {account-id}/
                   └── KiroLogs|QDeveloperLogs/
                       └── by_user_analytic/
                           └── {region}/
                               └── {year}/
                                   └── {month}/
                                       └── {day}/
                                           └── {hour}/
                                               └── {account-id}_by_user_analytic_{timestamp}_report.csv
     ```
   - **Important**: The solution expects the `daily-report/` prefix in the path

3. **IAM Identity Center**
   - Can be enabled in either Management Account (Payer) or Member Account - just specify the account information and region correctly in the config
   - Amazon Q logs users by user-id, which can only be retrieved via IAM Identity Center API

### Required Software
- AWS CLI configured
- Python 3.11 or higher
- jq (for JSON parsing)
- bash

### AWS Permissions

#### Lambda Execution Role
- `sts:AssumeRole` - Assume roles in other accounts
- `s3:PutObject` - Upload results to S3
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` - CloudWatch Logs

#### S3 Access Role (Target Account)
- `s3:GetObject`, `s3:ListBucket` - Download CSV files

#### Identity Store Access Role (Target Account)
- `identitystore:ListUsers`
- `sso-admin:ListInstances`

**Trust Policy Setup:**

The Identity Center account role must trust the Lambda execution role. This can be configured:
- **Before deployment**: Manually add trust relationship
- **After deployment**: Update trust policy with Lambda role ARN

**Example Trust Policy for `IdentityCenter-ReadOnly-Role`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::LAMBDA_ACCOUNT_ID:role/AmazonQMonthlyReportLambdaRole"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "your-external-id"
        }
      }
    }
  ]
}
```

Replace:
- `LAMBDA_ACCOUNT_ID`: AWS account ID where Lambda is deployed
- `your-external-id`: Optional external ID for additional security (must match `config.json`)

## 🔧 Installation & Deployment

### 1. Create Configuration File

```bash
cd /path/to/amazon_q_montly_usage_report_with_script_for_batch

# Copy config.json.example to config.json
cp config.json.example config.json

# Edit config.json
vi config.json
```

**config.json Example:**
```json
{
  "lambda_name": "amazon-q-monthly-report",
  "lambda_role_name": "AmazonQMonthlyReportLambdaRole",
  "lambda_region": "us-east-1",
  "eventbridge_region": "us-east-1",
  "identity_profile": {
    "account_id": "123456789012",
    "account_role_name": "IdentityCenter-ReadOnly-Role",
    "external_id": ""
  },
  "s3_bucket": "q-userreport-managementaccount-us",
  "s3_bucket_region": "us-east-1",
  "identity_region": "ap-northeast-2",
  "output_bucket": "your-output-bucket-name",
  "eventbridge_rule_name": "amazon-q-monthly-report-schedule",
  "schedule": "cron(0 10 1 * ? *)"
}
```

### 2. Full Deployment (Recommended)

```bash
./deploy.sh all
```

This command automatically performs:
1. Lambda packaging (including dependencies)
2. IAM Role creation (with AssumeRole permissions)
3. Lambda function creation
4. EventBridge Rule creation and connection

### 3. Individual Deployment

You can deploy specific resources:

```bash
# Deploy Lambda function only
./deploy.sh lambda

# Create IAM Role only
./deploy.sh role

# Create EventBridge Rule only
./deploy.sh eventbridge

# Update Lambda code only
./deploy.sh update-lambda
```

## ⚙️ Configuration

### config.json Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `lambda_name` | Lambda function name | `amazon-q-monthly-report` |
| `lambda_role_name` | Lambda execution role name | `AmazonQMonthlyReportLambdaRole` |
| `s3_profile.account_id` | S3 access target account ID | `123456789012` |
| `s3_profile.role_name` | Role name for S3 access | `IdentityCenter-ReadOnly-Role` |
| `identity_profile.account_id` | Identity Store account ID | `987654321012` |
| `identity_profile.role_name` | Role name for Identity Store access | `IdentityCenter-ReadOnly-Role` |
| `s3_bucket` | Source S3 bucket (Q daily usage report CSV location) | `q-userreport-managementaccount-us` |
| `s3_bucket_region` | Source S3 bucket region | `us-east-1` |
| `identity_region` | Identity Store region | `ap-northeast-2` |
| `output_bucket` | Output S3 bucket (where Q monthly usage reports are saved) | `my-reports-bucket` |
| `eventbridge_rule_name` | EventBridge Rule name | `amazon-q-monthly-report-schedule` |
| `schedule` | Execution schedule (cron) | `cron(0 10 1 * ? *)` |

### Schedule Configuration

EventBridge cron expression format: `cron(minute hour day month day-of-week year)`

**Examples:**
- `cron(0 10 1 * ? *)` - 1st of every month at 10:00 AM
- `cron(0 9 1 * ? *)` - 1st of every month at 9:00 AM
- `cron(0 14 1 * ? *)` - 1st of every month at 2:00 PM

## 🚀 Usage

### Automatic Execution

After deployment, EventBridge automatically triggers Lambda on the 1st of each month at 10:00 AM.

### Manual Execution (Testing)

```bash
# Invoke Lambda directly via AWS CLI
aws lambda invoke \
  --function-name amazon-q-monthly-report \
  --payload '{}' \
  response.json

# Check results
cat response.json
```

### View Logs

```bash
# Check CloudWatch Logs
aws logs tail /aws/lambda/amazon-q-monthly-report --follow
```

## 📊 Output Files

After Lambda execution, files are created in the Output S3 bucket with the following structure:

```
your-output-bucket/
└── 202501/                              # Year-month folder
    ├── final_report_202501.csv          # Daily detailed report
    └── monthly_summary_202501.csv       # Monthly summary report
```

### File Descriptions

#### 1. `final_report_YYYYMM.csv`
- **Content**: Daily detailed usage data
- **Columns**: DisplayName, UserName, Email, UserId, other metrics
- **Encoding**: UTF-8 BOM (Excel compatible)

#### 2. `monthly_summary_YYYYMM.csv`
- **Content**: Monthly aggregated data per user
- **Columns**: DisplayName, UserName, Email, UserId, aggregated metrics
- **Encoding**: UTF-8 BOM (Excel compatible)

## 🔍 Lambda Execution Flow

```
1. EventBridge Trigger (1st of month at 10:00)
   ↓
2. Calculate Previous Month (e.g., 2025-01)
   ↓
3. Assume S3 Role
   ↓
4. Download and Merge CSV Files
   ↓
5. Assume Identity Store Role
   ↓
6. Query User Information
   ↓
7. Enhance CSV (Add DisplayName, Email)
   ↓
8. Generate Monthly Summary Report
   ↓
9. Upload to Output S3
   ↓
10. Complete (Log to CloudWatch)
```

## 🐛 Troubleshooting

### 1. `config.json file not found`

**Cause**: Configuration file not created

**Solution**:
```bash
cp config.json.example config.json
vi config.json  # Edit configuration
```

### 2. `AccessDenied` Error

**Cause**: Insufficient AssumeRole permissions

**Solution**:
1. Check Target Account Role Trust Policy
2. Verify Lambda Role has `sts:AssumeRole` permission

**Target Account Role Trust Policy Example:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::LAMBDA_ACCOUNT_ID:role/AmazonQMonthlyReportLambdaRole"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### 3. Lambda Timeout

**Cause**: Processing time exceeded (default 15 minutes)

**Solution**:
```bash
# Increase timeout (max 15 minutes)
aws lambda update-function-configuration \
  --function-name amazon-q-monthly-report \
  --timeout 900
```

### 4. `No data found for YYYYMM`

**Cause**: No CSV files for the specified year-month

**Solution**:
- Verify S3 bucket path
- Check year-month folder structure: `daily-report/.../YYYY/MM/`

### 5. EventBridge Rule Not Triggering

**Cause**: Missing Lambda permission

**Solution**:
```bash
# Add EventBridge permission to Lambda
aws lambda add-permission \
  --function-name amazon-q-monthly-report \
  --statement-id AllowEventBridgeInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:REGION:ACCOUNT_ID:rule/amazon-q-monthly-report-schedule"
```

## 🗑️ Resource Cleanup

To delete all resources:

```bash
./deploy.sh delete
```

This command deletes:
- EventBridge Rule
- Lambda Function
- IAM Role and Policies
- Temporary files (package/, lambda_function.zip)

**Note**: Files in the Output S3 bucket are not deleted.

## 📝 Additional Information

### Lambda Environment Variables

The Lambda function uses the following environment variables:

| Environment Variable | Description |
|---------------------|-------------|
| `S3_PROFILE_ACCOUNT_ID` | S3 access account ID |
| `S3_PROFILE_ROLE_NAME` | S3 access role name |
| `IDENTITY_PROFILE_ACCOUNT_ID` | Identity Store account ID |
| `IDENTITY_PROFILE_ROLE_NAME` | Identity Store role name |
| `S3_BUCKET` | Source S3 bucket |
| `S3_BUCKET_REGION` | Source S3 region |
| `IDENTITY_REGION` | Identity Store region |
| `OUTPUT_BUCKET` | Output bucket for results |

### Cost Considerations

- **Lambda**: Charged based on execution time (runs once per month)
- **EventBridge**: Free rule creation, charged per execution
- **S3**: Charged based on storage and request count
- **CloudWatch Logs**: Charged based on log storage

**Estimated Cost**: Less than $1/month (for small-scale usage)

## 🤝 Support

If you encounter issues or have suggestions for improvements, please create an issue.

---

**Version**: v1.0  
**Last Updated**: 2026-03-20
