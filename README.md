# AWS CI/CD Foundations

A small, end-to-end CI/CD pipeline on AWS, built as a hands-on learning project. A Flask app is tested on every pull request, its infrastructure is planned and applied with Terraform from GitHub Actions, and the app is deployed to an EC2 instance through AWS Systems Manager. No SSH, no open admin ports and no long-lived AWS credentials anywhere.

**Stack:** GitHub Actions, Terraform, EC2, S3, IAM (OIDC), Systems Manager, Python/Flask

## Architecture

```mermaid
flowchart LR
    Dev([Developer]) -->|pull request| GH[GitHub]

    subgraph CI["GitHub Actions"]
        direction TB
        T1[App CI: ruff and pytest]
        T2[Terraform CI: fmt, validate, plan]
        T3[Infra: apply or destroy]
        T4[Deploy app]
    end

    GH --> CI
    CI -->|OIDC token| STS[AWS STS]
    STS -->|temporary credentials| CI

    subgraph AWS["AWS (eu-north-1)"]
        S3S[(S3: Terraform state)]
        S3A[(S3: app artifacts)]
        subgraph VPC["VPC with public subnet"]
            EC2[EC2 t3.micro<br/>Flask + gunicorn]
        end
        SSM[Systems Manager]
    end

    T2 -->|read-only plan role| S3S
    T3 -->|apply role| VPC
    T4 -->|upload build| S3A
    T4 -->|Run Command| SSM
    SSM --> EC2
    EC2 -->|pull build| S3A
```

## Repo layout

```
.
├── .github/workflows/
│   ├── ci.yml             # App lint and tests on PRs and pushes to main
│   ├── terraform-ci.yml   # fmt, validate and plan on PRs, plan posted as a comment
│   ├── infra.yml          # Manual apply or destroy of the infra layer
│   └── deploy.yml         # Package, upload, deploy via SSM, health check
├── app/                   # Flask hello-world app and tests
├── deploy/
│   └── remote-deploy.sh   # Runs on the instance: install, systemd service, health check
├── bootstrap/             # Persistent layer, applied once by hand
│   └── main.tf            # OIDC provider, plan and apply roles, artifacts bucket
├── infra/                 # Disposable layer, applied by the pipeline
│   ├── main.tf            # VPC, subnet, security group, IAM instance role, EC2
│   └── outputs.tf
└── CLAUDE.md              # Project context for Claude Code
```

## How it works

| Workflow | Trigger | What it does | AWS role |
|---|---|---|---|
| **CI** | Pull request, push to `main` | Lints with ruff, tests with pytest | none |
| **Terraform CI** | Pull request | `fmt -check`, `validate`, `plan`, then comments the plan on the PR | plan (read-only) |
| **Infra** | Manual (apply or destroy). Optionally on merge | Runs `terraform apply` or `destroy` on `infra/` | apply |
| **Deploy app** | Manual | Uploads a build to S3, runs the deploy script on the instance through SSM, checks `/health` | apply |

## Cost

Everything is designed to cost pennies when idle. While running, the main costs are the `t3.micro` instance and its public IPv4 address, around a cent or two per hour in total. Destroying the infra layer after each session keeps a month's cost to a few dollars. Persistent pieces (IAM, OIDC, two small S3 buckets) are free or close to it.

## Security notes

- No AWS access keys exist in this repo or in GitHub.
- State files and `*.tfvars` are git-ignored. The state bucket blocks public access and is versioned.
- The instance's security group exposes only port 8080 (the demo app) and has no SSH rule. The instance can read one S3 bucket and talk to SSM, nothing more.
- The apply role currently has `AdministratorAccess`. Narrowing it to what Terraform actually needs is a planned improvement.