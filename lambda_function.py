#!/usr/bin/env python3
"""
Amazon Q Developer 월별 사용량 리포트 Lambda 함수
EventBridge로 매월 1일 오전 10시 실행
"""

import boto3
import pandas as pd
import os
import json
from datetime import datetime, timedelta
from io import StringIO, BytesIO

def lambda_handler(event, context):
    """
    Lambda 핸들러
    환경변수:
    - IDENTITY_PROFILE_ACCOUNT_ID: Identity Store 접근용 계정 ID
    - IDENTITY_ACCOUNT_ROLE_NAME: Identity Store 접근용 Role 이름
    - IDENTITY_EXTERNAL_ID: Identity Store Role의 External ID (선택)
    - S3_BUCKET: S3 버킷 이름
    - S3_BUCKET_REGION: S3 버킷 리전
    - IDENTITY_REGION: Identity Store 리전
    - OUTPUT_BUCKET: 결과 저장 S3 버킷
    """
    
    # 환경변수 읽기
    identity_account_id = os.environ['IDENTITY_PROFILE_ACCOUNT_ID']
    identity_account_role_name = os.environ['IDENTITY_ACCOUNT_ROLE_NAME']
    identity_external_id = os.environ.get('IDENTITY_EXTERNAL_ID', '')
    bucket = os.environ['S3_BUCKET']
    bucket_region = os.environ['S3_BUCKET_REGION']
    identity_region = os.environ['IDENTITY_REGION']
    output_bucket = os.environ['OUTPUT_BUCKET']
    
    # 이전 달 계산
    last_month = datetime.now().replace(day=1) - timedelta(days=1)
    year_month = last_month.strftime('%Y%m')
    year = year_month[:4]
    month = year_month[4:6]
    
    print(f"📅 Processing report for {year}-{month}")
    
    try:
        # 1. S3에서 CSV 다운로드 및 병합 (Lambda Role 직접 사용)
        print(f"📥 Downloading CSVs from s3://{bucket}/daily-report/ ({year}/{month})...")
        merged_df = download_and_merge_csvs(bucket, bucket_region, year, month)
        
        if merged_df.empty:
            print(f"❌ No data found for {year_month}")
            return {
                'statusCode': 404,
                'body': json.dumps({'message': f'No data found for {year_month}'})
            }
        
        # 2. Identity Store Role Assume
        identity_role_arn = f"arn:aws:iam::{identity_account_id}:role/{identity_account_role_name}"
        identity_session = assume_role(identity_role_arn, 'IdentityAccessSession', identity_external_id)
        
        # 3. Identity Store 매핑
        print(f"👥 Fetching Identity Store users...")
        user_mapping = get_identity_store_mapping(identity_session, identity_region)
        
        # 4. CSV 보강
        print(f"🔄 Enriching CSV with Identity Store data...")
        enriched_df = enrich_dataframe(merged_df, user_mapping)
        
        # 5. 월별 합산 리포트
        print(f"📊 Creating monthly summary...")
        summary_df = create_monthly_summary(enriched_df)
        
        # 6. S3에 업로드
        print(f"📤 Uploading results to S3...")
        upload_results(output_bucket, year_month, enriched_df, summary_df)
        
        print(f"✅ Complete!")
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Report generated successfully',
                'year_month': year_month,
                'output_location': f"s3://{output_bucket}/{year_month}/",
                'total_rows': len(enriched_df),
                'total_users': len(summary_df)
            })
        }
        
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def assume_role(role_arn, session_name, external_id=''):
    """IAM Role Assume (External ID 지원)"""
    sts = boto3.client('sts')
    
    assume_role_params = {
        'RoleArn': role_arn,
        'RoleSessionName': session_name
    }
    
    # External ID가 있으면 추가
    if external_id and external_id != 'null' and external_id.strip():
        assume_role_params['ExternalId'] = external_id
    
    response = sts.assume_role(**assume_role_params)
    
    credentials = response['Credentials']
    return boto3.Session(
        aws_access_key_id=credentials['AccessKeyId'],
        aws_secret_access_key=credentials['SecretAccessKey'],
        aws_session_token=credentials['SessionToken']
    )

def download_and_merge_csvs(bucket, region, year, month):
    """S3에서 CSV 다운로드 및 병합 (Lambda Role 직접 사용)"""
    s3 = boto3.client('s3', region_name=region)
    
    paginator = s3.get_paginator('list_objects_v2')
    pages = paginator.paginate(Bucket=bucket, Prefix='daily-report/')
    
    dfs = []
    for page in pages:
        if 'Contents' not in page:
            continue
        for obj in page['Contents']:
            key = obj['Key']
            if key.endswith('.csv') and f'/{year}/{month}/' in key:
                print(f"  ✅ {key}")
                response = s3.get_object(Bucket=bucket, Key=key)
                df = pd.read_csv(BytesIO(response['Body'].read()))
                dfs.append(df)
    
    if not dfs:
        return pd.DataFrame()
    
    merged_df = pd.concat(dfs, ignore_index=True)
    print(f"📊 Merged {len(dfs)} CSV files, total {len(merged_df)} rows")
    return merged_df

def get_identity_store_mapping(session, region):
    """Identity Store 사용자 매핑"""
    identity_store = session.client('identitystore', region_name=region)
    sso_admin = session.client('sso-admin', region_name=region)
    
    instances = sso_admin.list_instances()['Instances']
    if not instances:
        raise Exception("No Identity Store instance found")
    
    identity_store_id = instances[0]['IdentityStoreId']
    print(f"  Identity Store ID: {identity_store_id}")
    
    user_mapping = {}
    paginator = identity_store.get_paginator('list_users')
    
    for page in paginator.paginate(IdentityStoreId=identity_store_id):
        for user in page['Users']:
            user_id = user['UserId']
            display_name = user.get('DisplayName', '')
            user_name = user.get('UserName', '')
            
            email = ''
            if 'Emails' in user and len(user['Emails']) > 0:
                primary_emails = [e['Value'] for e in user['Emails'] if e.get('Primary', False)]
                if primary_emails:
                    email = primary_emails[0]
                else:
                    email = user['Emails'][0]['Value']
            
            user_mapping[user_id] = {
                'DisplayName': display_name,
                'UserName': user_name,
                'Email': email
            }
    
    print(f"✅ Found {len(user_mapping)} users")
    return user_mapping

def enrich_dataframe(df, user_mapping):
    """DataFrame에 Identity Store 정보 추가"""
    if 'UserId' not in df.columns:
        print("⚠️  Warning: 'UserId' column not found")
        return df
    
    df['DisplayName'] = df['UserId'].map(lambda x: user_mapping.get(x, {}).get('DisplayName', ''))
    df['UserName'] = df['UserId'].map(lambda x: user_mapping.get(x, {}).get('UserName', ''))
    df['Email'] = df['UserId'].map(lambda x: user_mapping.get(x, {}).get('Email', ''))
    
    cols = df.columns.tolist()
    if 'DisplayName' in cols and 'UserName' in cols and 'Email' in cols:
        cols.remove('DisplayName')
        cols.remove('UserName')
        cols.remove('Email')
        cols = ['DisplayName', 'UserName', 'Email'] + cols
        df = df[cols]
    
    return df

def create_monthly_summary(df):
    """사용자별 월별 합산"""
    if 'UserId' not in df.columns:
        return pd.DataFrame()
    
    numeric_cols = df.select_dtypes(include=['number']).columns.tolist()
    
    group_cols = ['UserId']
    if 'DisplayName' in df.columns:
        group_cols.append('DisplayName')
    if 'UserName' in df.columns:
        group_cols.append('UserName')
    if 'Email' in df.columns:
        group_cols.append('Email')
    
    summary_df = df.groupby(group_cols, as_index=False)[numeric_cols].sum()
    
    sort_col = 'DisplayName' if 'DisplayName' in summary_df.columns else 'UserId'
    summary_df = summary_df.sort_values(sort_col)
    
    return summary_df

def upload_results(bucket, year_month, daily_df, summary_df):
    """결과를 S3에 업로드"""
    s3 = boto3.client('s3')
    
    # 일별 리포트
    daily_csv = daily_df.to_csv(index=False, encoding='utf-8-sig')
    s3.put_object(
        Bucket=bucket,
        Key=f"{year_month}/final_report_{year_month}.csv",
        Body=daily_csv.encode('utf-8-sig'),
        ContentType='text/csv'
    )
    print(f"  ✅ Uploaded: {year_month}/final_report_{year_month}.csv")
    
    # 월별 합산 리포트
    summary_csv = summary_df.to_csv(index=False, encoding='utf-8-sig')
    s3.put_object(
        Bucket=bucket,
        Key=f"{year_month}/monthly_summary_{year_month}.csv",
        Body=summary_csv.encode('utf-8-sig'),
        ContentType='text/csv'
    )
    print(f"  ✅ Uploaded: {year_month}/monthly_summary_{year_month}.csv")
