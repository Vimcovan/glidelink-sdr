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

const size_t DEFAULT_BUFFER_LENGTH = 16384;    // samples per IIO buffer
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
};

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
		writeLongLong(phyChan(dir, ch), "sampling_frequency", llround(rate));
	}

	double getSampleRate(const int dir, const size_t ch) const override
	{
		return readDouble(phyChan(dir, ch), "sampling_frequency");
	}

	SoapySDR::RangeList getSampleRateRange(const int dir, const size_t ch) const override
	{
		return {readRange(phyChan(dir, ch), "sampling_frequency_available")};
	}

	std::vector<double> listSampleRates(const int dir, const size_t ch) const override
	{
		SoapySDR::Range r = readRange(phyChan(dir, ch), "sampling_frequency_available");
		std::vector<double> rates;
		for (double f : {2.5e6, 5e6, 10e6, 15.36e6, 20e6, 30.72e6, 61.44e6})
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

	// registers

	std::vector<std::string> listRegisterInterfaces() const override { return {"AD9361"}; }

	void writeRegister(const std::string &name, const unsigned addr, const unsigned value) override
	{
		checkRegisterInterface(name);
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_device_reg_write(phy, addr, value) < 0)
			throw std::runtime_error("GlideLink: AD9361 register write failed");
	}

	unsigned readRegister(const std::string &name, const unsigned addr) const override
	{
		checkRegisterInterface(name);
		std::lock_guard<std::mutex> lock(mutex);
		uint32_t value = 0;
		if (iio_device_reg_read(phy, addr, &value) < 0)
			throw std::runtime_error("GlideLink: AD9361 register read failed");
		return value;
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
		return {len};
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
		s->buf = iio_device_create_buffer(s->dev, s->bufferLength, false);
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
		stopBuffer(reinterpret_cast<Stream *>(stream));
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
		if (s->pos == s->avail) {
			ssize_t ret = iio_buffer_refill(s->buf);
			if (ret < 0)
				return ret == -ETIMEDOUT ? SOAPY_SDR_TIMEOUT : SOAPY_SDR_STREAM_ERROR;
			s->avail = ret / iio_buffer_step(s->buf);
			s->pos = 0;
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
			const long long, const long) override
	{
		Stream *s = reinterpret_cast<Stream *>(stream);
		if (!s->buf)
			return SOAPY_SDR_STREAM_ERROR;
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

	static void checkRegisterInterface(const std::string &name)
	{
		if (name != "AD9361")
			throw std::runtime_error("GlideLink: unknown register interface " + name);
	}

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
	iio_device *phy = nullptr, *rxDev = nullptr, *txDev = nullptr;
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
