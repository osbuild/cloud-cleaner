#!/usr/bin/env python3

import argparse
import atexit
from datetime import datetime
import os
import ssl
import sys

from pyVim import connect
from pyVmomi import vim, vmodl


# https://github.com/vmware/pyvmomi-community-samples/blob/ec890d5286c966ddd8fe48f4eedda2e20620610f/samples/tools/tasks.py#L16C1-L60C31
def wait_for_tasks(si, tasks):
    property_collector = si.content.propertyCollector
    task_list = [str(task) for task in tasks]
    obj_specs = [vmodl.query.PropertyCollector.ObjectSpec(obj=task)
                 for task in tasks]
    property_spec = vmodl.query.PropertyCollector.PropertySpec(type=vim.Task,
                                                               pathSet=[],
                                                               all=True)
    filter_spec = vmodl.query.PropertyCollector.FilterSpec()
    filter_spec.objectSet = obj_specs
    filter_spec.propSet = [property_spec]
    pcfilter = property_collector.CreateFilter(filter_spec, True)
    try:
        version, state = None, None
        while task_list:
            update = property_collector.WaitForUpdates(version)
            for filter_set in update.filterSet:
                for obj_set in filter_set.objectSet:
                    task = obj_set.obj
                    for change in obj_set.changeSet:
                        if change.name == 'info':
                            state = change.val.state
                        elif change.name == 'info.state':
                            state = change.val
                        else:
                            continue

                        if not str(task) in task_list:
                            continue

                        if state == vim.TaskInfo.State.success:
                            task_list.remove(str(task))
                        elif state == vim.TaskInfo.State.error:
                            raise task.info.error
            version = update.version
    finally:
        if pcfilter:
            pcfilter.Destroy()


def get_client(url, user, password):
    si_kwargs = {}
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    si_kwargs['sslContext'] = context
    si = connect.SmartConnect(
        host=url,
        user=user,
        pwd=password,
        **si_kwargs
    )
    atexit.register(connect.Disconnect, si)
    return si


def find_folder(si, content, folder_name):
    folder_container = content.viewManager.CreateContainerView(
        container=content.rootFolder,
        recursive=True,
        type=[vim.Folder],
    )

    for folder in folder_container.view:
        if folder.name == folder_name:
            return folder
    raise RuntimeError(f"unable to find folder {folder_name}")


def find_vms(si, content, folder):
    return content.viewManager.CreateContainerView(
        container=folder,
        recursive=True,
        type=[vim.VirtualMachine],
    )


def parse_args():
    """
    Parses and returns the command-line arguments.
    """
    parser = argparse.ArgumentParser(
        description='Find and destroy old tagged VMware VMs.')

    # Use environment variables as the default source of truth, like the shell script
    parser.add_argument(
        '--url',
        default=os.getenv('GOVMOMI_URL'))
    parser.add_argument(
        '--user',
        default=os.getenv('GOVMOMI_USERNAME'))
    parser.add_argument(
        '--password',
        default=os.getenv('GOVMOMI_PASSWORD'))
    parser.add_argument(
        '--folder',
        default=os.getenv('GOVMOMI_FOLDER'))
    parser.add_argument(
        '--max-age',
        type=int,
        default=6,
        help="Maximum resource age in hours before eligible for removal (default: 6)")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be removed without actually removing resources",
    )

    args = parser.parse_args()

    if not args.url or not args.user or not args.password:
        parser.error("make sure --url, --user and --password are set.")

    return args


def main():
    args = parse_args()
    si = get_client(args.url, args.user, args.password)
    content = si.RetrieveContent()
    composer_folder = find_folder(si, content, args.folder)

    vms = find_vms(si, content, composer_folder)
    to_destroy = []
    for vm in vms.view:
        creation_date = vm.storage.timestamp
        current_time = datetime.now(creation_date.tzinfo)
        age_hours = (current_time - creation_date).total_seconds() / 3600

        if age_hours < args.max_age:
            print(f"skipping VM {vm.name} ({age_hours:.1f}h old)")
            continue
        print(f"destroying VM {vm.name} ({age_hours:.1f}h old)")
        to_destroy.append(vm)

    poweroff_tasks = [vm.PowerOffVM_Task() for vm in to_destroy]
    if poweroff_tasks:
        print(f"waiting for {len(poweroff_tasks)} poweroff task(s) to complete")
        wait_for_tasks(si, poweroff_tasks)

    destroy_tasks = [vm.Destroy_Task() for vm in to_destroy]
    if destroy_tasks:
        print(f"waiting for {len(destroy_tasks)} destroy task(s) to complete")
        wait_for_tasks(si, destroy_tasks)
    print("cleanup done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
