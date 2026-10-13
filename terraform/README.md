# AI-Powered E-Learning Content Automation Pipeline — Infra

## Folder structure

```
terraform/
├── bootstrap/     # Creates the S3 bucket + DynamoDB table used as the
│                  # remote state backend for everything else. Run this
│                  # ONCE, first, with local state.
└── main/          # The actual project infra (VPC, S3, DynamoDB, and
                    # later: ECS, Lambda, Step Functions, etc.). Uses the
                    # remote backend created by bootstrap/.
```

## Step 1: Run bootstrap

```bash
cd bootstrap
terraform init
terraform plan -var="unique_suffix=YOUR_UNIQUE_STRING"
terraform apply -var="unique_suffix=YOUR_UNIQUE_STRING"
```

Replace `YOUR_UNIQUE_STRING` with something unique to you.
This keeps S3 bucket names globally unique.

After `apply` finishes, copy the two output values:
- `state_bucket_name`
- `lock_table_name`

## Step 2: Wire up main/backend.tf

Open `main/backend.tf` and replace:
- `REPLACE_WITH_state_bucket_name_OUTPUT` with the `state_bucket_name` output
- `REPLACE_WITH_lock_table_name_OUTPUT` with the `lock_table_name` output

## Step 3: Initialize main/

```bash
cd ../main
terraform init
terraform plan -var="unique_suffix=YOUR_UNIQUE_STRING"
```

`main.tf` is intentionally empty right now — `plan` should show
"No changes." That confirms your credentials, provider, and remote
backend are all working correctly before we add any real infrastructure.

## Next step (not yet in this repo)

Once Step 3 is verified, we add VPC + S3 + DynamoDB resources to
`main/main.tf`.
