#!/usr/bin/env bash
# One-time AWS bootstrap for fireballenterprise.com hosting (S3 + CloudFront + IAM OIDC).
# Run locally with `aws configure` already set up, or paste straight into AWS CloudShell
# (aws CLI is preinstalled there — nothing else to install).
#
# Idempotent — safe to re-run if it's interrupted partway through (e.g. while waiting on
# DNS validation); already-created resources are detected and skipped.
#
# See ../../fireball_orchestrator/topics/fireball_enterprise/docs/setup_aws.md for the
# step-by-step this script automates.

set -euo pipefail

# --- Config -----------------------------------------------------------------
BUCKET_NAME="fireballenterprise.com"
REGION="us-east-1" # required for CloudFront-compatible ACM certs
ROLE_NAME="fireball-enterprise-landing-deploy"
REPO_SLUG="fireballenterprise/fireball_enterprise_landing"
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
# ------------------------------------------------------------------------------

echo "==> AWS identity"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Account: $ACCOUNT_ID"
echo "Caller:  $CALLER_ARN"
read -rp "Proceed with setup for account $ACCOUNT_ID? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || {
  echo "Aborted."
  exit 1
}

# --- 1. S3 bucket -------------------------------------------------------------
echo
echo "==> S3 bucket: $BUCKET_NAME"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket already exists, skipping create."
else
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
  echo "Created bucket."
fi
aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "Public access blocked (CloudFront will reach it privately via OAC, not a public policy)."

# --- 2. ACM certificate --------------------------------------------------------
echo
echo "==> ACM certificate for $BUCKET_NAME"
CERT_ARN=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?DomainName=='$BUCKET_NAME'].CertificateArn | [0]" --output text)

if [[ "$CERT_ARN" == "None" || -z "$CERT_ARN" ]]; then
  CERT_ARN=$(aws acm request-certificate --domain-name "$BUCKET_NAME" \
    --validation-method DNS --region "$REGION" --query CertificateArn --output text)
  echo "Requested certificate: $CERT_ARN"
else
  echo "Certificate already exists: $CERT_ARN"
fi

# validation record can take a few seconds to populate after a fresh request
RECORD_NAME="None"
for _ in $(seq 1 10); do
  RECORD_NAME=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text)
  [[ "$RECORD_NAME" != "None" ]] && break
  sleep 3
done
RECORD_VALUE=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" --output text)

echo
echo "Add this CNAME at your DNS provider to validate the certificate:"
echo "  Name:  $RECORD_NAME"
echo "  Value: $RECORD_VALUE"
read -rp "Press Enter once the record is added (validation happens automatically after)... "

echo "Waiting for certificate to be issued (can take several minutes; safe to Ctrl+C and re-run later)..."
aws acm wait certificate-validated --certificate-arn "$CERT_ARN" --region "$REGION"
echo "Certificate issued: $CERT_ARN"

# --- 3. CloudFront distribution (manual — too many moving parts for one CLI call) ---
echo
echo "==> CloudFront distribution"
echo "Manual step — in the AWS Console:"
echo "  1. CloudFront -> Create distribution"
echo "  2. Origin: the $BUCKET_NAME S3 bucket (accept the offered Origin Access Control)"
echo "  3. Viewer protocol policy: Redirect HTTP to HTTPS"
echo "  4. Alternate domain name (CNAME): $BUCKET_NAME"
echo "  5. Custom SSL certificate: select the cert issued above"
echo "  6. Default root object: index.html"
echo "(Full detail: docs/setup_aws.md section 3.)"
read -rp "Enter the CloudFront Distribution ID once created: " DISTRIBUTION_ID

# --- 4. DNS reminder -----------------------------------------------------------
echo
echo "==> DNS"
echo "Point $BUCKET_NAME (apex domain, so no plain CNAME) at the CloudFront distribution:"
echo "  Route 53: A record, Alias: Yes, targeting the distribution."
echo "  Other providers: use an ALIAS/ANAME record if supported (see docs/setup_aws.md §4)."

# --- 5. IAM OIDC provider (account-wide, one-time) ------------------------------
echo
echo "==> IAM OIDC provider for GitHub Actions"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "OIDC provider already exists."
else
  aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "$OIDC_THUMBPRINT"
  echo "Created OIDC provider."
fi

# --- 6. IAM role + least-privilege policy ---------------------------------------
echo
echo "==> IAM role: $ROLE_NAME"

TRUST_POLICY=$(
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "$OIDC_ARN" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${REPO_SLUG}:ref:refs/heads/main" }
      }
    }
  ]
}
JSON
)

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role already exists, updating trust policy."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY"
  echo "Created role."
fi

PERMISSIONS_POLICY=$(
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${BUCKET_NAME}", "arn:aws:s3:::${BUCKET_NAME}/*"]
    },
    {
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DISTRIBUTION_ID}"
    }
  ]
}
JSON
)

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "${ROLE_NAME}-policy" --policy-document "$PERMISSIONS_POLICY"
echo "Attached permissions policy."

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

# --- Summary ---------------------------------------------------------------------
echo
echo "==> Done. Paste these into .github/workflows/deploy.yml:"
echo "  role-to-assume:    $ROLE_ARN"
echo "  s3 sync bucket:    s3://$BUCKET_NAME"
echo "  --distribution-id: $DISTRIBUTION_ID"
echo
echo "Then test with: gh workflow run deploy.yml --repo $REPO_SLUG"
echo "Once that succeeds, uncomment the 'push: branches: [main]' trigger in deploy.yml."
