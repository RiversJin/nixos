// SPDX-License-Identifier: GPL-2.0-only
/*
 * PEX88096 B0 die temperature via the independent MPT_NO_SES endpoint.
 * Sensor sequence and conversion: Meta OpenBMC pal_get_pex_therm:
 * https://github.com/facebook/openbmc/blob/94594682123991e330709fd814b256f023f2ddcf/
 * meta-facebook/meta-fbep/recipes-fbep/plat-libs/files/pal/pal_switch.c
 * MPT diagnostic transport: Broadcom PCIe SDK PDE Atlas implementation.
 *
 * Each uncached read starts a new acquisition and restores the sensor and
 * diagnostic controls. Do not assume a latched sample refreshes itself.
 * Only BAR decoding stays enabled while this driver owns the endpoint.
 * No DMA, IRQs, firmware writes, CPU resets, or bridge control operations.
 */
#include <linux/delay.h>
#include <linux/hwmon.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/pm.h>

#define MPT_SEQUENCE       0x04
#define MPT_DIAGNOSTIC     0x08
#define MPT_DATA           0x10
#define MPT_ADDR_LOW       0x14
#define MPT_ADDR_HIGH      0x18
#define MPT_UNLOCKED       BIT(7)
#define MPT_AXI_ACCESS     BIT(4)
#define MPT_UNSAFE_STATE   (BIT(13) | BIT(2) | MPT_UNLOCKED | MPT_AXI_ACCESS)
#define CCR_CHIP_ID        0xfff00000
#define TEMP_CONTROL      0xffe78504
#define TEMP_STATUS        0xffe78538
#define TEMP_IDLE          0x000653e8
#define TEMP_SAMPLE        0x200653e8
#define SAMPLE_DELAY_MS    200
#define CACHE_INTERVAL_MS  1000

struct pex_temp {
	struct pci_dev *pdev;
	struct device *hwmon;
	void __iomem *bar;
	struct mutex lock;
	u16 original_command;
	bool suspended;
	bool valid;
	unsigned long updated;
	long temperature;
};

static void mpt_write(struct pex_temp *data, unsigned int reg, u32 value)
{
	writel(value, data->bar + reg);
	/* Flush posted PCI writes before changing the AXI window again. */
	readl(data->bar + MPT_ADDR_LOW);
}

static u32 axi_read(struct pex_temp *data, u32 address)
{
	mpt_write(data, MPT_ADDR_LOW, address);
	mpt_write(data, MPT_ADDR_HIGH, 0);
	return readl(data->bar + MPT_DATA);
}

static void axi_write(struct pex_temp *data, u32 address, u32 value)
{
	mpt_write(data, MPT_ADDR_LOW, address);
	mpt_write(data, MPT_ADDR_HIGH, 0);
	mpt_write(data, MPT_DATA, value);
}

/* Called under data->lock; restore the window on every exit after unlocking. */
static int pex_sample(struct pex_temp *data)
{
	static const u32 sequence[] = { 4, 11, 2, 7, 13 };
	u32 diagnostic, low, high, unlocked, status, control = 0;
	u16 command;
	bool sensor_changed = false;
	int ret = -EIO;
	unsigned int i;

	if (data->suspended || data->pdev->current_state != PCI_D0)
		return -EAGAIN;
	if (pci_channel_offline(data->pdev) ||
	    pci_read_config_word(data->pdev, PCI_COMMAND, &command))
		return -ENODEV;
	if (!(command & PCI_COMMAND_MEMORY) || (command & PCI_COMMAND_MASTER))
		return -EBUSY;
	diagnostic = readl(data->bar + MPT_DIAGNOSTIC);
	if (diagnostic == U32_MAX)
		return -ENODEV;
	if (diagnostic & MPT_UNSAFE_STATE)
		return -EBUSY;
	low = readl(data->bar + MPT_ADDR_LOW);
	high = readl(data->bar + MPT_ADDR_HIGH);
	for (i = 0; i < ARRAY_SIZE(sequence); i++)
		mpt_write(data, MPT_SEQUENCE, sequence[i]);
	unlocked = readl(data->bar + MPT_DIAGNOSTIC);
	if (!(unlocked & MPT_UNLOCKED) ||
	    ((unlocked ^ diagnostic) & ~MPT_UNLOCKED))
		goto restore_window;
	mpt_write(data, MPT_DIAGNOSTIC, unlocked | MPT_AXI_ACCESS);
	if ((readl(data->bar + MPT_DIAGNOSTIC) &
	     (MPT_UNLOCKED | MPT_AXI_ACCESS)) !=
	    (MPT_UNLOCKED | MPT_AXI_ACCESS))
		goto restore_window;
	if (axi_read(data, CCR_CHIP_ID) != 0xc0101000)
		goto restore_window;
	control = axi_read(data, TEMP_CONTROL);
	/* Preserve firmware or another manager's sensor configuration. */
	if (control != TEMP_IDLE) {
		ret = -EBUSY;
		goto restore_window;
	}
	sensor_changed = true;
	axi_write(data, TEMP_CONTROL, TEMP_SAMPLE);
	if (axi_read(data, TEMP_CONTROL) != TEMP_SAMPLE)
		goto restore_window;
	msleep(SAMPLE_DELAY_MS);
	if (pci_channel_offline(data->pdev)) {
		ret = -ENODEV;
		goto restore_window;
	}
	status = axi_read(data, TEMP_STATUS);
	/* Do not expose an empty or failed register read as a zero temperature. */
	if (status == U32_MAX || !(status & 0xffff) ||
	    (status & 0xffff) >= 150 * 128)
		goto restore_window;
	data->temperature = DIV_ROUND_CLOSEST((long)(status & 0xffff) * 1000, 128);
	ret = 0;
restore_window:
	if (pci_channel_offline(data->pdev))
		return -ENODEV;
	if (sensor_changed) {
		axi_write(data, TEMP_CONTROL, control);
		if (axi_read(data, TEMP_CONTROL) != control)
			ret = -EIO;
	}
	mpt_write(data, MPT_ADDR_LOW, low);
	mpt_write(data, MPT_ADDR_HIGH, high);
	mpt_write(data, MPT_DIAGNOSTIC, diagnostic);
	mpt_write(data, MPT_SEQUENCE, 0);
	if (readl(data->bar + MPT_DIAGNOSTIC) != diagnostic ||
	    readl(data->bar + MPT_ADDR_LOW) != low ||
	    readl(data->bar + MPT_ADDR_HIGH) != high)
		ret = -EIO;
	return ret;
}

static int pex_read(struct device *dev, enum hwmon_sensor_types type,
		    u32 attr, int channel, long *value)
{
	struct pex_temp *data = dev_get_drvdata(dev);
	int ret = 0;

	if (type == hwmon_chip && attr == hwmon_chip_update_interval) {
		*value = CACHE_INTERVAL_MS;
		return 0;
	}
	if (type != hwmon_temp || attr != hwmon_temp_input || channel)
		return -EOPNOTSUPP;
	mutex_lock(&data->lock);
	if (data->suspended) {
		ret = -EAGAIN;
		goto out;
	}
	if (!data->valid || time_after_eq(jiffies, data->updated +
				msecs_to_jiffies(CACHE_INTERVAL_MS))) {
		data->valid = false;
		ret = pex_sample(data);
		if (ret)
			goto out;
		data->updated = jiffies;
		data->valid = true;
	}
	*value = data->temperature;
out:
	mutex_unlock(&data->lock);
	return ret;
}

static int pex_read_string(struct device *dev, enum hwmon_sensor_types type,
			   u32 attr, int channel, const char **value)
{
	if (type != hwmon_temp || attr != hwmon_temp_label || channel)
		return -EOPNOTSUPP;
	*value = "PEX88096 die";
	return 0;
}

static umode_t pex_is_visible(const void *data, enum hwmon_sensor_types type,
			     u32 attr, int channel)
{
	if (type == hwmon_chip && attr == hwmon_chip_update_interval)
		return 0444;
	if (type == hwmon_temp && !channel &&
	    (attr == hwmon_temp_input || attr == hwmon_temp_label))
		return 0444;
	return 0;
}

static const struct hwmon_ops pex_ops = {
	.is_visible = pex_is_visible,
	.read = pex_read,
	.read_string = pex_read_string,
};

static const struct hwmon_channel_info * const pex_info[] = {
	HWMON_CHANNEL_INFO(chip, HWMON_C_UPDATE_INTERVAL),
	HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT | HWMON_T_LABEL),
	NULL,
};

static const struct hwmon_chip_info pex_chip_info = {
	.ops = &pex_ops,
	.info = pex_info,
};

static int pex_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct pex_temp *data;
	int ret;

	/* Only this management EP qualifies; bridge functions share device c010. */
	if (pdev->revision != 0xb0 || pdev->class != 0x018000 ||
	    !(pci_resource_flags(pdev, 0) & IORESOURCE_MEM) ||
	    pci_resource_len(pdev, 0) != 0x4000)
		return -ENODEV;
	data = devm_kzalloc(&pdev->dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->pdev = pdev;
	mutex_init(&data->lock);
	pci_set_drvdata(pdev, data);
	ret = pci_read_config_word(pdev, PCI_COMMAND, &data->original_command);
	if (ret)
		return -EIO;
	if (data->original_command & (PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER))
		return -EBUSY;
	ret = pci_enable_device_mem(pdev);
	if (ret)
		return ret;
	ret = pci_request_selected_regions_exclusive(pdev, BIT(0), "pex88096_hwmon");
	if (ret)
		goto disable;
	data->bar = pci_iomap(pdev, 0, 0x20);
	if (!data->bar) {
		ret = -ENOMEM;
		goto release;
	}
	ret = pex_sample(data);
	if (ret)
		goto unmap;
	data->valid = true;
	data->updated = jiffies;
	data->hwmon = hwmon_device_register_with_info(&pdev->dev, "pex88096",
						     data, &pex_chip_info, NULL);
	if (IS_ERR(data->hwmon)) {
		ret = PTR_ERR(data->hwmon);
		goto unmap;
	}
	dev_info(&pdev->dev, "internal die temperature registered (%ld mC)\n",
		 data->temperature);
	return 0;
unmap:
	pci_iounmap(pdev, data->bar);
release:
	pci_release_selected_regions(pdev, BIT(0));
disable:
	pci_disable_device(pdev);
	pci_write_config_word(pdev, PCI_COMMAND, data->original_command);
	return ret;
}

static void pex_remove(struct pci_dev *pdev)
{
	struct pex_temp *data = pci_get_drvdata(pdev);

	/* Drain sysfs readers before unmapping the BAR. */
	hwmon_device_unregister(data->hwmon);
	pci_iounmap(pdev, data->bar);
	pci_release_selected_regions(pdev, BIT(0));
	pci_disable_device(pdev);
	pci_write_config_word(pdev, PCI_COMMAND, data->original_command);
}

static int pex_suspend(struct device *dev)
{
	struct pex_temp *data = pci_get_drvdata(to_pci_dev(dev));

	mutex_lock(&data->lock);
	data->suspended = true;
	data->valid = false;
	mutex_unlock(&data->lock);
	return 0;
}

static int pex_resume(struct device *dev)
{
	struct pex_temp *data = pci_get_drvdata(to_pci_dev(dev));

	mutex_lock(&data->lock);
	data->valid = false;
	data->suspended = false;
	mutex_unlock(&data->lock);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(pex_pm_ops, pex_suspend, pex_resume);
static const struct pci_device_id pex_ids[] = {
	{ PCI_DEVICE_SUB(0x1000, 0xc010, 0x1000, 0x00b2) },
	{ }
};
MODULE_DEVICE_TABLE(pci, pex_ids);

static struct pci_driver pex_driver = {
	.name = "pex88096_hwmon",
	.id_table = pex_ids,
	.probe = pex_probe,
	.remove = pex_remove,
	.driver.pm = pm_sleep_ptr(&pex_pm_ops),
};
module_pci_driver(pex_driver);
MODULE_DESCRIPTION("Broadcom PEX88096 B0 internal die temperature via MPT");
MODULE_LICENSE("GPL");
