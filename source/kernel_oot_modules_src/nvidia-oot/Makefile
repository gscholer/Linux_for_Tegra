# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2022-2023, NVIDIA CORPORATION.  All rights reserved.

LINUXINCLUDE += -I$(srctree.nvconftest)
LINUXINCLUDE += -I$(srctree.nvidia-oot)/include

subdir-ccflags-y += -Werror

LINUX_VERSION := $(shell expr $(VERSION) \* 256 + $(PATCHLEVEL))
LINUX_VERSION_6_2 := $(shell expr 6 \* 256 + 2)
LINUX_VERSION_6_3 := $(shell expr 6 \* 256 + 3)
LINUX_VERSION_6_6 := $(shell expr 6 \* 256 + 6)

# The Tegra IVC driver was updated to support iosys-map in Linux v6.2.
# For Linux v6.2 kernels, don't build any drivers that requires this.
ifeq ($(shell test $(LINUX_VERSION) -ge $(LINUX_VERSION_6_2); echo $$?),0)
export CONFIG_TEGRA_IVC_LEGACY_DISABLE=y
endif

ifeq ($(CONFIG_TEGRA_IVC_LEGACY_DISABLE),y)
subdir-ccflags-y += -DCONFIG_TEGRA_IVC_LEGACY_DISABLE
endif

# Legacy GPIO support is removed in Linux v6.3
ifeq ($(shell test $(LINUX_VERSION) -ge $(LINUX_VERSION_6_3); echo $$?),0)
export CONFIG_TEGRA_GPIO_LEGACY_DISABLE=y
endif

# Changes done in Linux 6.6 onwards
ifeq ($(shell test $(LINUX_VERSION) -ge $(LINUX_VERSION_6_6); echo $$?),0)
# Move probe to DAI Ops.
export CONFIG_SND_SOC_MOVE_DAI_PROBE_TO_OPS=y
subdir-ccflags-y += -DNV_SND_SOC_DAI_OPS_STRUCT_HAS_PROBE_ARG

# probe_new is removed from i2c driver structure
subdir-ccflags-y += -DNV_I2C_LEGACY_PROBE_NEW_REMOVED

# API changes to replace u8 with unsigned char
subdir-ccflags-y += -DNV_TTY_SERIAL_TYPE_U8_CHANGE

# v4l2_async_subdev is renamed to v4l2_async_connection.
subdir-ccflags-y += -DNV_V4L2_ASYNC_SUBDEV_RENAME

# Rename V4L2_ASYNC_MATCH_FWNODE to V4L2_ASYNC_MATCH_TYPE_FWNODE
subdir-ccflags-y += -DNV_V4L2_ASYNC_MATCH_FWNODE_RENAME

# Rename async_nf_init and v4l2_async_subdev_nf_register
subdir-ccflags-y += -DNV_V4L2_ASYNC_NF_SUBDEVICE_INIT_RENAME

# Deprecate PCIED Error reporting pci_enable_pcie_error_reporting
subdir-ccflags-y += -DNV_DROP_PCIE_ERROR_REPORTING

# Split types and declaration of net/page_pool.h
subdir-ccflags-y += -DNV_SPLIT_PAGE_POOL_HEADER

# Unexport helpers for fd/handle conversion
subdir-ccflags-y += -DNV_UNEXPORT_FD_HANDLE_CONVERSION

# FB Deferred IO helpers name alignment
subdir-ccflags-y += -DNV_FB_DEFERRED_IO_OPS_RENAME

# Crypto driver has major change in it ops, skip it
export CONFIG_SKIP_CRYPTO=y
endif

ifeq ($(CONFIG_TEGRA_VIRTUALIZATION),y)
subdir-ccflags-y += -DCONFIG_TEGRA_VIRTUALIZATION
endif

ifeq ($(CONFIG_TEGRA_SYSTEM_TYPE_ACK),y)
subdir-ccflags-y += -DCONFIG_TEGRA_SYSTEM_TYPE_ACK
subdir-ccflags-y += -Wno-sometimes-uninitialized
subdir-ccflags-y += -Wno-parentheses-equality
subdir-ccflags-y += -Wno-enum-conversion
subdir-ccflags-y += -Wno-implicit-fallthrough
endif

obj-m += drivers/

ifdef CONFIG_SND_SOC
obj-m += sound/soc/tegra/
obj-m += sound/tegra-safety-audio/
obj-m += sound/soc/tegra-virt-alt/
endif
