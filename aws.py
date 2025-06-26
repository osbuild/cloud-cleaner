#!/usr/bin/env python3
"""
AWS EC2 Resource Cleaner

This script lists and cleans up AWS resources, including EC2 instances,
AMIs (images), and EBS snapshots across all opted-in regions.
If not run in dry-run mode, it will terminate/deregister/delete resources
that are not protected.
"""

import boto3
from datetime import datetime
import argparse
from botocore.exceptions import ClientError


def get_tag_value(tags, key):
    """Get the value of a specific tag by key."""
    if not tags:
        return None
    for tag in tags:
        if tag["Key"] == key:
            return tag["Value"]
    return None


def should_remove_resource(tags, creation_date, max_age_hours):
    """
    Determine if a resource should be removed based on its tags and age.

    Args:
        tags (list): List of resource tags, each tag is a dict with 'Key' and 'Value' fields
        creation_date (datetime): The creation timestamp of the resource
        max_age_hours (int): Maximum allowed age in hours before resource is eligible for removal

    Returns:
        tuple: A pair of (bool, str) where:
            - bool: True if resource should be removed, False otherwise
            - str: Reason for the decision (None if should be removed, explanation string if kept)
    """
    persist_tag = get_tag_value(tags, "persist")
    if persist_tag and persist_tag.lower() == "true":
        return False, "persist=true"

    current_time = datetime.now(creation_date.tzinfo)
    age_hours = (current_time - creation_date).total_seconds() / 3600

    if age_hours < max_age_hours:
        return False, f"age={age_hours:.1f}h"

    return True, None


def get_enabled_regions():
    """Get list of all enabled regions in the account."""
    ec2_client = boto3.client("ec2", region_name="us-east-1")
    regions = ec2_client.describe_regions(
        Filters=[
            {"Name": "opt-in-status", "Values": ["opted-in", "opt-in-not-required"]}
        ]
    )
    return [region["RegionName"] for region in regions["Regions"]]


class EC2ResourceCleaner:
    def __init__(self, region, max_age_hours, dry_run):
        self.region = region
        self.max_age_hours = max_age_hours
        self.dry_run = dry_run
        self.ec2_client = boto3.client("ec2", region_name=region)

    def process_instances(self):
        """
        Process EC2 instances in the configured region.
        Lists all non-terminated instances and terminates unprotected ones if not in dry-run mode.
        """
        print(f"{self.region}: --- Analyzing EC2 Instances ---")
        response = self.ec2_client.describe_instances()

        instance_found = False
        for reservation in response["Reservations"]:
            for instance in reservation["Instances"]:
                state = instance["State"]["Name"]

                if state in ["terminated", "shutting-down"]:
                    continue

                instance_found = True
                instance_id = instance["InstanceId"]

                should_terminate, reason = should_remove_resource(
                    instance.get("Tags", []), instance["LaunchTime"], self.max_age_hours
                )

                if should_terminate:
                    if self.dry_run:
                        print(f"{self.region}: {instance_id}: WOULD TERMINATE")
                    else:
                        try:
                            self.ec2_client.terminate_instances(
                                InstanceIds=[instance_id]
                            )
                            print(f"{self.region}: {instance_id}: TERMINATING")
                        except Exception as e:
                            print(
                                f"{self.region}: {instance_id}: FAILED TO TERMINATE ({str(e)})"
                            )
                else:
                    print(
                        f"{self.region}: {instance_id}: WOULD NOT TERMINATE ({reason})"
                    )

        if not instance_found:
            print(f"{self.region}: No running or pending instances found")

    def process_amis(self):
        """
        Process EC2 AMIs (images) in the configured region and return a set of snapshot IDs in use.
        Lists all AMIs and deregisters unprotected ones if not in dry-run mode.
        Returns a set of snapshot IDs that belong to protected AMIs.
        """
        print(f"{self.region}: --- Analyzing EC2 AMIs (Images) ---")
        images_response = self.ec2_client.describe_images(Owners=["self"])

        images = images_response.get("Images", [])
        if not images:
            print(f"{self.region}: No images found")
            return set()

        snapshots_in_use = set()
        for image in images:
            image_id = image["ImageId"]
            tags = image.get("Tags", [])
            creation_date_str = image["CreationDate"]
            creation_date = datetime.fromisoformat(creation_date_str)

            should_deregister, reason = should_remove_resource(
                tags, creation_date, self.max_age_hours
            )

            if should_deregister:
                if self.dry_run:
                    print(f"{self.region}: {image_id}: WOULD DEREGISTER")
                else:
                    try:
                        self.ec2_client.deregister_image(ImageId=image_id)
                        print(f"{self.region}: {image_id}: DEREGISTERED")
                    except Exception as e:
                        print(
                            f"{self.region}: {image_id}: FAILED TO DEREGISTER ({str(e)})"
                        )
            else:
                print(f"{self.region}: {image_id}: WOULD NOT DEREGISTER ({reason})")
                for device in image.get("BlockDeviceMappings", []):
                    if "Ebs" in device and "SnapshotId" in device["Ebs"]:
                        snapshots_in_use.add(device["Ebs"]["SnapshotId"])

        return snapshots_in_use

    def process_snapshots(self, snapshots_in_use):
        """
        Process EC2 EBS snapshots in the configured region.
        Lists all snapshots and deletes unprotected ones if not in dry-run mode.
        Skips snapshots that belong to protected AMIs.

        Args:
            snapshots_in_use (set): Set of IDs of snapshots in use
        """
        print(f"{self.region}: --- Analyzing EC2 EBS Snapshots ---")
        snapshots_response = self.ec2_client.describe_snapshots(OwnerIds=["self"])

        snapshots = snapshots_response.get("Snapshots", [])
        if not snapshots:
            print(f"{self.region}: No snapshots found")
            return

        for snapshot in snapshots:
            snapshot_id = snapshot["SnapshotId"]

            if snapshot_id in snapshots_in_use:
                print(f"{self.region}: {snapshot_id}: WOULD NOT DELETE (used by AMI)")
                continue

            should_delete, reason = should_remove_resource(
                snapshot.get("Tags", []), snapshot["StartTime"], self.max_age_hours
            )

            if should_delete:
                if self.dry_run:
                    print(f"{self.region}: {snapshot_id}: WOULD DELETE")
                else:
                    try:
                        self.ec2_client.delete_snapshot(SnapshotId=snapshot_id)
                        print(f"{self.region}: {snapshot_id}: DELETED")
                    except Exception as e:
                        print(
                            f"{self.region}: {snapshot_id}: FAILED TO DELETE ({str(e)})"
                        )
            else:
                print(f"{self.region}: {snapshot_id}: WOULD NOT DELETE ({reason})")


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="List and optionally clean up unprotected AWS resources across all regions."
    )
    parser.add_argument(
        "--region",
        help="Only check specific AWS region (default: checks all opted-in regions)",
    )
    parser.add_argument(
        "--max-age",
        type=int,
        default=6,
        help="Maximum resource age in hours before eligible for removal (default: 6)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be removed without actually removing resources",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    if args.region:
        regions = [args.region]
    else:
        regions = get_enabled_regions()

    for region in regions:
        try:
            print(f"Cleaning up {region}...")
            cleaner = EC2ResourceCleaner(
                region=region, max_age_hours=args.max_age, dry_run=args.dry_run
            )
            cleaner.process_instances()
            snapshots_in_use = cleaner.process_amis()
            cleaner.process_snapshots(snapshots_in_use)
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            error_message = e.response["Error"]["Message"]
            print(f"{region}: AWS API error - {error_code}: {error_message}")
        except Exception as e:
            print(f"{region}: Unexpected error - {str(e)}")


if __name__ == "__main__":
    main()
