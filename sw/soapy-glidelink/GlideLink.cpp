// SoapySDR module for the GlideLink platform (PYNQ-ZU + AD9361 FMC card).
//
// Talks to the ADI ad9361 / cf_axi_adc / cf_axi_dds drivers through libiio,
// either on the board (uri=local:, the default) or from a PC through the
// board's iiod (uri=ip:<board>).
//
// Phase 0 scope: standard parameters (frequency, sample rate, bandwidth, gain,
// antenna), RX / TX streams in CS16 and CF32, and raw AD9361 register access.
// CS16 is the AD9361's 12-bit sample with full scale 2048 in both directions.

#include <SoapySDR/Device.hpp>
#include <SoapySDR/Formats.hpp>
#include <SoapySDR/Logger.hpp>
#include <SoapySDR/Registry.hpp>
#include <SoapySDR/Time.hpp>
#include <iio.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

const char *PHY_NAME = "ad9361-phy";
const char *RX_NAME = "cf-ad9361-lpc";
const char *TX_NAME = "cf-ad9361-dds-core-lpc";
const char *SHELL_NAME = "glidelink-shell";    // PL shell registers, optional

const size_t DEFAULT_BUFFER_LENGTH = 65536;    // samples per IIO buffer; 4 queued = 5 ms at 50 MSPS
// Highest sample rate: on the third-party AD9361 card the TX data interface is
// only bit-exact up to 50 MSPS (pairs D4/D5, hw/dts/fmcomms2_pynqzu.dtso)
const double MAX_SAMPLE_RATE = 50e6;
const unsigned DEFAULT_TIMEOUT_MS = 1000;
const double TX_ATTEN_MAX = 89.75;             // dB, TX gain = 89.75 + hardwaregain

std::string chanName(size_t i) { return "voltage" + std::to_string(i); }

struct Stream {
	int direction;
	bool cf32;
	std::vector<size_t> channels;   // user order
	std::vector<size_t> slot;       // position of channels[i] in the buffer's sample
	size_t numSlots = 0;
	size_t bufferLength = DEFAULT_BUFFER_LENGTH;
	iio_device *dev = nullptr;
	iio_buffer *buf = nullptr;
	size_t pos = 0;                 // samples consumed (RX) / filled (TX) in buf
	size_t avail = 0;               // RX: samples in buf

	// packet headers on host port 0 (shell >= 1.1, docs/phase1_shell.md D4)
	bool headers = false;
	double rate = 0;                // sample rate when the stream was activated
	unsigned hdrPos = 0;            // RX: header words taken of the current packet (4 = samples)
	uint32_t hdr[4] = {0, 0, 0, 0};
	size_t pktLeft = 0;             // RX: samples left in the current packet
	uint64_t pktTime = 0;           // RX: sample counter of the next sample
	bool overflow = false;          // RX: report an overflow before the next samples
	bool firstPacket = true;        // RX: drops before the stream started are not its overflow
	uint32_t seq = 0;               // TX: packet sequence number
};

const uint32_t HDR_MAGIC = 0xA5;
const uint32_t FLAG_RX_DROPPED = 1u << 0, FLAG_TX_TIMED = 1u << 0, FLAG_TX_EOB = 1u << 1;
const unsigned SHELL_VERSION_HEADERS = 0x00010100;
// shell registers (hw/library/glidelink_shell/glidelink_shell_regs.v)
const unsigned REG_VERSION = 0x004, REG_CONFIG = 0x054, REG_PORT_RESET = 0x05C, REG_ROUTE = 0x1000;
const unsigned PORT_RESET_HOST0_RX = 1u << 0, PORT_RESET_HOST0_TX = 1u << 1;
const unsigned CFG_RX_ENABLE = 1u << 0, CFG_HOST0_RX_HDR = 1u << 2, CFG_HOST0_TX_HDR = 1u << 3;
const unsigned SINK_RF_TX = 0, SINK_HOST0_RX = 1, SRC_RF_RX = 0, SRC_HOST0_TX = 1, ROUTE_NONE = 0xF;

class GlideLink : public SoapySDR::Device {
public:
	explicit GlideLink(const SoapySDR::Kwargs &args)
	{
		auto it = args.find("uri");
		uri = it != args.end() ? it->second : "local:";
		ctx = iio_create_context_from_uri(uri.c_str());
		if (!ctx)
			throw std::runtime_error("GlideLink: cannot open IIO context " + uri);
		phy = iio_context_find_device(ctx, PHY_NAME);
		rxDev = iio_context_find_device(ctx, RX_NAME);
		txDev = iio_context_find_device(ctx, TX_NAME);
		if (!phy || !rxDev || !txDev) {
			iio_context_destroy(ctx);
			throw std::runtime_error("GlideLink: AD9361 IIO devices not found at " + uri);
		}
		shell = iio_context_find_device(ctx, SHELL_NAME);
		iio_context_set_timeout(ctx, DEFAULT_TIMEOUT_MS);
	}

	~GlideLink() override { iio_context_destroy(ctx); }

	// identification

	std::string getDriverKey() const override { return "GlideLink"; }
	std::string getHardwareKey() const override { return "AD9361"; }

	SoapySDR::Kwargs getHardwareInfo() const override
	{
		SoapySDR::Kwargs info;
		info["uri"] = uri;
		for (unsigned i = 0; i < iio_context_get_attrs_count(ctx); i++) {
			const char *name, *value;
			if (iio_context_get_attr(ctx, i, &name, &value) == 0)
				info[name] = value;
		}
		return info;
	}

	// channels

	size_t getNumChannels(const int dir) const override
	{
		// with the shell, only the RF channels it streams (CAPS[7:0]) reach the DMAs
		if (shell) {
			uint32_t caps = 0;
			std::lock_guard<std::mutex> lock(mutex);
			if (iio_device_reg_read(shell, 0x008, &caps) == 0)
				return caps & 0xff;
		}
		iio_device *dev = dir == SOAPY_SDR_RX ? rxDev : txDev;
		size_t n = 0;
		while (iio_device_find_channel(dev, chanName(2 * n + 1).c_str(), dir == SOAPY_SDR_TX))
			n++;
		return n;
	}

	bool getFullDuplex(const int, const size_t) const override { return true; }

	// antennas

	std::vector<std::string> listAntennas(const int dir, const size_t ch) const override
	{
		std::string s = readAttr(phyChan(dir, ch), "rf_port_select_available");
		std::vector<std::string> names;
		size_t p = 0;
		while (p < s.size()) {
			size_t q = s.find(' ', p);
			if (q == std::string::npos)
				q = s.size();
			if (q > p)
				names.push_back(s.substr(p, q - p));
			p = q + 1;
		}
		return names;
	}

	void setAntenna(const int dir, const size_t ch, const std::string &name) override
	{
		writeAttr(phyChan(dir, ch), "rf_port_select", name);
	}

	std::string getAntenna(const int dir, const size_t ch) const override
	{
		return readAttr(phyChan(dir, ch), "rf_port_select");
	}

	// gain

	bool hasGainMode(const int dir, const size_t) const override { return dir == SOAPY_SDR_RX; }

	void setGainMode(const int dir, const size_t ch, const bool automatic) override
	{
		if (dir == SOAPY_SDR_RX)
			writeAttr(phyChan(dir, ch), "gain_control_mode", automatic ? "slow_attack" : "manual");
	}

	bool getGainMode(const int dir, const size_t ch) const override
	{
		return dir == SOAPY_SDR_RX && readAttr(phyChan(dir, ch), "gain_control_mode") != "manual";
	}

	std::vector<std::string> listGains(const int, const size_t) const override { return {"PGA"}; }

	void setGain(const int dir, const size_t ch, const double value) override
	{
		setGain(dir, ch, "PGA", value);
	}

	void setGain(const int dir, const size_t ch, const std::string &, const double value) override
	{
		double hw = dir == SOAPY_SDR_RX ? value : value - TX_ATTEN_MAX;
		writeDouble(phyChan(dir, ch), "hardwaregain", hw);
	}

	double getGain(const int dir, const size_t ch) const override { return getGain(dir, ch, "PGA"); }

	double getGain(const int dir, const size_t ch, const std::string &) const override
	{
		double hw = readDouble(phyChan(dir, ch), "hardwaregain");
		return dir == SOAPY_SDR_RX ? hw : hw + TX_ATTEN_MAX;
	}

	SoapySDR::Range getGainRange(const int dir, const size_t ch) const override
	{
		return getGainRange(dir, ch, "PGA");
	}

	SoapySDR::Range getGainRange(const int dir, const size_t ch, const std::string &) const override
	{
		SoapySDR::Range r = readRange(phyChan(dir, ch), "hardwaregain_available");
		if (dir == SOAPY_SDR_RX)
			return r;
		return SoapySDR::Range(r.minimum() + TX_ATTEN_MAX, r.maximum() + TX_ATTEN_MAX, r.step());
	}

	// frequency (RX and TX each have one LO shared by both channels)

	void setFrequency(const int dir, const size_t, const std::string &, const double frequency,
			  const SoapySDR::Kwargs &) override
	{
		writeLongLong(loChan(dir), "frequency", llround(frequency));
	}

	double getFrequency(const int dir, const size_t, const std::string &) const override
	{
		return readDouble(loChan(dir), "frequency");
	}

	std::vector<std::string> listFrequencies(const int, const size_t) const override { return {"RF"}; }

	SoapySDR::RangeList getFrequencyRange(const int dir, const size_t, const std::string &) const override
	{
		return {readRange(loChan(dir), "frequency_available")};
	}

	// sample rate (one rate for RX and TX)

	void setSampleRate(const int dir, const size_t ch, const double rate) override
	{
		if (rate > MAX_SAMPLE_RATE)
			throw std::runtime_error("GlideLink: sample rate above " +
						 std::to_string(llround(MAX_SAMPLE_RATE)) + " S/s");
		writeLongLong(phyChan(dir, ch), "sampling_frequency", llround(rate));
	}

	double getSampleRate(const int dir, const size_t ch) const override
	{
		return readDouble(phyChan(dir, ch), "sampling_frequency");
	}

	SoapySDR::RangeList getSampleRateRange(const int dir, const size_t ch) const override
	{
		SoapySDR::Range r = readRange(phyChan(dir, ch), "sampling_frequency_available");
		return {SoapySDR::Range(r.minimum(), std::min(r.maximum(), MAX_SAMPLE_RATE), r.step())};
	}

	std::vector<double> listSampleRates(const int dir, const size_t ch) const override
	{
		SoapySDR::Range r = getSampleRateRange(dir, ch).front();
		std::vector<double> rates;
		for (double f : {2.5e6, 5e6, 10e6, 15.36e6, 20e6, 30.72e6, 40e6, 50e6})
			if (f >= r.minimum() && f <= r.maximum())
				rates.push_back(f);
		return rates;
	}

	// analog bandwidth

	void setBandwidth(const int dir, const size_t ch, const double bw) override
	{
		writeLongLong(phyChan(dir, ch), "rf_bandwidth", llround(bw));
	}

	double getBandwidth(const int dir, const size_t ch) const override
	{
		return readDouble(phyChan(dir, ch), "rf_bandwidth");
	}

	SoapySDR::RangeList getBandwidthRange(const int dir, const size_t ch) const override
	{
		return {readRange(phyChan(dir, ch), "rf_bandwidth_available")};
	}

	// registers: "AD9361" (SPI registers), "FPGA" (PL shell window, byte offsets)

	std::vector<std::string> listRegisterInterfaces() const override
	{
		if (shell)
			return {"AD9361", "FPGA"};
		return {"AD9361"};
	}

	void writeRegister(const std::string &name, const unsigned addr, const unsigned value) override
	{
		iio_device *dev = registerDevice(name);
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_device_reg_write(dev, addr, value) < 0)
			throw std::runtime_error("GlideLink: " + name + " register write failed");
	}

	unsigned readRegister(const std::string &name, const unsigned addr) const override
	{
		iio_device *dev = registerDevice(name);
		std::lock_guard<std::mutex> lock(mutex);
		uint32_t value = 0;
		if (iio_device_reg_read(dev, addr, &value) < 0)
			throw std::runtime_error("GlideLink: " + name + " register read failed");
		return value;
	}

	// time: the shell's sample counter (RF channel 0 samples) at the current sample rate

	bool hasHardwareTime(const std::string &what) const override { return shell && what.empty(); }

	long long getHardwareTime(const std::string &what) const override
	{
		checkTime(what);
		long long samples;
		{
			std::lock_guard<std::mutex> lock(mutex);
			if (iio_device_attr_read_longlong(shell, "timestamp", &samples) < 0)
				throw std::runtime_error("GlideLink: cannot read the sample counter");
		}
		return SoapySDR::ticksToTimeNs(samples, sampleRate());
	}

	void setHardwareTime(const long long timeNs, const std::string &what) override
	{
		checkTime(what);
		long long samples = SoapySDR::timeNsToTicks(timeNs, sampleRate());
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_device_attr_write_longlong(shell, "timestamp", samples) < 0)
			throw std::runtime_error("GlideLink: cannot set the sample counter");
	}

	// streams

	std::vector<std::string> getStreamFormats(const int, const size_t) const override
	{
		return {SOAPY_SDR_CS16, SOAPY_SDR_CF32};
	}

	std::string getNativeStreamFormat(const int, const size_t, double &fullScale) const override
	{
		fullScale = 2048;
		return SOAPY_SDR_CS16;
	}

	SoapySDR::ArgInfoList getStreamArgsInfo(const int, const size_t) const override
	{
		SoapySDR::ArgInfo len;
		len.key = "bufferLength";
		len.value = std::to_string(DEFAULT_BUFFER_LENGTH);
		len.name = "Buffer length";
		len.description = "Samples per IIO buffer (one DMA transfer).";
		len.type = SoapySDR::ArgInfo::INT;
		SoapySDR::ArgInfo hdr;
		hdr.key = "headers";
		hdr.value = "true";
		hdr.name = "Packet headers";
		hdr.description = "Timestamps and burst flags through the shell's packet headers "
				  "(shell 1.1 and later); off gives raw samples.";
		hdr.type = SoapySDR::ArgInfo::BOOL;
		return {len, hdr};
	}

	SoapySDR::Stream *setupStream(const int dir, const std::string &format,
				      const std::vector<size_t> &channels,
				      const SoapySDR::Kwargs &args) override
	{
		if (format != SOAPY_SDR_CS16 && format != SOAPY_SDR_CF32)
			throw std::runtime_error("GlideLink: unsupported stream format " + format);
		auto *s = new Stream;
		s->direction = dir;
		s->cf32 = format == SOAPY_SDR_CF32;
		s->channels = channels.empty() ? std::vector<size_t>{0} : channels;
		s->dev = dir == SOAPY_SDR_RX ? rxDev : txDev;
		auto it = args.find("bufferLength");
		if (it != args.end())
			s->bufferLength = std::stoul(it->second);
		it = args.find("headers");
		s->headers = shell && readRegister("FPGA", REG_VERSION) >= SHELL_VERSION_HEADERS &&
			     (it == args.end() || it->second != "false") && s->channels.size() == 1 &&
			     s->channels[0] == 0;

		size_t n = getNumChannels(dir);
		std::vector<size_t> sorted = s->channels;
		std::sort(sorted.begin(), sorted.end());
		for (size_t c : s->channels) {
			if (c >= n) {
				delete s;
				throw std::runtime_error("GlideLink: no channel " + std::to_string(c));
			}
			s->slot.push_back(std::lower_bound(sorted.begin(), sorted.end(), c) - sorted.begin());
		}
		s->numSlots = sorted.size();

		bool output = dir == SOAPY_SDR_TX;
		for (size_t c = 0; c < n; c++) {
			bool on = std::find(sorted.begin(), sorted.end(), c) != sorted.end();
			for (size_t k = 0; k < 2; k++) {
				iio_channel *chn = iio_device_find_channel(s->dev, chanName(2 * c + k).c_str(), output);
				if (on)
					iio_channel_enable(chn);
				else
					iio_channel_disable(chn);
			}
		}
		return reinterpret_cast<SoapySDR::Stream *>(s);
	}

	void closeStream(SoapySDR::Stream *stream) override
	{
		Stream *s = reinterpret_cast<Stream *>(stream);
		stopBuffer(s);
		delete s;
	}

	size_t getStreamMTU(SoapySDR::Stream *stream) const override
	{
		return reinterpret_cast<Stream *>(stream)->bufferLength;
	}

	int activateStream(SoapySDR::Stream *stream, const int flags, const long long, const size_t) override
	{
		if (flags != 0)
			return SOAPY_SDR_NOT_SUPPORTED;
		Stream *s = reinterpret_cast<Stream *>(stream);
		if (s->buf)
			return 0;
		s->rate = sampleRate();
		s->hdrPos = 0;
		s->pktLeft = 0;
		s->overflow = false;
		s->firstPacket = true;
		// RX: hold the RX streamer off until the DMA has its buffers queued, so
		// the stream neither starts with a drop nor with samples from before it
		bool gateRx = s->headers && s->direction == SOAPY_SDR_RX;
		if (gateRx)
			setRxEnable(false);
		setPortHeaders(s, s->headers);
		s->buf = iio_device_create_buffer(s->dev, s->bufferLength, false);
		if (gateRx)
			setRxEnable(true);
		if (!s->buf) {
			SoapySDR::logf(SOAPY_SDR_ERROR, "GlideLink: cannot create IIO buffer (%s)", strerror(errno));
			return SOAPY_SDR_STREAM_ERROR;
		}
		s->pos = s->avail = 0;
		return 0;
	}

	int deactivateStream(SoapySDR::Stream *stream, const int flags, const long long) override
	{
		if (flags != 0)
			return SOAPY_SDR_NOT_SUPPORTED;
		Stream *s = reinterpret_cast<Stream *>(stream);
		stopBuffer(s);
		if (s->headers)
			setPortHeaders(s, false);     // raw again for tools that do not know the headers
		return 0;
	}

	int readStream(SoapySDR::Stream *stream, void *const *buffs, const size_t numElems, int &flags,
		       long long &timeNs, const long) override
	{
		Stream *s = reinterpret_cast<Stream *>(stream);
		flags = 0;
		timeNs = 0;
		if (!s->buf)
			return SOAPY_SDR_STREAM_ERROR;
		if (s->headers)
			return readPackets(s, buffs[0], numElems, flags, timeNs);
		if (s->pos == s->avail) {
			int ret = refill(s);
			if (ret < 0)
				return ret;
		}
		size_t n = std::min(numElems, s->avail - s->pos);
		const int16_t *src = static_cast<const int16_t *>(iio_buffer_start(s->buf)) + 2 * s->numSlots * s->pos;
		for (size_t i = 0; i < s->channels.size(); i++) {
			const int16_t *p = src + 2 * s->slot[i];
			if (s->cf32) {
				float *dst = static_cast<float *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					dst[2 * j] = p[0] / 2048.0f;
					dst[2 * j + 1] = p[1] / 2048.0f;
				}
			} else {
				int16_t *dst = static_cast<int16_t *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					dst[2 * j] = p[0];
					dst[2 * j + 1] = p[1];
				}
			}
		}
		s->pos += n;
		if (s->pos < s->avail)
			flags |= SOAPY_SDR_MORE_FRAGMENTS;
		return n;
	}

	int writeStream(SoapySDR::Stream *stream, const void *const *buffs, const size_t numElems, int &flags,
			const long long timeNs, const long) override
	{
		Stream *s = reinterpret_cast<Stream *>(stream);
		if (!s->buf)
			return SOAPY_SDR_STREAM_ERROR;
		if (s->headers)
			return writePacket(s, buffs[0], numElems, flags, timeNs);
		size_t n = std::min(numElems, s->bufferLength - s->pos);
		int16_t *dst = static_cast<int16_t *>(iio_buffer_start(s->buf)) + 2 * s->numSlots * s->pos;
		for (size_t i = 0; i < s->channels.size(); i++) {
			int16_t *p = dst + 2 * s->slot[i];
			if (s->cf32) {
				const float *src = static_cast<const float *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					p[0] = toDac(std::lround(src[2 * j] * 2048.0f));
					p[1] = toDac(std::lround(src[2 * j + 1] * 2048.0f));
				}
			} else {
				const int16_t *src = static_cast<const int16_t *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					p[0] = toDac(src[2 * j]);
					p[1] = toDac(src[2 * j + 1]);
				}
			}
		}
		s->pos += n;
		bool endBurst = (flags & SOAPY_SDR_END_BURST) && n == numElems;
		if (s->pos == s->bufferLength || (endBurst && s->pos > 0)) {
			ssize_t ret = s->pos == s->bufferLength ? iio_buffer_push(s->buf)
								: iio_buffer_push_partial(s->buf, s->pos);
			s->pos = 0;
			if (ret < 0)
				return ret == -ETIMEDOUT ? SOAPY_SDR_TIMEOUT : SOAPY_SDR_STREAM_ERROR;
		}
		return n;
	}

private:
	// 12-bit sample, full scale 2048, into the DAC's MSB-aligned 16-bit word
	static int16_t toDac(long v)
	{
		return static_cast<int16_t>(std::max(-2048L, std::min(2047L, v)) * 16);
	}

	int refill(Stream *s)
	{
		ssize_t ret = iio_buffer_refill(s->buf);
		if (ret < 0)
			return ret == -ETIMEDOUT ? SOAPY_SDR_TIMEOUT : SOAPY_SDR_STREAM_ERROR;
		s->avail = ret / iio_buffer_step(s->buf);
		s->pos = 0;
		return 0;
	}

	// header mode: one channel, so one buffer word per sample or header word

	int readPackets(Stream *s, void *out, const size_t numElems, int &flags, long long &timeNs)
	{
		if (numElems == 0)
			return 0;
		for (;;) {
			if (s->hdrPos == 4 && s->overflow) {
				s->overflow = false;
				return SOAPY_SDR_OVERFLOW;        // the samples follow on the next call
			}
			if (s->pos == s->avail) {
				int ret = refill(s);
				if (ret < 0)
					return ret;
			}
			const uint32_t *w = static_cast<const uint32_t *>(iio_buffer_start(s->buf));
			while (s->hdrPos < 4 && s->pos < s->avail) {
				s->hdr[s->hdrPos++] = w[s->pos++];
				if (s->hdrPos == 1 && (s->hdr[0] >> 24 != HDR_MAGIC || (s->hdr[0] & 0xffff) == 0)) {
					SoapySDR::log(SOAPY_SDR_WARNING, "GlideLink: RX packet header lost, resynchronising");
					s->hdrPos = 0;
				}
				if (s->hdrPos == 4) {
					s->pktLeft = s->hdr[0] & 0xffff;
					s->pktTime = (uint64_t(s->hdr[3]) << 32) | s->hdr[2];
					if (((s->hdr[0] >> 16) & FLAG_RX_DROPPED) && !s->firstPacket)
						s->overflow = true;
					s->firstPacket = false;
				}
			}
			if (s->hdrPos < 4 || s->overflow)
				continue;
			size_t n = std::min(std::min(numElems, s->pktLeft), s->avail - s->pos);
			if (n == 0)
				continue;
			copyFromBuffer(s, out, w + s->pos, n);
			flags |= SOAPY_SDR_HAS_TIME;
			timeNs = SoapySDR::ticksToTimeNs(s->pktTime, s->rate);
			s->pktTime += n;
			s->pktLeft -= n;
			s->pos += n;
			if (s->pktLeft == 0)
				s->hdrPos = 0;
			else
				flags |= SOAPY_SDR_MORE_FRAGMENTS;
			return n;
		}
	}

	int writePacket(Stream *s, const void *in, const size_t numElems, const int flags, const long long timeNs)
	{
		if (s->bufferLength - s->pos < 5) {           // no room for a header and a sample
			int ret = pushBuffer(s);
			if (ret < 0)
				return ret;
		}
		size_t n = std::min(std::min(numElems, s->bufferLength - s->pos - 4), size_t(0xffff));
		bool eob = (flags & SOAPY_SDR_END_BURST) && n == numElems;
		uint32_t pf = ((flags & SOAPY_SDR_HAS_TIME) ? FLAG_TX_TIMED : 0) | (eob ? FLAG_TX_EOB : 0);
		uint64_t t = (flags & SOAPY_SDR_HAS_TIME) ? SoapySDR::timeNsToTicks(timeNs, s->rate) : 0;
		uint32_t *w = static_cast<uint32_t *>(iio_buffer_start(s->buf)) + s->pos;
		w[0] = (HDR_MAGIC << 24) | (pf << 16) | uint32_t(n);
		w[1] = s->seq++;
		w[2] = uint32_t(t);
		w[3] = uint32_t(t >> 32);
		copyToBuffer(s, w + 4, in, n);
		s->pos += 4 + n;
		if (eob || s->bufferLength - s->pos < 5) {
			int ret = pushBuffer(s);
			if (ret < 0)
				return ret;
		}
		return n;
	}

	int pushBuffer(Stream *s)
	{
		if (s->pos == 0)
			return 0;
		ssize_t ret = s->pos == s->bufferLength ? iio_buffer_push(s->buf)
							: iio_buffer_push_partial(s->buf, s->pos);
		s->pos = 0;
		if (ret < 0)
			return ret == -ETIMEDOUT ? SOAPY_SDR_TIMEOUT : SOAPY_SDR_STREAM_ERROR;
		return 0;
	}

	void copyFromBuffer(const Stream *s, void *out, const uint32_t *w, size_t n) const
	{
		const int16_t *p = reinterpret_cast<const int16_t *>(w);
		if (s->cf32) {
			float *dst = static_cast<float *>(out);
			for (size_t j = 0; j < 2 * n; j++)
				dst[j] = p[j] / 2048.0f;
		} else {
			std::memcpy(out, p, 4 * n);
		}
	}

	void copyToBuffer(const Stream *s, uint32_t *w, const void *in, size_t n) const
	{
		int16_t *p = reinterpret_cast<int16_t *>(w);
		if (s->cf32) {
			const float *src = static_cast<const float *>(in);
			for (size_t j = 0; j < 2 * n; j++)
				p[j] = toDac(std::lround(src[j] * 2048.0f));
		} else {
			const int16_t *src = static_cast<const int16_t *>(in);
			for (size_t j = 0; j < 2 * n; j++)
				p[j] = toDac(src[j]);
		}
	}

	void setRxEnable(bool on)
	{
		unsigned cfg = readRegister("FPGA", REG_CONFIG);
		writeRegister("FPGA", REG_CONFIG, on ? (cfg | CFG_RX_ENABLE) : (cfg & ~CFG_RX_ENABLE));
	}

	// Host port 0 is flushed and its header mode set while the port is idle:
	// a stream that was torn down can leave a packet cut off in the shell
	// (the DMA stops mid-transfer), which PORT_RESET clears; RX is unrouted
	// meanwhile, and the switch reconnects it at the start of a packet.
	void setPortHeaders(const Stream *s, bool on)
	{
		if (!shell || readRegister("FPGA", REG_VERSION) < SHELL_VERSION_HEADERS)
			return;
		unsigned bit = s->direction == SOAPY_SDR_RX ? CFG_HOST0_RX_HDR : CFG_HOST0_TX_HDR;
		unsigned cfg = readRegister("FPGA", REG_CONFIG);
		cfg = on ? (cfg | bit) : (cfg & ~bit);
		if (s->direction == SOAPY_SDR_RX) {
			writeRegister("FPGA", REG_ROUTE + 4 * SINK_HOST0_RX, ROUTE_NONE);
			writeRegister("FPGA", REG_PORT_RESET, PORT_RESET_HOST0_RX);
			writeRegister("FPGA", REG_CONFIG, cfg);
			writeRegister("FPGA", REG_ROUTE + 4 * SINK_HOST0_RX, SRC_RF_RX);
		} else {
			writeRegister("FPGA", REG_PORT_RESET, PORT_RESET_HOST0_TX);
			writeRegister("FPGA", REG_CONFIG, cfg);
			writeRegister("FPGA", REG_ROUTE + 4 * SINK_RF_TX, SRC_HOST0_TX);
		}
	}

	void stopBuffer(Stream *s)
	{
		if (!s->buf)
			return;
		if (s->direction == SOAPY_SDR_TX && s->pos > 0)
			iio_buffer_push_partial(s->buf, s->pos);
		iio_buffer_destroy(s->buf);
		s->buf = nullptr;
		s->pos = s->avail = 0;
	}

	iio_channel *phyChan(const int dir, const size_t ch) const
	{
		iio_channel *chn = iio_device_find_channel(phy, chanName(ch).c_str(), dir == SOAPY_SDR_TX);
		if (!chn)
			throw std::runtime_error("GlideLink: no channel " + std::to_string(ch));
		return chn;
	}

	iio_channel *loChan(const int dir) const
	{
		return iio_device_find_channel(phy, dir == SOAPY_SDR_RX ? "altvoltage0" : "altvoltage1", true);
	}

	iio_device *registerDevice(const std::string &name) const
	{
		if (name == "AD9361")
			return phy;
		if (name == "FPGA" && shell)
			return shell;
		throw std::runtime_error("GlideLink: unknown register interface " + name);
	}

	void checkTime(const std::string &what) const
	{
		if (!shell || !what.empty())
			throw std::runtime_error("GlideLink: no hardware time \"" + what + "\"");
	}

	double sampleRate() const { return readDouble(phyChan(SOAPY_SDR_RX, 0), "sampling_frequency"); }

	std::string readAttr(iio_channel *chn, const char *attr) const
	{
		char buf[1024];
		std::lock_guard<std::mutex> lock(mutex);
		ssize_t ret = iio_channel_attr_read(chn, attr, buf, sizeof(buf));
		if (ret < 0)
			throw std::runtime_error(std::string("GlideLink: cannot read ") + attr);
		return buf;
	}

	void writeAttr(iio_channel *chn, const char *attr, const std::string &value)
	{
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_channel_attr_write(chn, attr, value.c_str()) < 0)
			throw std::runtime_error(std::string("GlideLink: cannot write ") + attr + " = " + value);
	}

	double readDouble(iio_channel *chn, const char *attr) const
	{
		return std::stod(readAttr(chn, attr));
	}

	void writeDouble(iio_channel *chn, const char *attr, double value)
	{
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_channel_attr_write_double(chn, attr, value) < 0)
			throw std::runtime_error(std::string("GlideLink: cannot write ") + attr);
	}

	void writeLongLong(iio_channel *chn, const char *attr, long long value)
	{
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_channel_attr_write_longlong(chn, attr, value) < 0)
			throw std::runtime_error(std::string("GlideLink: cannot write ") + attr);
	}

	// "[min step max]" as given by the *_available attributes
	SoapySDR::Range readRange(iio_channel *chn, const char *attr) const
	{
		double lo, step, hi;
		std::string s = readAttr(chn, attr);
		if (sscanf(s.c_str(), "[%lf %lf %lf]", &lo, &step, &hi) != 3)
			throw std::runtime_error(std::string("GlideLink: cannot parse ") + attr + ": " + s);
		return SoapySDR::Range(lo, hi, step);
	}

	std::string uri;
	iio_context *ctx = nullptr;
	iio_device *phy = nullptr, *rxDev = nullptr, *txDev = nullptr, *shell = nullptr;
	mutable std::mutex mutex;
};

SoapySDR::KwargsList findGlideLink(const SoapySDR::Kwargs &args)
{
	SoapySDR::Kwargs result;
	auto it = args.find("uri");
	result["uri"] = it != args.end() ? it->second : "local:";

	iio_context *ctx = iio_create_context_from_uri(result["uri"].c_str());
	if (!ctx)
		return {};
	bool found = iio_context_find_device(ctx, PHY_NAME) && iio_context_find_device(ctx, RX_NAME) &&
		     iio_context_find_device(ctx, TX_NAME);
	iio_context_destroy(ctx);
	if (!found)
		return {};
	result["label"] = "GlideLink AD9361 [" + result["uri"] + "]";
	return {result};
}

SoapySDR::Device *makeGlideLink(const SoapySDR::Kwargs &args) { return new GlideLink(args); }

SoapySDR::Registry registerGlideLink("glidelink", &findGlideLink, &makeGlideLink, SOAPY_SDR_ABI_VERSION);

} // namespace
