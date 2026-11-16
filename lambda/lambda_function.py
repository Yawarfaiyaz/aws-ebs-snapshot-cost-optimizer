"""
Orphaned EBS snapshot cleanup.

A snapshot is deleted ONLY if ALL of these are true:
  1. It is owned by this account.
  2. Its source volume NO LONGER EXISTS (a detached volume still counts as existing).
  3. It is older than RETENTION_DAYS.
  4. It does NOT have the protection tag (e.g. DoNotDelete=true).
  5. It is NOT used by an AMI (machine image) owned by this account.

DRY_RUN=true (the default) only reports what WOULD be deleted.
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))
PROTECT_TAG_KEY = os.environ.get("PROTECT_TAG_KEY", "DoNotDelete")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

# AWS uses this placeholder when a snapshot has no real source volume
# (for example, a copied snapshot). We cannot judge those, so we skip them.
PLACEHOLDER_VOLUME_ID = "vol-ffffffff"


def get_snapshots():
    """All snapshots owned by this account (handles pagination)."""
    snapshots = []
    paginator = ec2.get_paginator("describe_snapshots")
    for page in paginator.paginate(OwnerIds=["self"]):
        snapshots.extend(page["Snapshots"])
    return snapshots


def get_existing_volume_ids():
    """IDs of every volume that still exists, attached or not."""
    volume_ids = set()
    paginator = ec2.get_paginator("describe_volumes")
    for page in paginator.paginate():
        for volume in page["Volumes"]:
            volume_ids.add(volume["VolumeId"])
    return volume_ids


def get_ami_snapshot_ids():
    """Snapshots that back an AMI owned by this account. Never delete these."""
    snapshot_ids = set()
    response = ec2.describe_images(Owners=["self"])
    for image in response.get("Images", []):
        for mapping in image.get("BlockDeviceMappings", []):
            snapshot_id = mapping.get("Ebs", {}).get("SnapshotId")
            if snapshot_id:
                snapshot_ids.add(snapshot_id)
    return snapshot_ids


def is_protected(snapshot):
    for tag in snapshot.get("Tags", []):
        if tag["Key"] == PROTECT_TAG_KEY and tag["Value"].lower() in ("true", "yes", "1"):
            return True
    return False


def skip_reason(snapshot, existing_volumes, ami_snapshots, cutoff):
    """Return why a snapshot must be kept, or None if it is safe to delete."""
    volume_id = snapshot.get("VolumeId")
    if not volume_id or volume_id == PLACEHOLDER_VOLUME_ID:
        return "no source volume information"
    if volume_id in existing_volumes:
        return "source volume still exists"
    if snapshot["SnapshotId"] in ami_snapshots:
        return "used by an AMI"
    if is_protected(snapshot):
        return f"protected by tag {PROTECT_TAG_KEY}"
    if snapshot["StartTime"] > cutoff:
        return f"younger than {RETENTION_DAYS} days"
    return None


def send_report(report):
    if not SNS_TOPIC_ARN:
        logger.info("SNS_TOPIC_ARN not set, skipping email")
        return
    mode = "DRY RUN (nothing deleted)" if report["dry_run"] else "LIVE"
    lines = [
        "AWS Cost Optimization Cleanup Report",
        f"Mode: {mode}",
        f"Snapshots checked: {report['checked']}",
        "",
    ]
    if report["dry_run"]:
        lines.append(f"Would delete ({len(report['would_delete'])}):")
        lines += [f"  {s}" for s in report["would_delete"]] or ["  none"]
    else:
        lines.append(f"Deleted ({len(report['deleted'])}):")
        lines += [f"  {s}" for s in report["deleted"]] or ["  none"]
    if report["failed"]:
        lines.append("")
        lines.append(f"Failed ({len(report['failed'])}):")
        lines += [f"  {f['snapshot_id']}: {f['error']}" for f in report["failed"]]

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="EBS Snapshot Cleanup Report",
        Message="\n".join(lines),
    )


def lambda_handler(event, context):
    logger.info("Starting cleanup: dry_run=%s retention_days=%s", DRY_RUN, RETENTION_DAYS)

    cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    snapshots = get_snapshots()
    existing_volumes = get_existing_volume_ids()
    ami_snapshots = get_ami_snapshot_ids()

    report = {
        "dry_run": DRY_RUN,
        "checked": len(snapshots),
        "deleted": [],
        "would_delete": [],
        "skipped": [],
        "failed": [],
    }

    for snapshot in snapshots:
        snapshot_id = snapshot["SnapshotId"]
        reason = skip_reason(snapshot, existing_volumes, ami_snapshots, cutoff)

        if reason:
            logger.info("Keeping %s: %s", snapshot_id, reason)
            report["skipped"].append({"snapshot_id": snapshot_id, "reason": reason})
            continue

        if DRY_RUN:
            logger.info("DRY RUN: would delete %s (volume %s gone)", snapshot_id, snapshot["VolumeId"])
            report["would_delete"].append(snapshot_id)
            continue

        try:
            ec2.delete_snapshot(SnapshotId=snapshot_id)
            logger.info("Deleted %s (volume %s gone)", snapshot_id, snapshot["VolumeId"])
            report["deleted"].append(snapshot_id)
        except ClientError as err:
            logger.error("Failed to delete %s: %s", snapshot_id, err)
            report["failed"].append({"snapshot_id": snapshot_id, "error": str(err)})

    logger.info("Report: %s", json.dumps(report))

    if report["deleted"] or report["would_delete"] or report["failed"]:
        send_report(report)

    return report
