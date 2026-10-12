# AWS CI/CD Foundations

Personal learning project: a simple CI/CD pipeline on AWS using GitHub Actions, Terraform and EC2 (deployed via SSM, no SSH).

## About me
- Experienced GCP cloud architect, new to AWS. Explain AWS concepts by mapping them to GCP equivalents.
- This is for learning. Explain *why*, and let me write the first version of key files myself, then review them.
- Windows 11, PowerShell, VS Code.

## AWS setup
- Account: "Lans AWS Sandbox", a member account in an AWS Organization.
- Region: **eu-north-1 (Stockholm) only**. An SCP denies most actions in other regions, so never suggest eu-west-2 or other regions.
- Auth: IAM Identity Center (sign-in region us-east-1), CLI profile `sandbox`. Run `aws sso login --profile sandbox` when the session expires.
- Terraform state: S3 bucket with versioning, native locking (`use_lockfile = true`), no DynamoDB.

## Repo layout
- `bootstrap/`: persistent layer (GitHub OIDC provider, pipeline IAM role). Never destroyed.
- `infra/`: ephemeral layer (VPC, subnet, security group, EC2, instance profile). Destroyed after each session.
- `app/`: small hello-world app with tests.
- `.github/workflows/`: CI (lint, test, terraform plan) and CD (apply, deploy via SSM), plus a manual destroy workflow.

## Rules
- Keep costs minimal: target under $10-20/month. No NAT gateways, load balancers, RDS or unattached Elastic IPs.
- Use t3.micro. Tag all resources with `Project = "aws-cicd-foundations"` via provider `default_tags`.
- Never run `terraform apply` or `destroy` without showing me the plan first.
- No long-lived AWS access keys. GitHub Actions authenticates via OIDC.
- Never commit state files, `*.tfvars` or secrets.