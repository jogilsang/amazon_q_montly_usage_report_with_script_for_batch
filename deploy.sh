#!/bin/bash
set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# AWS 프로필 기본값
AWS_PROFILE="gsn-nx"

# 사용법 출력
usage() {
    echo "Usage: $0 [command] [--profile PROFILE_NAME]"
    echo ""
    echo "Commands:"
    echo "  all                  - 전체 배포 (Lambda + Role + EventBridge)"
    echo "  lambda               - Lambda 함수만 배포/업데이트"
    echo "  delete               - 모든 리소스 삭제"
    echo ""
    echo "Options:"
    echo "  --profile            - AWS CLI 프로필 이름 (기본값: default)"
    echo ""
    echo "Examples:"
    echo "  $0 all --profile my-profile"
    echo "  $0 lambda --profile my-profile"
    echo "  $0 delete --profile my-profile"
    echo ""
    exit 1
}

# 설정 파일 로드
load_config() {
    if [ ! -f "config.json" ]; then
        echo -e "${RED}❌ config.json 파일이 없습니다${NC}"
        echo "config.json.example을 참고하여 config.json을 생성하세요"
        exit 1
    fi
    
    echo -e "${GREEN}📋 Loading configuration...${NC}"
    echo -e "${GREEN}🔑 Using AWS Profile: $AWS_PROFILE${NC}"
    
    # jq로 config 파싱
    LAMBDA_NAME=$(jq -r '.lambda_name' config.json)
    LAMBDA_ROLE_NAME=$(jq -r '.lambda_role_name' config.json)
    LAMBDA_REGION=$(jq -r '.lambda_region' config.json)
    EVENTBRIDGE_REGION=$(jq -r '.eventbridge_region' config.json)
    IDENTITY_ACCOUNT_ID=$(jq -r '.identity_profile.account_id' config.json)
    IDENTITY_ACCOUNT_ROLE_NAME=$(jq -r '.identity_profile.account_role_name' config.json)
    IDENTITY_EXTERNAL_ID=$(jq -r '.identity_profile.external_id' config.json)
    S3_BUCKET=$(jq -r '.s3_bucket' config.json)
    S3_BUCKET_REGION=$(jq -r '.s3_bucket_region' config.json)
    IDENTITY_REGION=$(jq -r '.identity_region' config.json)
    OUTPUT_BUCKET=$(jq -r '.output_bucket' config.json)
    EVENTBRIDGE_RULE_NAME=$(jq -r '.eventbridge_rule_name' config.json)
    SCHEDULE=$(jq -r '.schedule' config.json)
    
    echo -e "${GREEN}✅ Configuration loaded${NC}"
    echo -e "${GREEN}📍 Lambda Region: $LAMBDA_REGION${NC}"
    echo -e "${GREEN}📍 EventBridge Region: $EVENTBRIDGE_REGION${NC}"
}

# Lambda 패키징
package_lambda() {
    echo -e "${YELLOW}📦 Packaging Lambda function...${NC}"
    
    # Lambda 코드만 패키징 (의존성은 Layer 사용)
    rm -f lambda_function.zip
    zip lambda_function.zip lambda_function.py
    
    echo -e "${GREEN}✅ Lambda package created: lambda_function.zip${NC}"
}

# Lambda Layer ARN 가져오기 (AWS Data Wrangler 공식 Layer 사용)
get_awswrangler_layer_arn() {
    # AWS Data Wrangler는 pandas를 포함하는 공식 Layer
    # https://aws-sdk-pandas.readthedocs.io/en/stable/layers.html
    
    case "$LAMBDA_REGION" in
        us-east-1)
            echo "arn:aws:lambda:us-east-1:336392948345:layer:AWSSDKPandas-Python311:22"
            ;;
        us-west-2)
            echo "arn:aws:lambda:us-west-2:336392948345:layer:AWSSDKPandas-Python311:22"
            ;;
        eu-west-1)
            echo "arn:aws:lambda:eu-west-1:336392948345:layer:AWSSDKPandas-Python311:22"
            ;;
        ap-northeast-1)
            echo "arn:aws:lambda:ap-northeast-1:336392948345:layer:AWSSDKPandas-Python311:22"
            ;;
        ap-northeast-2)
            echo "arn:aws:lambda:ap-northeast-2:336392948345:layer:AWSSDKPandas-Python311:22"
            ;;
        *)
            echo "arn:aws:lambda:$LAMBDA_REGION:336392948345:layer:AWSSDKPandas-Python311:22"
            ;;
    esac
}

# IAM Role 생성
create_role() {
    echo -e "${YELLOW}🔐 Creating IAM Role...${NC}"
    
    # Trust Policy
    cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    # Role 생성
    aws iam create-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json \
        --region "$LAMBDA_REGION" \
        --profile "$AWS_PROFILE" \
        2>/dev/null || echo "Role already exists"
    
    # Basic Lambda 실행 권한 추가
    aws iam attach-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
        --region "$LAMBDA_REGION" \
        --profile "$AWS_PROFILE"
    
    # AssumeRole 및 S3 권한 추가
    cat > assume-role-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${IDENTITY_ACCOUNT_ID}:role/${IDENTITY_ACCOUNT_ROLE_NAME}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::${OUTPUT_BUCKET}/*"
    }
  ]
}
EOF
    
    aws iam put-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-name AssumeRolePolicy \
        --policy-document file://assume-role-policy.json \
        --region "$LAMBDA_REGION" \
        --profile "$AWS_PROFILE"
    
    echo -e "${GREEN}✅ IAM Role created: $LAMBDA_ROLE_NAME${NC}"
    
    # Cleanup
    rm -f trust-policy.json assume-role-policy.json
}

# Lambda 함수 생성
create_lambda() {
    echo -e "${YELLOW}⚡ Creating Lambda function...${NC}"
    
    # Role ARN 가져오기
    ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" --query 'Role.Arn' --output text)
    
    # AWS Data Wrangler Layer ARN 가져오기
    LAYER_ARN=$(get_awswrangler_layer_arn)
    echo "Using AWS SDK Pandas Layer: $LAYER_ARN"
    
    # Lambda 생성
    aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime python3.11 \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file fileb://lambda_function.zip \
        --timeout 900 \
        --memory-size 512 \
        --layers "$LAYER_ARN" \
        --region "$LAMBDA_REGION" \
        --profile "$AWS_PROFILE" \
        --environment "Variables={
            IDENTITY_PROFILE_ACCOUNT_ID=$IDENTITY_ACCOUNT_ID,
            IDENTITY_ACCOUNT_ROLE_NAME=$IDENTITY_ACCOUNT_ROLE_NAME,
            IDENTITY_EXTERNAL_ID=$IDENTITY_EXTERNAL_ID,
            S3_BUCKET=$S3_BUCKET,
            S3_BUCKET_REGION=$S3_BUCKET_REGION,
            IDENTITY_REGION=$IDENTITY_REGION,
            OUTPUT_BUCKET=$OUTPUT_BUCKET
        }" \
        2>/dev/null || {
            echo -e "${YELLOW}Lambda already exists, updating...${NC}"
            update_lambda_code
        }
    
    echo -e "${GREEN}✅ Lambda function created: $LAMBDA_NAME${NC}"
}

# Lambda 코드 업데이트
update_lambda_code() {
    echo -e "${YELLOW}🔄 Updating Lambda code...${NC}"
    
    aws lambda update-function-code \
        --function-name "$LAMBDA_NAME" \
        --zip-file fileb://lambda_function.zip \
        --region "$LAMBDA_REGION" \
        --profile "$AWS_PROFILE"
    
    echo -e "${GREEN}✅ Lambda code updated${NC}"
}

# EventBridge Rule 생성
create_eventbridge() {
    echo -e "${YELLOW}⏰ Creating EventBridge Rule...${NC}"
    
    # Rule 생성
    aws events put-rule \
        --name "$EVENTBRIDGE_RULE_NAME" \
        --schedule-expression "$SCHEDULE" \
        --state ENABLED \
        --description "Amazon Q Monthly Usage Report - Runs on 1st day of month at 10:00 AM" \
        --region "$EVENTBRIDGE_REGION" \
        --profile "$AWS_PROFILE"
    
    # Lambda ARN 가져오기
    LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" --query 'Configuration.FunctionArn' --output text)
    
    # Target 추가
    aws events put-targets \
        --rule "$EVENTBRIDGE_RULE_NAME" \
        --targets "Id=1,Arn=$LAMBDA_ARN" \
        --region "$EVENTBRIDGE_REGION" \
        --profile "$AWS_PROFILE"
    
    # Lambda에 EventBridge 권한 추가
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$LAMBDA_REGION" --query Account --output text)
    
    aws lambda add-permission \
        --function-name "$LAMBDA_NAME" \
        --statement-id AllowEventBridgeInvoke \
        --action lambda:InvokeFunction \
        --principal events.amazonaws.com \
        --source-arn "arn:aws:events:$EVENTBRIDGE_REGION:$ACCOUNT_ID:rule/$EVENTBRIDGE_RULE_NAME" \
        --region "$LAMBDA_REGION" \
        --profile "$AWS_PROFILE" \
        2>/dev/null || echo "Permission already exists"
    
    echo -e "${GREEN}✅ EventBridge Rule created: $EVENTBRIDGE_RULE_NAME${NC}"
}

# Lambda만 배포/업데이트
deploy_lambda_only() {
    load_config
    package_lambda
    
    # Lambda 존재 여부 확인
    if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" &>/dev/null; then
        echo -e "${YELLOW}🔄 Lambda exists, updating code...${NC}"
        
        aws lambda update-function-code \
            --function-name "$LAMBDA_NAME" \
            --zip-file fileb://lambda_function.zip \
            --region "$LAMBDA_REGION" \
            --profile "$AWS_PROFILE"
        
        echo -e "${GREEN}✅ Lambda code updated${NC}"
    else
        echo -e "${YELLOW}⚡ Lambda not found, creating new function...${NC}"
        
        # Role 존재 확인
        if ! aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" &>/dev/null; then
            echo -e "${RED}❌ IAM Role not found. Run './deploy.sh all' first${NC}"
            exit 1
        fi
        
        create_lambda
    fi
    
    echo ""
    echo -e "${GREEN}🎉 Lambda 배포 완료!${NC}"
    echo ""
    echo "Lambda Function: $LAMBDA_NAME"
    echo "Region: $LAMBDA_REGION"
    echo ""
}
deploy_all() {
    load_config
    package_lambda
    create_role
    sleep 10  # Role 생성 대기
    create_lambda
    create_eventbridge
    
    echo ""
    echo -e "${GREEN}🎉 배포 완료!${NC}"
    echo ""
    echo "Lambda Function: $LAMBDA_NAME"
    echo "IAM Role: $LAMBDA_ROLE_NAME"
    echo "EventBridge Rule: $EVENTBRIDGE_RULE_NAME"
    echo "Schedule: $SCHEDULE"
    echo ""
}

# 리소스 삭제
delete_all() {
    load_config
    
    echo -e "${RED}⚠️  모든 리소스를 삭제합니다${NC}"
    read -p "계속하시겠습니까? (y/N): " confirm
    
    if [ "$confirm" != "y" ]; then
        echo "취소되었습니다"
        exit 0
    fi
    
    echo -e "${YELLOW}🗑️  Deleting resources...${NC}"
    
    # EventBridge Rule 삭제
    aws events remove-targets --rule "$EVENTBRIDGE_RULE_NAME" --ids 1 --region "$EVENTBRIDGE_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
    aws events delete-rule --name "$EVENTBRIDGE_RULE_NAME" --region "$EVENTBRIDGE_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
    
    # Lambda 삭제
    aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
    
    # IAM Role 삭제
    aws iam delete-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name AssumeRolePolicy --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
    aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" --region "$LAMBDA_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
    
    # 임시 파일 삭제
    rm -rf package lambda_function.zip layer layer.zip
    
    echo -e "${GREEN}✅ 모든 리소스가 삭제되었습니다${NC}"
}

# 메인 로직
COMMAND=""

# 파라미터 파싱
while [[ $# -gt 0 ]]; do
    case $1 in
        all|delete|lambda)
            COMMAND=$1
            shift
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# 명령어 실행
case "$COMMAND" in
    all)
        deploy_all
        ;;
    lambda)
        deploy_lambda_only
        ;;
    delete)
        delete_all
        ;;
    *)
        usage
        ;;
esac
