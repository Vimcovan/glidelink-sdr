// SPDX-License-Identifier: GPL-2.0
/*
 * GlideLink shell register block (hw/library/glidelink_shell) as an IIO
 * device "glidelink-shell". libiio reaches the shell registers, locally or
 * through iiod, with iio_device_reg_read() / iio_device_reg_write()
 * (debugfs direct_reg_access, byte offsets into the 64 KB window), and the
 * 64-bit sample counter as the device attribute "timestamp" (write to set it).
 */

#include <linux/delay.h>
#include <linux/iio/iio.h>
#include <linux/iio/sysfs.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>

#define SHELL_ID		0x000
#define SHELL_VERSION		0x004
#define SHELL_CAPS		0x008
#define SHELL_TIME_LO		0x010	/* reading it latches TIME_HI */
#define SHELL_TIME_HI		0x014
#define SHELL_TIME_SET_LO	0x018
#define SHELL_TIME_SET_HI	0x01C
#define SHELL_TIME_CTRL		0x020	/* bit 0: load TIME_SET / load pending */

#define SHELL_ID_VALUE		0x474C4B53	/* "GLKS" */
#define SHELL_WINDOW		0x10000

struct glidelink_shell {
	void __iomem *base;
	struct mutex lock;	/* TIME_LO / TIME_HI and TIME_SET / TIME_CTRL pairs */
};

static int glidelink_shell_reg_access(struct iio_dev *indio_dev, unsigned int reg,
				      unsigned int writeval, unsigned int *readval)
{
	struct glidelink_shell *st = iio_priv(indio_dev);

	if (reg >= SHELL_WINDOW || reg & 3)
		return -EINVAL;

	mutex_lock(&st->lock);
	if (readval)
		*readval = readl(st->base + reg);
	else
		writel(writeval, st->base + reg);
	mutex_unlock(&st->lock);

	return 0;
}

static ssize_t timestamp_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct glidelink_shell *st = iio_priv(dev_to_iio_dev(dev));
	u32 lo, hi;

	mutex_lock(&st->lock);
	lo = readl(st->base + SHELL_TIME_LO);
	hi = readl(st->base + SHELL_TIME_HI);
	mutex_unlock(&st->lock);

	return sysfs_emit(buf, "%llu\n", ((u64)hi << 32) | lo);
}

static ssize_t timestamp_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t len)
{
	struct glidelink_shell *st = iio_priv(dev_to_iio_dev(dev));
	unsigned int tries;
	u64 val;
	int ret;

	ret = kstrtou64(buf, 0, &val);
	if (ret)
		return ret;

	mutex_lock(&st->lock);
	writel(lower_32_bits(val), st->base + SHELL_TIME_SET_LO);
	writel(upper_32_bits(val), st->base + SHELL_TIME_SET_HI);
	writel(1, st->base + SHELL_TIME_CTRL);
	/* the load happens at the next sample; without samples it stays pending */
	for (tries = 0; tries < 100 && (readl(st->base + SHELL_TIME_CTRL) & 1); tries++)
		udelay(1);
	mutex_unlock(&st->lock);

	return tries < 100 ? len : -ETIMEDOUT;
}

static IIO_DEVICE_ATTR_RW(timestamp, 0);

static struct attribute *glidelink_shell_attrs[] = {
	&iio_dev_attr_timestamp.dev_attr.attr,
	NULL
};

static const struct attribute_group glidelink_shell_group = {
	.attrs = glidelink_shell_attrs,
};

static const struct iio_info glidelink_shell_info = {
	.attrs = &glidelink_shell_group,
	.debugfs_reg_access = glidelink_shell_reg_access,
};

static int glidelink_shell_probe(struct platform_device *pdev)
{
	struct glidelink_shell *st;
	struct iio_dev *indio_dev;
	u32 id, version, caps;

	indio_dev = devm_iio_device_alloc(&pdev->dev, sizeof(*st));
	if (!indio_dev)
		return -ENOMEM;

	st = iio_priv(indio_dev);
	mutex_init(&st->lock);
	st->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(st->base))
		return PTR_ERR(st->base);

	id = readl(st->base + SHELL_ID);
	if (id != SHELL_ID_VALUE)
		return dev_err_probe(&pdev->dev, -ENODEV, "unexpected ID 0x%08x\n", id);
	version = readl(st->base + SHELL_VERSION);
	caps = readl(st->base + SHELL_CAPS);

	indio_dev->name = "glidelink-shell";
	indio_dev->modes = INDIO_DIRECT_MODE;
	indio_dev->info = &glidelink_shell_info;

	dev_info(&pdev->dev, "GlideLink shell %u.%u.%u: %u RF channel(s), %u/%u host RX/TX port(s), %u slot(s)\n",
		 version >> 16, (version >> 8) & 0xff, version & 0xff,
		 caps & 0xff, (caps >> 8) & 0xff, (caps >> 16) & 0xff, caps >> 24);

	return devm_iio_device_register(&pdev->dev, indio_dev);
}

static const struct of_device_id glidelink_shell_of_match[] = {
	{ .compatible = "glidelink,shell-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, glidelink_shell_of_match);

static struct platform_driver glidelink_shell_driver = {
	.driver = {
		.name = "glidelink-shell",
		.of_match_table = glidelink_shell_of_match,
	},
	.probe = glidelink_shell_probe,
};
module_platform_driver(glidelink_shell_driver);

MODULE_DESCRIPTION("GlideLink SDR shell registers");
MODULE_LICENSE("GPL");
