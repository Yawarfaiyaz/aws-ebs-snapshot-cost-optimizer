# AWS Cost Optimization: Safe Orphaned EBS Snapshot Cleanup

An automated AWS system that finds and deletes **orphaned EBS snapshots** (snapshots whose source volume no longer exists) to cut unnecessary storage costs.

Built with **Lambda (Python + Boto3)**, scheduled by **EventBridge**, monitored by **CloudWatch**, reporting through **SNS**, provisioned with **Terraform** (S3 remote state) and deployed by **GitHub Actions** with a least-privilege IAM user (see "Why not OIDC?").

## Architecture

```
GitHub repo ──push──▶ GitHub Actions ──keys──▶ limited IAM user ──▶ Terraform (state in S3)
                                                                │
              ┌─────────────────────┬──────────────────────────┼───────────────────┐
              ▼                     ▼                          ▼                   ▼
     EventBridge schedule ──▶ Lambda cleanup ──logs──▶ CloudWatch Logs     AWS Budget
                                    │                  CloudWatch Alarms          │
                                    │                  (errors, throttles)        │
                                    ▼                          │                  │
                           EBS snapshot checks                 │                  │
                                    │                          ▼                  ▼
                                    └──── report ─────────▶  SNS  ──────────▶  Email
```

## Safety rules (what makes this project different)

A snapshot is deleted **only if all** of these are true:

| Check | Why |
|---|---|
| Source volume **no longer exists** | A *detached* volume still holds data, so its snapshots are kept |
| Older than `retention_days` (default 30) | Recent backups are never touched |
| No `DoNotDelete=true` tag | Lets people protect important snapshots |
| Not used by an AMI | Deleting it would break the machine image |
| Has a real source volume ID | Copied snapshots (`vol-ffffffff`) can't be judged, so they're skipped |

**Dry-run mode is ON by default**: the first deployment only reports what *would* be deleted.

## Project structure

```
aws-cost-optimization/
├── lambda/lambda_function.py        # Cleanup logic
├── terraform/                       # Main infrastructure
│   ├── provider.tf  backend.tf  variables.tf  outputs.tf
│   ├── iam.tf  lambda.tf  sns.tf  eventbridge.tf  cloudwatch.tf
│   └── terraform.tfvars.example
├── bootstrap/main.tf                # One-time: S3 state bucket + limited GitHub Actions user
└── .github/workflows/terraform.yml  # CI/CD: fmt → init → validate → plan → apply
```

---

## Setup guide (do these in order)

### What you need installed
- AWS account (billing in good standing) and the **AWS CLI**, configured with `aws configure`
- **Terraform 1.10 or newer**
- **Git** and a **GitHub** account

### Step 0: Region

This account is locked by AWS to its home region **ap-southeast-2 (Sydney)**. Every other region returns
`explicit deny in a service control policy`. Set it once:

```bash
aws configure set region ap-southeast-2
```

Also select **Asia Pacific (Sydney)** in the console's region menu.

### Step 1: Bootstrap (one time, from your laptop)

```bash
cd bootstrap
terraform init
terraform apply
```

Copy the outputs:
- `state_bucket_name` → paste into `terraform/backend.tf` (replace `CHANGE-ME-tfstate-bucket`)
- `github_actions_user_name` → used in Step 3

Keep `bootstrap/terraform.tfstate` safe on your laptop. It is git-ignored on purpose.

### Step 2: First deploy from your laptop (dry run)

```bash
cd ../terraform
cp terraform.tfvars.example terraform.tfvars   # put your email in it
terraform fmt -recursive
terraform init
terraform plan
terraform apply
```

Then **open your email and click "Confirm subscription"** from AWS SNS. Without this you get no emails.

### Step 3: Connect GitHub Actions

1. **IAM console → Users → `ebs-snapshot-cleanup-github-actions` → Security credentials → Create access key**
   → choose *Third-party service* → create → download the CSV.
2. Create a GitHub repo and push this project to the `main` branch.
3. In the repo: **Settings → Secrets and variables → Actions**
   - **Secrets** tab → `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from the CSV
   - **Variables** tab → `ALERT_EMAIL` = your email
4. Go to **Actions** and run the workflow (or push any change). It should go green and the plan should say "No changes", because the state is shared in S3.

From now on, **every push to `main` deploys automatically.**

### Why not OIDC?

GitHub OIDC is the preferred method because no long-lived keys are stored. On this account, AWS applies a
managed service control policy that explicitly denies IAM OpenID Connect provider actions:

```
iam:ListOpenIDConnectProviders ... with an explicit deny in a service control policy
```

An SCP overrides every IAM permission, so this cannot be fixed from inside the account. As a documented fallback,
GitHub Actions uses a **dedicated IAM user** whose policy allows only this project's services and roles plus the
state bucket. Its keys are stored as **encrypted GitHub Secrets** and should be rotated regularly. On an account
without this restriction, the workflow can be switched back to `role-to-assume` with OIDC.

---

## End-to-end test

1. **EC2 console** → launch a `t2.micro`/`t3.micro` instance (free tier).
2. **Volumes** → select its volume → **Create snapshot**.
3. **Terminate** the instance. If the volume remains, **delete** it.
4. The snapshot is now orphaned. Because it is brand new, temporarily set `retention_days = 0` in `terraform.tfvars` and run `terraform apply`.
5. **Lambda console** → your function → **Test** (any event, e.g. `{}`).
   - Dry run: logs say `DRY RUN: would delete snap-...` and you get a "DRY RUN" email. The snapshot is still there.
6. Set `dry_run = false`, run `terraform apply`, and test again.
   - Logs say `Deleted snap-...`, the snapshot disappears from EC2 → Snapshots, and the email says "LIVE".
7. **Protection test**: create another snapshot, add tag `DoNotDelete = true`, delete its volume, and run the test. It must be kept.
8. Put `retention_days` back to 30 and apply.

Take screenshots of the logs, the email and the empty Snapshots page for your portfolio.

## Cleaning up (avoid charges)

```bash
cd terraform && terraform destroy
```

The bootstrap S3 bucket is protected from deletion on purpose. It costs almost nothing. Also make sure no EC2 instances or volumes are left running from testing.

## Costs

At this scale everything is in or near the free tier: one Lambda run per day, a few emails, small log volume (kept 14 days), a tiny S3 state file. The **AWS Budget** in `cloudwatch.tf` emails you if spending crosses 80% of the monthly limit (default $5).
