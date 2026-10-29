// Host port 1 loop through slot 0 (docs/phase1_shell.md step 1.5), bit-exact, raw:
// host 1 TX -> slot 0 -> host 1 RX. Not tied to the sample clock, so it runs as fast
// as the DMAs go; run it next to ramp_loopback_iio to load both host ports at once.
//
// TX sends a 32-bit counter running across buffers; RX checks every word is the
// previous one + 1.
//
//   gcc -O2 -o host1_loop_iio host1_loop_iio.c -liio -lpthread
//   ./host1_loop_iio [seconds] [buffer_words] [MB/s limit for TX, 0 = none]

#include <iio.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static struct iio_buffer *txbuf;
static volatile int stop;
static long tx_buffers;
static double tx_limit;              // bytes per second, 0 = as fast as the DMA goes

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static void *tx_loop(void *arg)
{
	uint32_t n = 0;
	double t0 = now();

	(void)arg;
	while (!stop) {
		size_t bytes = (char *)iio_buffer_end(txbuf) - (char *)iio_buffer_start(txbuf);
		while (tx_limit > 0 && !stop && tx_buffers * bytes > (now() - t0) * tx_limit) {
			struct timespec d = { 0, 200000 };
			nanosleep(&d, NULL);
		}
		for (uint32_t *p = iio_buffer_start(txbuf); p < (uint32_t *)iio_buffer_end(txbuf); p++)
			*p = n++;
		if (iio_buffer_push(txbuf) < 0) {
			perror("TX push");
			break;
		}
		tx_buffers++;
	}
	return NULL;
}

int main(int argc, char **argv)
{
	double seconds = argc > 1 ? atof(argv[1]) : 10;
	size_t len = argc > 2 ? atol(argv[2]) : 65536;
	tx_limit = argc > 3 ? atof(argv[3]) * 1e6 : 0;

	struct iio_context *ctx = iio_create_local_context();
	struct iio_device *shell = iio_context_find_device(ctx, "glidelink-shell");
	struct iio_device *rx = iio_context_find_device(ctx, "glidelink-host1-rx");
	struct iio_device *tx = iio_context_find_device(ctx, "glidelink-host1-tx");
	if (!shell || !rx || !tx) {
		fprintf(stderr, "glidelink-shell / glidelink-host1-rx / -tx not found\n");
		return 1;
	}

	// raw host port 1, routes slot 0 in <- host 1 TX, host 1 RX <- slot 0 out,
	// flush host port 1 and slot 0
	uint32_t cfg;
	iio_device_reg_read(shell, 0x054, &cfg);
	iio_device_reg_write(shell, 0x054, cfg & ~0x30u);
	iio_device_reg_write(shell, 0x1008, 3);
	iio_device_reg_write(shell, 0x100C, 2);
	iio_device_reg_write(shell, 0x05C, 0x1C);

	iio_channel_enable(iio_device_find_channel(rx, "voltage0", false));
	iio_channel_enable(iio_device_find_channel(tx, "voltage0", true));
	struct iio_buffer *rxbuf = iio_device_create_buffer(rx, len, false);
	txbuf = iio_device_create_buffer(tx, len, false);
	if (!txbuf || !rxbuf) {
		perror("create buffer");
		return 1;
	}

	pthread_t th;
	pthread_create(&th, NULL, tx_loop, NULL);

	long long words = 0, errors = 0, refills = 0;
	int have_prev = 0;
	uint32_t prev = 0;
	double t0 = now();
	while (now() - t0 < seconds) {
		if (iio_buffer_refill(rxbuf) < 0) {
			perror("RX refill");
			break;
		}
		refills++;
		for (const uint32_t *p = iio_buffer_start(rxbuf); p < (uint32_t *)iio_buffer_end(rxbuf); p++, words++) {
			if (have_prev && *p != prev + 1)
				errors++;
			prev = *p;
			have_prev = 1;
		}
	}
	double dt = now() - t0;
	stop = 1;
	pthread_join(th, NULL);

	iio_buffer_destroy(rxbuf);
	iio_buffer_destroy(txbuf);
	iio_device_reg_write(shell, 0x1008, 0xF);
	iio_device_reg_write(shell, 0x100C, 0xF);
	printf("host 1 loop through slot 0: %.1f MB/s over %.1f s (%lld buffers of %zu words), %ld TX buffers: "
	       "steps != 1: %lld\n", words * 4 / dt / 1e6, dt, refills, len, tx_buffers, errors);
	iio_context_destroy(ctx);
	return 0;
}
