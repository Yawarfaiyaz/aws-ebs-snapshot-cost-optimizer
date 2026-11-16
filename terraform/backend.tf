# Remote state in S3. The bucket is created by the bootstrap/ folder first.
# CHANGE the bucket name below to the "state_bucket_name" output of bootstrap.
# use_lockfile = true locks the state using S3 itself (no DynamoDB table needed).
terraform {
  backend "s3" {
    bucket       = "ebs-snapshot-cleanup-tfstate-941058375158"
    key          = "ebs-snapshot-cleanup/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
