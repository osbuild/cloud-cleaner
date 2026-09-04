#!/usr/bin/env python3
"""
AWS S3 images-ci-cache cleaner

This script lists and cleans up cached test images from s3://images-ci-cache.

Cache cleanup for this bucket is handled separately and with special rules:
- Blobs in the root are deleted if they are over 2h old. These are images uploaded to create AMIs for testing. The
  uploaders should be deleting them immediately but, if that fails, this script will handle them.
- Cached images and metadata with a DeleteAfter date on the info.json that is in the past are deleted. The info.json
  files are updated with a DeleteAfter timestamp whenever they, and their associated images, are created or found
  matching a CI image (cache hit).
- If an info.json file does not have a DeleteAfter tag, the associated image and files are deleted if its mtime is over
  2 weeks old.
"""
import argparse
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

BUCKET_NAME = "images-ci-cache"


def collect_prefixes_to_delete(s3, now):
    paginator = s3.get_paginator("list_objects_v2")

    prefixes = []

    mtime_cutoff = now - timedelta(days=14)

    for page in paginator.paginate(Bucket=BUCKET_NAME, Prefix="images/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            print(f"Processing {key}")

            filename = os.path.basename(key)
            if filename != "info.json":
                continue

            tagging = s3.get_object_tagging(Bucket=BUCKET_NAME, Key=key)
            tags = {t["Key"]: t["Value"] for t in tagging.get("TagSet", [])}

            if "DeleteAfter" in tags:
                delete_after = datetime.fromisoformat(tags["DeleteAfter"])

                if delete_after < now:
                    prefixes.append(os.path.dirname(key))
                continue

            # if the object wasn't tagged, fall back to mtime and add it to the deletion list if it's over 2 weeks old
            mtime = s3.head_object(Bucket=BUCKET_NAME, Key=key)["LastModified"]
            if mtime < mtime_cutoff:
                prefixes.append(os.path.dirname(key))

    return prefixes


def collect_root_blobs_to_delete(s3, now):
    paginator = s3.get_paginator("list_objects_v2")

    blobs = []

    mtime_cutoff = now - timedelta(hours=2)

    for page in paginator.paginate(Bucket=BUCKET_NAME, Delimiter="/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            print(f"Processing {key}")
            mtime = s3.head_object(Bucket=BUCKET_NAME, Key=key)["LastModified"]
            if mtime < mtime_cutoff:
                blobs.append(key)

    return blobs


def parse_args():
    parser = argparse.ArgumentParser(description=f"Clean up s3://{BUCKET_NAME}.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be removed without actually removing resources",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    dry = args.dry_run

    try:
        print(f"Cleaning up {BUCKET_NAME}...")
        now = datetime.now(timezone.utc)
        s3 = boto3.client("s3")
        prefixes = collect_prefixes_to_delete(s3, now)
        blobs = collect_root_blobs_to_delete(s3, now)

        if dry:
            print("Would delete (prefixes):")
            print("\n".join(prefixes))
            print("Would delete (blobs):")
            print("\n".join(blobs))
            return

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        error_message = e.response["Error"]["Message"]
        print(f"AWS API error - {error_code}: {error_message}")
    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Unexpected error - {str(e)}")


if __name__ == "__main__":
    main()
