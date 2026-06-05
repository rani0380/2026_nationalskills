# 2026 Cloud Computing Small Challenge - Required Files

Upload the files in this folder to AWS CloudShell or use each module folder directly.

## Common

Set your assigned number before running scripts that need a unique S3 bucket name.

```bash
export TEAM_ID=<your-number>
```

The grading scripts use the same number:

```bash
bash grade_all.sh <your-number>
```

## Module1 NoSQL

Region: `ap-northeast-2`

```bash
cd module1_nosql
bash create_nosql.sh
bash insert.sh
bash query.sh electronics
cat ~/result.json
```

Created resources:

- DynamoDB table: `nosql-products`
- GSI: `category-price-index`
- Stream view type: `NEW_AND_OLD_IMAGES`
- Tag: `Module=NoSQL`

## Module2 CDN

Region: `us-east-1`

Required static files:

- `index.html`
- `style.css`
- `image.png`

Optional one-shot setup:

```bash
cd module2_cdn
export TEAM_ID=<your-number>
bash setup_cdn.sh
```

Created resources:

- S3 bucket: `cdn-static-<your-number>`
- CloudFront distribution comment: `cdn-<your-number>`
- CloudFront Function: `cdn-add-security-header`
- OAC: `cdn-oac`

Manual function file:

- `cdn-add-security-header.js`

Verify:

```bash
curl -sI "https://<CloudFront-domain>/index.html?v=1" | grep -i X-Custom-Header
```

Expected header:

```text
x-custom-header: wsc2026
```

## Module3 Workflow

Region: `ap-southeast-1`

Required files:

- `data.csv`
- `lambda_function.py`
- `lambda_function.zip`

Optional one-shot setup:

```bash
cd module3_workflow
export TEAM_ID=<your-number>
bash setup_workflow.sh
```

Created resources:

- S3 bucket: `workflow-input-<your-number>`
- DynamoDB table: `workflow-output`
- Lambda: `workflow-transform`
- Step Functions state machine: `workflow-state-machine`

## Module4 RDS Connection

Region: `ap-northeast-3`

Required files:

- `lambda_function.py`
- `lambda_function.zip`

Optional one-shot setup:

```bash
cd module4_rds
bash setup_rds.sh
```

Created resources:

- Aurora cluster: `rds-aurora-cluster`
- Engine: `Aurora MySQL Compatible 3.x`
- Aurora instance: `rds-aurora-cluster-instance-1`
- Secret: `rds/aurora/admin`
- Lambda: `rds-query-function`

Verify:

```bash
aws lambda invoke --function-name rds-query-function --region ap-northeast-3 response.json
cat response.json
```
