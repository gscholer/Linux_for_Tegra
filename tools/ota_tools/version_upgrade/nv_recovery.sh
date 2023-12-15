#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2019-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

# This is a script to run tasks automatically in recovery mode
set -e

source /bin/nv_ota_internals.sh
source /bin/nv_ota_log.sh
source /bin/nv_ota_utils.func
source /bin/nv_ota_disk_enc.func

OTA_RUN_TASKS_SCRIPT="nv_ota_run_tasks.sh"
INTERNAL_DEVICE=

# OTA update rootfs on devices other than eMMC such as SD, USB, and NVMe
EXTERNAL_DEVICES=(
	"/dev/mmcblk?p1"
	"/dev/sd?1"
	"/dev/nvme?n1p1"
)
DM_CRYPT_OTA="dm_crypt_ota"

rootfs_part=
dm_crypt=

check_internal_device()
{
	# Set INTERNAL_DEVICE
	# If kernel version is earlier than 5.15, set INTERNAL_DEVICE=/dev/mmcblk0
	# Otherwise, set INTERNAL_DEVICE=/dev/mmcblk3
	local comp_ver=5015
	local major_num=
	local minor_num=
	local kernel_ver=

	# The maximum values of major number and minor number are 255, so constructing
	# version number with major * 1000 + minor is secure.
	major_num="$(uname -r | cut -d\. -f 1)"
	minor_num="$(uname -r | cut -d\. -f 2)"
	kernel_ver="$((major_num * 1000 + minor_num))"
	if [ "${kernel_ver}" -lt "${comp_ver}" ]; then
		INTERNAL_DEVICE="/dev/mmcblk0"
	else
		INTERNAL_DEVICE="/dev/mmcblk3"
	fi

	# Waiting for internal device
	local timeout=10
	while [ "${timeout}" -gt 0 ]
	do
		if [ -e "${INTERNAL_DEVICE}" ]; then
			break
		fi
		sleep 1
		timeout="$((timeout - 1))"
	done
}

load_nvme_device_drivers()
{

	if [ -e "/dev/nmve0n1" ]; then
		return 0
	fi

	if [ ! -e "/usr/sbin/modprobe" ]; then
		ln -s /bin/kmod /usr/sbin/modprobe
	fi

	local nvme_drivers=(
		"phy_tegra194_p2u"
		"pcie_tegra194"
		"nvme"
		"tegra-bpmp-thermal"
		"pwm-fan"
	)

	local driver=
	for driver in "${nvme_drivers[@]}"
	do
		if ! modprobe -v "${driver}"; then
			ota_log "Failed to probe ${driver}"
			return 1
		fi
	done
	return 0
}

set_rootfs_and_dm_crypt()
{
	# Set the rootfs part and dm_crypt
	# Usage:
	#        set_rootfs_and_dm_crypt
	ota_log "Set rootfs=${rootfs_part}"
	store_variable "rootfs_part"
	ota_log "Set dm_crypt=${dm_crypt}"
	store_variable "dm_crypt"
}

is_mounted()
{
	# Check whether specified path is mounted on partition
	# Usage:
	#        is_mounted {mount_point}
	local mount_point="${1}"
	local ret=

	set +e
	if grep "${mount_point}" </proc/mounts >/dev/null 2>&1; then
		ret=0
	else
		ret=1
		ota_log "No partition is mounted on ${mount_point}"
	fi
	set -e
	return ${ret}
}

umount_partition()
{
	# Unmount the partition mounted on the specified path
	# Usage:
	#        umount_partition {mount_point}
	local mount_point="${1}"

	if is_mounted "${mount_point}"; then
		if ! umount "${mount_point}"; then
			ota_log "Failed to umount ${mount_point}"
			return 1
		fi
	fi
	return 0
}

mount_rootfs_partition()
{
	# Mount rootfs partition including OTA work directory
	# Steps:
	#  1. Get the PARTUUID for rootfs partition from the "extlinux.conf"
	#     in the mounted boot partition. The OTA work directory is
	#     put on the rootfs partition.
	#  2. If PARTUUID is found, the rootfs partition is not encrypted.
	#     Otherwise, the rootfs partition is encrypted. Get UUID and convert it
	#     to the partition node
	#  3. Umount the boot partition that is mounted on the specified mount point.
	#  4. Mount rootfs partition
	#    4a. If it is not encrypted, directly mount it.
	#    4b. If it is encrypted, unlock it and then mount the unlocked partition.
	# Usage:
	#        mount_rootfs_partition {boot_part} {mount_point}
	local boot_part="${1}"
	local mount_point="${2}"

	# Get the uuid of the encrypted OTA partition from extlinux.conf
	local extlinux_conf="${mount_point}/boot/extlinux/extlinux.conf"
	local rootfsuuid=
	local part_node=
	local rootfs_encrypted=
	if [ ! -f "${extlinux_conf}" ]; then
		ota_log "Warning: the ${extlinux_conf} is not found on ${boot_part}, umount it..."
		return 1
	fi
	rootfsuuid="$(grep -m 1 "^[\t  ]\+APPEND" "${extlinux_conf}" | grep -oE "root=PARTUUID=[a-f0-9\-]+" | cut -d= -f 3)"
	if [ "${rootfsuuid}" != "" ]; then
		# Rootfs partition is not encrypted
		part_node="$(blkid | grep -m 1 "PARTUUID=\"${rootfsuuid}\"" | cut -d: -f 1)"
		if [ "${part_node}" == "" ]; then
			ota_log "Failed to get the rootfs partition with PARTUUID=${rootfsuuid}"
			return 1
		fi
		ota_log "Found rootfs partition ${part_node} through PARTUUID(${rootfsuuid})"
		rootfs_encrypted=0
	else
		# Rootfs partition is encrypted. Try getting UUID from extlinux.conf
		rootfsuuid="$(grep -m 1 "^[\t  ]\+APPEND" "${extlinux_conf}" | grep -oE "root=UUID=[a-f0-9\-]+" | cut -d= -f 3)"
		if [ "${rootfsuuid}" == "" ]; then
			ota_log "Faile to get the UUID of the rootfs partition from ${extlinux_conf}"
			return 1
		fi
		# Convert UUID to partition node
		part_node="$(blkid --uuid "${rootfsuuid}")"
		if [ "${part_node}" == "" ]; then
			ota_log "Can not find partition whose UUID is ${rootfsuuid}"
			return 1
		fi
		ota_log "Found encrypted rootfs partition ${part_node} through UUID(${rootfsuuid})"
		rootfs_encrypted=1
	fi
	rootfs_part="${part_node}"

	# Umount the boot partition
	ota_log "umount ${mount_point}"
	if ! umount "${mount_point}"; then
		ota_log "Failed to umount ${mount_point}"
		return 1
	fi

	# Mount the rootfs partition
	if [ "${rootfs_encrypted}" == 0 ]; then
		# Mount directly
		ota_log "mount ${part_node} ${mount_point}"
		if ! mount "${part_node}" "${mount_point}"; then
			ota_log "Failed to mount ${part_node} on the ${mount_point}"
			return 1
		fi
	else
		# Unlock the encrypted rootfs partition
		ota_log "unlock_encrypted_partition ${part_node} ${DM_CRYPT_OTA} dm_crypt"
		if ! unlock_encrypted_partition "${part_node}" "${DM_CRYPT_OTA}" dm_crypt; then
			ota_log "Failed to run \"unlock_encrypted_partition ${part_node} ${DM_CRYPT_OTA} dm_crypt\""
			return 1
		fi

		# Mount the unlocked rootfs partition
		local unlocked_device="/dev/mapper/${dm_crypt}"
		if ! mount "${unlocked_device}" "${mount_point}"; then
			ota_log "Failed to mount ${unlocked_device} on the ${mount_point}"
			return 1
		fi
	fi
	return 0
}

is_boot_only_partition()
{
	# Check whether it is boot only partition
	# If mounted partition is boot partition ,it only includes "/boot"
	# directory but not include "/etc" and "/bin".
	# Usage:
	#        is_boot_only_partition ${mount_point}
	local mount_point="${1}"
	local num_dirs=

	num_dirs="$(ls -Al -I "lost+found" "${mount_point}" | grep -c ^d)"
	if [ "${num_dirs}" == 1 ] && [ -d "${mount_point}/boot" ]; then
		return 0
	else
		return 1
	fi

}

mount_ota_work_partition()
{
	# Mount partition including OTA work directory
	# Usage:
	#        mount_ota_work_partition ${part_node} ${mount_point}
	local part_node="${1}"
	local mount_point="${2}"

	ota_log "mount ${part_node} ${mount_point}"
	if ! mount "${part_node}" "${mount_point}"; then
		ota_log "Failed to mount ${part_node} on the ${mount_point}"
		return 1
	fi
	rootfs_part="${part_node}"

	# Check whether mounted partition is boot partition.
	ota_log "is_boot_only_partition ${mount_point}"
	if is_boot_only_partition "${mount_point}"; then
		# As the OTA work directory is put on the rootfs partition instead
		# of boot parition, so need to find the rootfs partition and mount it.
		ota_log "The mounted ${part_node} is boot partition, try locating rootfs partition and mount it..."
		ota_log "mount_rootfs_partition ${part_node} ${mount_point}"
		if ! mount_rootfs_partition "${part_node}" "${mount_point}"; then
			ota_log "Failed to run \"moutn_rootfs_partition ${part_node} ${mount_point}\""
			return 1
		fi
	fi
}

function find_ota_work_dir()
{
	local device="${1}"

	if ! mount_ota_work_partition "${device}" "${OTA_PACKAGE_MOUNTPOINT}"; then
		ota_log "Failed to run \"mount_ota_work_partition ${device} ${OTA_PACKAGE_MOUNTPOINT}\""
		return 1
	fi

	if [ ! -d "${OTA_WORK_DIR}" ];then
		# Umount the partition if OTA work directory is not found on it
		ota_log "OTA work directory ${OTA_WORK_DIR} is not found on ${device}"
		if ! umount_partition "${OTA_PACKAGE_MOUNTPOINT}"; then
			ota_log "Failed to umount ${OTA_PACKAGE_MOUNTPOINT}"
			return 1
		fi
		rootfs_part=

		# Lock it if the partition is encrypted
		if [ "${dm_crypt}" != "" ]; then
			ota_log "lock_encrypted_partition ${dm_crypt}"
			if ! lock_encrypted_partition "${dm_crypt}"; then
				ota_log "Failed to run \"lock_encrypted_partition ${dm_crypt}\""
				return 1
			fi
			sync
			dm_crypt=
		fi
		return 1
	fi

	return 0
}

function find_ota_work_dir_on_external()
{
	ota_log "Finding OTA work dir on external storage devices"
	for ext_dev in "${EXTERNAL_DEVICES[@]}"; do
		echo "Checking whether device ${ext_dev} exist"
		ext_devices="$(eval ls "${ext_dev}" 2>/dev/null || true)"
		if [ "${ext_devices}" == "" ]; then
			echo "Device ${ext_dev} does not exist"
			continue
		fi
		echo "Looking for OTA work directory on the device(s): ${ext_devices}"
		ext_devices=(${ext_devices// /})
		for device in "${ext_devices[@]}"; do
			if [ "${device}" == "${INTERNAL_DEVICE}" ]; then
			    # Skip internal device
			    continue
			fi
			if ! find_ota_work_dir "${device}"; then
				continue
			fi
			# OTA work directory is always stored on the rootfs partition
			set_rootfs_and_dm_crypt
			return 0
		done
	done

	return 1
}


function find_ota_work_dir_on_internal()
{
	if [ "${INTERNAL_DEVICE}" == "" ]; then
		ota_log "Internal storage device does not exist"
		return 1
	fi
	ota_log "Finding OTA work dir on internal storage device"
	if ! find_ota_work_dir "${INTERNAL_DEVICE}"; then
		return 1
	fi
	set_rootfs_and_dm_crypt
	return 0
}

function enter_bash_shell()
{
	local message="${1}"

	if [ "${message}" != "" ]; then
		ota_log "${message}"
	fi
	/bin/bash
}

set +e

# Check whether internal device exists
check_internal_device

# Load NVMe related drivers
if ! load_nvme_device_drivers; then
	enter_bash_shell "Failed to load NVMe and its dependent drivers"
fi

if ! find_ota_work_dir_on_external; then
	if ! find_ota_work_dir_on_internal; then
		enter_bash_shell "OTA work directory is not found on internal and external storage devices"
	fi
fi

if [ -x "${OTA_WORK_DIR}/${OTA_RUN_TASKS_SCRIPT}" ]; then
	pushd "${OTA_WORK_DIR}"
	eval "./${OTA_RUN_TASKS_SCRIPT}"
	if [ $? -ne 0 ]; then
		enter_bash_shell "Failed to run ${OTA_RUN_TASKS_SCRIPT}"
	fi
	popd
else
	enter_bash_shell "OTA task runner ${OTA_RUN_TASKS_SCRIPT} is not found"
fi
