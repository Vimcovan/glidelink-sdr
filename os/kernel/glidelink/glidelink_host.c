// SPDX-License-Identifier: GPL-2.0
/*
 * GlideLink host port (shell host port 1 and up): its two DMAs as IIO buffer
 * devices "<name>-rx" (input) and "<name>-tx" (output), each with one 32-bit
 * channel, so libiio streams the port locally or through iiod. The words are
 * whatever the shell's stream carries (samples {Q, I}, or packet headers and
 * samples, docs/phase1_shell.md); routes and header mode are set through the
 * glidelink-shell device.
 *
 * Device tree: compatible "glidelink,host-port-1.0", dmas / dma-names "rx" and
 * "tx"; the device name is "glidelink-host<N>" with N from the node's
 * "glidelink,port" property (default 1).
 */

#include <linux/iio/buffer-dmaengine.h>
#include <linux/iio/buffer.h>
#include <linux/iio/iio.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>

static const struct iio_chan_spec glidelink_host_rx_chan = {
	.type = IIO_VOLTAGE,
	.indexed = 1,
	.channel = 0,
	.scan_index = 0,
	.scan_type = { .sign = 'u', .realbits = 32, .storagebits = 32, .endianness = IIO_LE },
};

static const struct iio_chan_spec glidelink_host_tx_chan = {
	.type = IIO_VOLTAGE,
	.indexed = 1,
	.output = 1,
	.channel = 0,
	.scan_index = 0,
	.scan_type = { .sign = 'u', .realbits = 32, .storagebits = 32, .endianness = IIO_LE },
};

static const struct iio_info glidelink_host_info = {};

static int glidelink_host_add(struct device *dev, const char *name, const char *dma,
			      const struct iio_chan_spec *chan, enum iio_buffer_direction dir)
{
	struct iio_dev *indio_dev;
	int ret;

	indio_dev = devm_iio_device_alloc(dev, 0);
	if (!indio_dev)
		return -ENOMEM;

	indio_dev->name = name;
	indio_dev->modes = INDIO_BUFFER_HARDWARE;
	indio_dev->info = &glidelink_host_info;
	indio_dev->channels = chan;
	indio_dev->num_channels = 1;

	ret = devm_iio_dmaengine_buffer_setup_ext(dev, indio_dev, dma, dir);
	if (ret)
		return dev_err_probe(dev, ret, "cannot set up the %s DMA buffer\n", dma);

	return devm_iio_device_register(dev, indio_dev);
}

static int glidelink_host_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	const char *rx_name, *tx_name;
	u32 port = 1;
	int ret;

	device_property_read_u32(dev, "glidelink,port", &port);
	rx_name = devm_kasprintf(dev, GFP_KERNEL, "glidelink-host%u-rx", port);
	tx_name = devm_kasprintf(dev, GFP_KERNEL, "glidelink-host%u-tx", port);
	if (!rx_name || !tx_name)
		return -ENOMEM;

	ret = glidelink_host_add(dev, rx_name, "rx", &glidelink_host_rx_chan, IIO_BUFFER_DIRECTION_IN);
	if (ret)
		return ret;
	ret = glidelink_host_add(dev, tx_name, "tx", &glidelink_host_tx_chan, IIO_BUFFER_DIRECTION_OUT);
	if (ret)
		return ret;

	dev_info(dev, "GlideLink host port %u\n", port);
	return 0;
}

static const struct of_device_id glidelink_host_of_match[] = {
	{ .compatible = "glidelink,host-port-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, glidelink_host_of_match);

static struct platform_driver glidelink_host_driver = {
	.driver = {
		.name = "glidelink-host",
		.of_match_table = glidelink_host_of_match,
	},
	.probe = glidelink_host_probe,
};
module_platform_driver(glidelink_host_driver);

MODULE_DESCRIPTION("GlideLink SDR host port DMA buffers");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS(IIO_DMAENGINE_BUFFER);
