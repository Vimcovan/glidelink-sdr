// SoapySDR module for the GlideLink platform (PYNQ-ZU + AD9361 FMC card).
//
// Talks to the ADI ad9361 / cf_axi_adc / cf_axi_dds drivers through libiio,
// either on the board (uri=local:, the default) or from a PC through the
// board's iiod (uri=ip:<board>).
//
// Three layers of control (docs/design.md 7.2): standard parameters (frequency,
// sample rate, bandwidth, gain, antenna); the driver's device-tree parameters as
// settings (debugfs, applied by the "initialize" setting); raw AD9361 and PL
// shell registers. Streams: RF RX / TX through host port 0, in CS16 and CF32,
// where CS16 is the AD9361's 12-bit sample with full scale 2048 in both
// directions; and host port 1 (stream argument port=1), whose 32-bit words pass
// unchanged as CS16 (full scale 32768 for CF32).
//
// Over the network the samples go either through iiod (libiio buffers) or, where
// the board runs glidelink-streamd (sw/streamd), through its continuous TCP
// streams: stream argument transport = auto (streamd when it answers), iiod or
// streamd. iiod waits a round trip per buffer and tops out near 130 MB/s over the
// USB network link; streamd keeps the link busy (docs/known_issues.md 1.3).

#include <SoapySDR/Device.hpp>
#include <SoapySDR/Formats.hpp>
#include <SoapySDR/Logger.hpp>
#include <SoapySDR/Registry.hpp>
#include <SoapySDR/Time.hpp>
#include <iio.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <set>
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
// for driver operations that can take over a second (re-initialisation about
// 1 s, a sample rate change up to 1.4 s with the FIR reloaded): over the
// network, an expired timeout drops the connection to iiod
const unsigned SLOW_TIMEOUT_MS = 10000;
const double TX_ATTEN_MAX = 89.75;             // dB, TX gain = 89.75 + hardwaregain
const char *STREAMD_PORT = "7040";             // glidelink-streamd (sw/streamd)
const uint32_t STREAMD_MAGIC = 0x31534C47;     // "GLS1"
const unsigned STREAMD_KBUFS = 8;              // kernel buffers on the board

std::string chanName(size_t i) { return "voltage" + std::to_string(i); }

// One glidelink-streamd connection with its own thread, so that the connections of a
// stream move data at the same time: RX, the thread receives the buffers of its
// connection into a queue; TX, it sends the buffers queued for it. Buffers are swapped,
// not copied, between the queue and the stream's current buffer.
struct StreamdConn {
	struct Buf {
		std::vector<char> data;
		size_t len = 0;
	};
	int fd = -1;
	bool rx = true;
	size_t bufBytes = 0;
	static const size_t DEPTH = 4;      // buffers queued per connection
	std::thread th;
	std::mutex m;
	std::condition_variable cv;
	std::deque<Buf> q;                  // RX: received, TX: to send
	std::vector<std::vector<char>> spare;
	bool stop = false, error = false, busy = false;

	std::vector<char> take()            // a spare buffer (caller holds m)
	{
		if (spare.empty())
			return std::vector<char>(bufBytes);
		std::vector<char> b = std::move(spare.back());
		spare.pop_back();
		return b;
	}

	void run()
	{
		for (;;) {
			std::unique_lock<std::mutex> lock(m);
			if (rx) {
				cv.wait(lock, [&] { return stop || q.size() < DEPTH; });
				if (stop)
					return;
				Buf b;
				b.data = take();
				lock.unlock();
				uint32_t hdr[2];
				bool ok = recvFull(hdr, sizeof hdr) && hdr[0] == 0x31534C47 && hdr[1] <= bufBytes &&
					  recvFull(b.data.data(), hdr[1]);
				lock.lock();
				if (!ok) {
					error = true;
					cv.notify_all();
					return;
				}
				b.len = hdr[1];
				q.push_back(std::move(b));
				cv.notify_all();
			} else {
				cv.wait(lock, [&] { return stop || !q.empty(); });
				if (q.empty())
					return;                 // stopped with nothing left to send
				Buf b = std::move(q.front());
				q.pop_front();
				busy = true;
				lock.unlock();
				uint32_t hdr[2] = {0x31534C47, uint32_t(b.len)};
				bool ok = sendFull(hdr, sizeof hdr) && sendFull(b.data.data(), b.len);
				lock.lock();
				busy = false;
				spare.push_back(std::move(b.data));
				cv.notify_all();
				if (!ok) {
					error = true;
					return;
				}
			}
		}
	}

	bool recvFull(void *p, size_t n)
	{
		char *c = static_cast<char *>(p);
		while (n) {
			ssize_t k = recv(fd, c, n, 0);
			if (k <= 0)
				return false;
			c += k;
			n -= k;
		}
		return true;
	}

	bool sendFull(const void *p, size_t n)
	{
		const char *c = static_cast<const char *>(p);
		while (n) {
			ssize_t k = send(fd, c, n, MSG_NOSIGNAL);
			if (k <= 0)
				return false;
			c += k;
			n -= k;
		}
		return true;
	}
};

struct Stream {
	int direction;
	bool cf32;
	unsigned port = 0;              // host port: 0 = RF channels, 1 = module data
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
	uint32_t timedFlag = 0;         // TX: header flag of a timed packet (by shell version)
	bool flagsShared = false;       // shell >= 1.3: one set of flags in both directions
	bool pktEob = false;            // RX: the current packet ends a burst
	bool pktCut = false;            // RX: the current part was cut off, the packet goes on
	bool rxShifted = false;         // RX, host port 0: samples arrive shifted left by 4 (shell >= 1.5)

	// transport: libiio buffer (buf) or glidelink-streamd connections (socks)
	std::string transport = "auto";
	unsigned conns = 3;             // streamd connections; buffer i goes over connection i mod conns
	std::vector<std::string> scan;  // the IIO channels of the stream, for streamd
	std::vector<int> socks;
	std::vector<std::unique_ptr<StreamdConn>> workers;   // streamd: one per connection
	std::vector<char> local;        // streamd: the current buffer
	size_t step = 0;                // bytes per sample in the buffer
	size_t next = 0;                // streamd: connection of the next buffer
};

const uint32_t HDR_MAGIC = 0xA5;
// header flags = tuser flags (hw/library/glidelink_shell/glidelink_shell.v); before
// shell 1.3 the TX side had its own bit 0 = timed
const uint32_t FLAG_DROPPED = 1u << 0, FLAG_EOB = 1u << 1, FLAG_TIMED = 1u << 2, FLAG_TIMED_OLD = 1u << 0;
const uint32_t FLAG_CUT = 1u << 7;            // header only: a packet longer than one part goes on
const unsigned SHELL_VERSION_HEADERS = 0x00010100, SHELL_VERSION_FLAGS = 0x00010300;
// from 1.5 the RX streamer passes the 12-bit ADC sample shifted left by 4 (16-bit
// full scale in the PL, as the DAC side); CS16 stays the 12-bit sample
const unsigned SHELL_VERSION_RX16 = 0x00010500;
// shell registers (hw/library/glidelink_shell/glidelink_shell_regs.v)
const unsigned REG_VERSION = 0x004, REG_CONFIG = 0x054, REG_PORT_RESET = 0x05C, REG_ROUTE = 0x1000;
const unsigned CFG_RX_ENABLE = 1u << 0, ROUTE_NONE = 0xF;
const unsigned SINK_RF_TX = 0, SRC_RF_RX = 0;

// per host port: its DMAs' IIO devices (port 0: the AD9361 cores), PORT_RESET
// bits, CONFIG header bits, its switch sink (RX side) and source (TX side)
struct HostPort {
	const char *rxName, *txName;
	unsigned rxReset, txReset, rxHdr, txHdr, rxSink, txSource;
};
const HostPort HOST_PORTS[2] = {
	{RX_NAME, TX_NAME, 1u << 0, 1u << 1, 1u << 2, 1u << 3, 1, 1},
	{"glidelink-host1-rx", "glidelink-host1-tx", 1u << 3, 1u << 4, 1u << 4, 1u << 5, 3, 3},
};
const unsigned SHELL_VERSION_HOST1 = 0x00010200;
// slot k: switch sink and source 2 for k = 0, 3 + k after that; PORT_RESET bit
// 2 for slot 0, 4 + k after that (shell 1.4: three slots)
unsigned slotPort(unsigned k) { return k == 0 ? 2 : 3 + k; }
unsigned slotReset(unsigned k) { return k == 0 ? 1u << 2 : 1u << (4 + k); }

// A re-initialisation brings back the device tree's values; the standard
// parameters are restored afterwards unless their device-tree parameter was
// written since the last initialisation.
const char *DT_RX_BW = "adi,rf-rx-bandwidth-hz", *DT_TX_BW = "adi,rf-tx-bandwidth-hz";
const char *DT_RX_PORT = "adi,rx-rf-port-input-select", *DT_TX_PORT = "adi,tx-rf-port-input-select";
const char *DT_TX_ATTEN = "adi,tx-attenuation-mdB";
const char *DT_GC_MODE[2] = {"adi,gc-rx1-mode", "adi,gc-rx2-mode"};
const char *SETTING_INIT = "initialize", *SETTING_GAIN_MODE = "gain_control_mode";

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
		host1Rx = iio_context_find_device(ctx, HOST_PORTS[1].rxName);
		host1Tx = iio_context_find_device(ctx, HOST_PORTS[1].txName);
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
		return splitWords(readAttr(phyChan(dir, ch), "rf_port_select_available"));
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
		// automatic keeps an AGC mode already chosen (fast_attack, hybrid through
		// the gain_control_mode setting) and takes slow_attack from manual
		if (dir != SOAPY_SDR_RX || automatic == getGainMode(dir, ch))
			return;
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
		// under AGC the chip sets the RX gain (and refuses writes): tools that
		// always set a gain (gr-soapy) are not an error
		if (dir == SOAPY_SDR_RX && getGainMode(dir, ch))
			return;
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
		slow([&] { writeLongLong(phyChan(dir, ch), "sampling_frequency", llround(rate)); });
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

	// settings: the driver's debugfs parameters by their device-tree names
	// ("adi,...", plus "loopback" and the other debug attributes), applied to
	// the chip by "initialize"; and the RX gain control mode by name

	SoapySDR::ArgInfoList getSettingInfo() const override
	{
		SoapySDR::ArgInfoList list;
		SoapySDR::ArgInfo init;
		init.key = SETTING_INIT;
		init.value = "false";
		init.name = "Re-initialise";
		init.description = "Writing true re-initialises the AD9361 with the device-tree parameters as now "
				   "set (about 1 s); frequency, sample rate, bandwidth, ports, gain mode and gains "
				   "are restored unless their own parameter was written.";
		init.type = SoapySDR::ArgInfo::BOOL;
		list.push_back(init);
		SoapySDR::ArgInfo mode;
		mode.key = SETTING_GAIN_MODE;
		mode.value = readAttr(phyChan(SOAPY_SDR_RX, 0), "gain_control_mode");
		mode.name = "RX gain control mode";
		mode.description = "AD9361 gain control of all RX channels.";
		mode.type = SoapySDR::ArgInfo::STRING;
		mode.options = splitWords(readAttr(phyChan(SOAPY_SDR_RX, 0), "gain_control_mode_available"));
		list.push_back(mode);
		for (const std::string &key : debugAttrs()) {
			SoapySDR::ArgInfo a;
			a.key = key;
			a.value = readDebug(key);
			a.name = key;
			a.description = "AD9361 driver parameter (debugfs); a device-tree parameter takes effect "
					"on initialize.";
			a.type = SoapySDR::ArgInfo::STRING;
			list.push_back(a);
		}
		return list;
	}

	void writeSetting(const std::string &key, const std::string &value) override
	{
		if (key == SETTING_INIT) {
			if (value == "true" || value == "1")
				initialize();
			return;
		}
		if (key == SETTING_GAIN_MODE) {
			for (size_t ch = 0; ch < getNumChannels(SOAPY_SDR_RX); ch++)
				writeAttr(phyChan(SOAPY_SDR_RX, ch), "gain_control_mode", value);
			return;
		}
		checkDebugAttr(key);
		slow([&] {                       // some (bist_*, digital_tune) act at once
			std::lock_guard<std::mutex> lock(mutex);
			if (iio_device_debug_attr_write(phy, key.c_str(), value.c_str()) < 0)
				throw std::runtime_error("GlideLink: cannot write setting " + key + " = " + value);
		});
		written.insert(key);
	}

	std::string readSetting(const std::string &key) const override
	{
		if (key == SETTING_INIT)
			return "false";
		if (key == SETTING_GAIN_MODE)
			return readAttr(phyChan(SOAPY_SDR_RX, 0), "gain_control_mode");
		checkDebugAttr(key);
		return readDebug(key);
	}

	// the settings belong to the device; per-channel calls (e.g. gr-soapy's
	// "Other settings") reach the same ones, listed once at device level

	void writeSetting(const int, const size_t, const std::string &key, const std::string &value) override
	{
		writeSetting(key, value);
	}

	std::string readSetting(const int, const size_t, const std::string &key) const override
	{
		return readSetting(key);
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
		SoapySDR::ArgInfo port;
		port.key = "port";
		port.value = "0";
		port.name = "Host port";
		port.description = "0: the RF channels; 1: host port 1 of the PL shell (module data, 32-bit words "
				   "unchanged, routed by the FPGA ROUTE registers).";
		port.type = SoapySDR::ArgInfo::INT;
		port.options = {"0", "1"};
		SoapySDR::ArgInfo tr;
		tr.key = "transport";
		tr.value = "auto";
		tr.name = "Transport";
		tr.description = "Over the network: iiod (libiio buffers), streamd (glidelink-streamd on the board, "
				 "continuous TCP streams, for high rates) or auto (streamd when the board runs it).";
		tr.type = SoapySDR::ArgInfo::STRING;
		tr.options = {"auto", "iiod", "streamd"};
		SoapySDR::ArgInfo nc;
		nc.key = "connections";
		nc.value = "3";
		nc.name = "streamd connections";
		nc.description = "TCP connections a streamd stream is spread over (1 to 4).";
		nc.type = SoapySDR::ArgInfo::INT;
		return {len, hdr, port, tr, nc};
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
		it = args.find("port");
		if (it != args.end())
			s->port = std::stoul(it->second);
		it = args.find("transport");
		if (it != args.end())
			s->transport = it->second;
		it = args.find("connections");
		if (it != args.end())
			s->conns = std::max(1ul, std::min(4ul, std::stoul(it->second)));
		if (s->transport != "auto" && s->transport != "iiod" && s->transport != "streamd") {
			delete s;
			throw std::runtime_error("GlideLink: transport auto, iiod or streamd");
		}
		it = args.find("headers");
		bool wantHeaders = it == args.end() || it->second != "false";
		if (s->port == 1) {
			s->dev = dir == SOAPY_SDR_RX ? host1Rx : host1Tx;
			if (!s->dev || readRegister("FPGA", REG_VERSION) < SHELL_VERSION_HOST1 ||
			    s->channels != std::vector<size_t>{0}) {
				delete s;
				throw std::runtime_error("GlideLink: host port 1 needs shell 1.2 with its DMA devices, "
							 "and one channel (0)");
			}
			s->headers = wantHeaders;
			setFlagBits(s);
			s->slot = {0};
			s->numSlots = 1;
			s->scan = {"voltage0"};
			iio_channel_enable(iio_device_find_channel(s->dev, "voltage0", dir == SOAPY_SDR_TX));
			return reinterpret_cast<SoapySDR::Stream *>(s);
		}
		if (s->port != 0) {
			unsigned port = s->port;
			delete s;
			throw std::runtime_error("GlideLink: no host port " + std::to_string(port));
		}
		s->headers = shell && readRegister("FPGA", REG_VERSION) >= SHELL_VERSION_HEADERS && wantHeaders &&
			     s->channels.size() == 1 && s->channels[0] == 0;
		s->rxShifted = dir == SOAPY_SDR_RX && shell && readRegister("FPGA", REG_VERSION) >= SHELL_VERSION_RX16;
		if (s->headers)
			setFlagBits(s);

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
		for (size_t c : sorted)
			for (size_t k = 0; k < 2; k++)
				s->scan.push_back(chanName(2 * c + k));
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
		if (active(s))
			return 0;
		s->rate = sampleRate();
		s->hdrPos = 0;
		s->pktLeft = 0;
		s->overflow = false;
		s->firstPacket = true;
		// RX: hold the RX streamer off until the DMA has its buffers queued, so
		// the stream neither starts with a drop nor with samples from before it
		bool gateRx = s->headers && s->direction == SOAPY_SDR_RX && s->port == 0;
		if (gateRx)
			setRxEnable(false);
		setPortHeaders(s, s->headers);
		bool net = uri.compare(0, 3, "ip:") == 0;
		bool viaStreamd = net && s->transport != "iiod" && openStreamd(s);
		if (!viaStreamd && s->transport == "streamd") {
			if (gateRx)
				setRxEnable(true);
			SoapySDR::log(SOAPY_SDR_ERROR, "GlideLink: glidelink-streamd not reachable");
			return SOAPY_SDR_STREAM_ERROR;
		}
		if (!viaStreamd) {
			s->buf = iio_device_create_buffer(s->dev, s->bufferLength, false);
			if (s->buf)
				s->step = iio_buffer_step(s->buf);
		}
		if (gateRx)
			setRxEnable(true);
		if (!active(s)) {
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
		if (!active(s))
			return SOAPY_SDR_STREAM_ERROR;
		if (s->headers)
			return readPackets(s, buffs[0], numElems, flags, timeNs);
		if (s->pos == s->avail) {
			int ret = refill(s);
			if (ret < 0)
				return ret;
		}
		size_t n = std::min(numElems, s->avail - s->pos);
		const int16_t *src = static_cast<const int16_t *>(bufStart(s)) + 2 * s->numSlots * s->pos;
		for (size_t i = 0; i < s->channels.size(); i++) {
			const int16_t *p = src + 2 * s->slot[i];
			if (s->cf32) {
				float *dst = static_cast<float *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					dst[2 * j] = fromWord(s, p[0]) / fullScale(s);
					dst[2 * j + 1] = fromWord(s, p[1]) / fullScale(s);
				}
			} else {
				int16_t *dst = static_cast<int16_t *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					dst[2 * j] = fromWord(s, p[0]);
					dst[2 * j + 1] = fromWord(s, p[1]);
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
		if (!active(s))
			return SOAPY_SDR_STREAM_ERROR;
		if (s->headers)
			return writePacket(s, buffs[0], numElems, flags, timeNs);
		size_t n = std::min(numElems, s->bufferLength - s->pos);
		int16_t *dst = static_cast<int16_t *>(bufStart(s)) + 2 * s->numSlots * s->pos;
		for (size_t i = 0; i < s->channels.size(); i++) {
			int16_t *p = dst + 2 * s->slot[i];
			if (s->cf32) {
				const float *src = static_cast<const float *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					p[0] = toWord(s, roundHalfAway(src[2 * j] * fullScale(s)));
					p[1] = toWord(s, roundHalfAway(src[2 * j + 1] * fullScale(s)));
				}
			} else {
				const int16_t *src = static_cast<const int16_t *>(buffs[i]);
				for (size_t j = 0; j < n; j++, p += 2 * s->numSlots) {
					p[0] = toWord(s, src[2 * j]);
					p[1] = toWord(s, src[2 * j + 1]);
				}
			}
		}
		s->pos += n;
		bool endBurst = (flags & SOAPY_SDR_END_BURST) && n == numElems;
		if (s->pos == s->bufferLength || (endBurst && s->pos > 0)) {
			int ret = pushBuffer(s);
			if (ret < 0)
				return ret;
		}
		return n;
	}

private:
	// 12-bit sample, full scale 2048, into the DAC's MSB-aligned 16-bit word
	static int16_t toDac(long v)
	{
		return static_cast<int16_t>(std::max(-2048L, std::min(2047L, v)) * 16);
	}

	// host port 0 carries AD9361 samples, host port 1 the module's words as they are
	static float fullScale(const Stream *s) { return s->port == 0 ? 2048.0f : 32768.0f; }

	// a received word as a CS16 value: the 12-bit sample on host port 0
	static int16_t fromWord(const Stream *s, int16_t v)
	{
		return s->rxShifted && s->port == 0 ? static_cast<int16_t>(v >> 4) : v;
	}

	// to the nearest integer, halves away from zero (as std::lround, without its cost: TX
	// conversion of CF32 at 50 MSPS)
	static long roundHalfAway(float x) { return static_cast<long>(x + (x < 0 ? -0.5f : 0.5f)); }

	static int16_t toWord(const Stream *s, long v)
	{
		return s->port == 0 ? toDac(v) : static_cast<int16_t>(std::max(-32768L, std::min(32767L, v)));
	}

	int refill(Stream *s)
	{
		if (!s->socks.empty())
			return refillStreamd(s);
		ssize_t ret = iio_buffer_refill(s->buf);
		if (ret < 0)
			return ret == -ETIMEDOUT ? SOAPY_SDR_TIMEOUT : SOAPY_SDR_STREAM_ERROR;
		s->avail = ret / s->step;
		s->pos = 0;
		return 0;
	}

	static bool active(const Stream *s) { return s->buf || !s->socks.empty(); }

	static void *bufStart(Stream *s) { return s->socks.empty() ? iio_buffer_start(s->buf) : s->local.data(); }

	// glidelink-streamd: s->conns connections to the board's port 7040, the stream
	// set up over the first (sw/streamd/glidelink_streamd.c)
	bool openStreamd(Stream *s)
	{
		std::string host = uri.substr(3);
		addrinfo hints = {}, *res = nullptr;
		hints.ai_socktype = SOCK_STREAM;
		if (getaddrinfo(host.c_str(), STREAMD_PORT, &hints, &res) != 0)
			return false;
		auto connectOne = [&]() {
			int fd = socket(res->ai_family, SOCK_STREAM, 0);
			if (fd < 0)
				return -1;
			int sz = 16 << 20, one = 1;
			setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
			setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
			setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
			if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
				close(fd);
				return -1;
			}
			return fd;
		};
		auto fail = [&](const std::string &why) {
			if (!why.empty())
				SoapySDR::logf(SOAPY_SDR_WARNING, "GlideLink: streamd: %s", why.c_str());
			for (int fd : s->socks)
				close(fd);
			s->socks.clear();
			freeaddrinfo(res);
			return false;
		};
		int fd = connectOne();
		if (fd < 0)
			return fail(s->transport == "streamd" ? "cannot connect" : "");
		s->socks.push_back(fd);
		std::string names;
		for (const auto &c : s->scan)
			names += (names.empty() ? "" : ",") + c;
		std::string req = std::string("GLS1 ") + (s->direction == SOAPY_SDR_RX ? "rx " : "tx ") +
				  iio_device_get_name(s->dev) + " " + std::to_string(s->bufferLength) + " " +
				  std::to_string(STREAMD_KBUFS) + " " + names + " " + std::to_string(s->conns) + "\n";
		std::string reply;
		if (!sendAll(fd, req.data(), req.size()) || !readLine(fd, reply) || reply.compare(0, 3, "OK ") != 0)
			return fail(reply.empty() ? "no reply" : reply);
		unsigned long step = 0;
		int id = 0;
		if (sscanf(reply.c_str(), "OK %lu %d", &step, &id) != 2)
			return fail(reply);
		for (unsigned k = 1; k < s->conns; k++) {
			int fk = connectOne();
			if (fk < 0)
				return fail("cannot open connection " + std::to_string(k));
			s->socks.push_back(fk);
			std::string join = "GLS1 join " + std::to_string(id) + " " + std::to_string(k) + "\n";
			if (!sendAll(fk, join.data(), join.size()) || !readLine(fk, reply) || reply != "OK")
				return fail("connection " + std::to_string(k) + ": " + reply);
		}
		freeaddrinfo(res);
		s->step = step;
		s->local.assign(s->bufferLength * step, 0);
		s->next = 0;
		for (int fk : s->socks) {
			auto w = std::make_unique<StreamdConn>();
			w->fd = fk;
			w->rx = s->direction == SOAPY_SDR_RX;
			w->bufBytes = s->local.size();
			StreamdConn *wp = w.get();
			w->th = std::thread([wp] { wp->run(); });
			s->workers.push_back(std::move(w));
		}
		return true;
	}

	static bool sendAll(int fd, const void *p, size_t n)
	{
		const char *c = static_cast<const char *>(p);
		while (n) {
			ssize_t k = send(fd, c, n, MSG_NOSIGNAL);
			if (k <= 0)
				return false;
			c += k;
			n -= k;
		}
		return true;
	}

	// read n bytes: waits up to timeoutMs for the first (0: none came), then for the rest
	static int recvAll(int fd, void *p, size_t n, int timeoutMs)
	{
		char *c = static_cast<char *>(p);
		size_t got = 0;
		while (got < n) {
			pollfd pf = {fd, POLLIN, 0};
			int r = poll(&pf, 1, got == 0 ? timeoutMs : 10000);
			if (r == 0)
				return got == 0 ? 0 : -1;
			if (r < 0)
				return -1;
			ssize_t k = recv(fd, c + got, n - got, 0);
			if (k <= 0)
				return -1;
			got += k;
		}
		return 1;
	}

	static bool readLine(int fd, std::string &line)
	{
		line.clear();
		char ch;
		while (recvAll(fd, &ch, 1, 5000) == 1) {
			if (ch == '\n')
				return true;
			line += ch;
		}
		return false;
	}

	// RX: the next buffer from the connection it comes over (its thread received it)
	int refillStreamd(Stream *s)
	{
		StreamdConn &w = *s->workers[s->next];
		std::unique_lock<std::mutex> lock(w.m);
		if (!w.cv.wait_for(lock, std::chrono::milliseconds(DEFAULT_TIMEOUT_MS),
				   [&] { return !w.q.empty() || w.error; }))
			return SOAPY_SDR_TIMEOUT;
		if (w.q.empty())
			return SOAPY_SDR_STREAM_ERROR;
		StreamdConn::Buf b = std::move(w.q.front());
		w.q.pop_front();
		std::swap(s->local, b.data);            // the old current buffer goes back as a spare
		w.spare.push_back(std::move(b.data));
		w.cv.notify_all();
		lock.unlock();
		s->next = (s->next + 1) % s->workers.size();
		s->avail = b.len / s->step;
		s->pos = 0;
		return 0;
	}

	// TX: queue the current buffer for its connection's thread
	int pushStreamd(Stream *s)
	{
		StreamdConn &w = *s->workers[s->next];
		std::unique_lock<std::mutex> lock(w.m);
		if (!w.cv.wait_for(lock, std::chrono::milliseconds(SLOW_TIMEOUT_MS),
				   [&] { return w.q.size() < StreamdConn::DEPTH || w.error; }))
			return SOAPY_SDR_TIMEOUT;
		if (w.error)
			return SOAPY_SDR_STREAM_ERROR;
		StreamdConn::Buf b;
		b.len = s->pos * s->step;
		b.data = w.take();
		std::swap(s->local, b.data);            // a spare becomes the buffer to fill next
		w.q.push_back(std::move(b));
		w.cv.notify_all();
		lock.unlock();
		s->next = (s->next + 1) % s->workers.size();
		s->pos = 0;
		return 0;
	}

	// end the streamd stream: TX, what is queued is sent first
	static void closeStreamd(Stream *s)
	{
		for (auto &w : s->workers) {
			std::unique_lock<std::mutex> lock(w->m);
			if (!w->rx)
				w->cv.wait_for(lock, std::chrono::seconds(10), [&] { return (w->q.empty() && !w->busy) || w->error; });
			w->stop = true;
			w->cv.notify_all();
		}
		for (auto &w : s->workers)
			shutdown(w->fd, SHUT_RDWR);         // a thread blocked in recv / send returns
		for (auto &w : s->workers)
			w->th.join();
		s->workers.clear();
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
			const uint32_t *w = static_cast<const uint32_t *>(bufStart(s));
			while (s->hdrPos < 4 && s->pos < s->avail) {
				s->hdr[s->hdrPos++] = w[s->pos++];
				if (s->hdrPos == 1 && (s->hdr[0] >> 24 != HDR_MAGIC || (s->hdr[0] & 0xffff) == 0)) {
					SoapySDR::log(SOAPY_SDR_WARNING, "GlideLink: RX packet header lost, resynchronising");
					s->hdrPos = 0;
				}
				if (s->hdrPos == 4) {
					s->pktLeft = s->hdr[0] & 0xffff;
					s->pktTime = (uint64_t(s->hdr[3]) << 32) | s->hdr[2];
					uint32_t pf = s->hdr[0] >> 16;
					s->pktEob = s->flagsShared && (pf & FLAG_EOB);
					s->pktCut = pf & FLAG_CUT;
					// before 1.3 a packet from a host TX port had bit 0 = timed
					bool dropped = (pf & FLAG_DROPPED) && (s->flagsShared || s->port == 0);
					if (dropped && !s->firstPacket)
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
			if (s->pktLeft == 0) {
				s->hdrPos = 0;
				if (s->pktCut)
					flags |= SOAPY_SDR_MORE_FRAGMENTS;   // the stream packet continues in the next part
				else if (s->pktEob)
					flags |= SOAPY_SDR_END_BURST;
			} else {
				flags |= SOAPY_SDR_MORE_FRAGMENTS;
			}
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
		uint32_t pf = ((flags & SOAPY_SDR_HAS_TIME) ? s->timedFlag : 0) | (eob ? FLAG_EOB : 0);
		uint64_t t = (flags & SOAPY_SDR_HAS_TIME) ? SoapySDR::timeNsToTicks(timeNs, s->rate) : 0;
		uint32_t *w = static_cast<uint32_t *>(bufStart(s)) + s->pos;
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
		if (!s->socks.empty())
			return pushStreamd(s);
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
				dst[j] = fromWord(s, p[j]) / fullScale(s);
		} else if (s->rxShifted) {
			int16_t *dst = static_cast<int16_t *>(out);
			for (size_t j = 0; j < 2 * n; j++)
				dst[j] = fromWord(s, p[j]);
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
				p[j] = toWord(s, roundHalfAway(src[j] * fullScale(s)));
		} else {
			const int16_t *src = static_cast<const int16_t *>(in);
			for (size_t j = 0; j < 2 * n; j++)
				p[j] = toWord(s, src[j]);
		}
	}

	void setFlagBits(Stream *s) const
	{
		s->flagsShared = readRegister("FPGA", REG_VERSION) >= SHELL_VERSION_FLAGS;
		s->timedFlag = s->flagsShared ? FLAG_TIMED : FLAG_TIMED_OLD;
	}

	void setRxEnable(bool on)
	{
		unsigned cfg = readRegister("FPGA", REG_CONFIG);
		writeRegister("FPGA", REG_CONFIG, on ? (cfg | CFG_RX_ENABLE) : (cfg & ~CFG_RX_ENABLE));
	}

	// The host port is flushed and its header mode set while the port is idle:
	// a stream that was torn down can leave a packet cut off in the shell (the
	// DMA stops mid-transfer), which PORT_RESET clears; RX is unrouted
	// meanwhile, and the switch reconnects it at the start of a packet. Routes
	// the user set (e.g. through module slots) are kept; host port 0 falls back
	// to the RF channels where its route is empty. The slots on the port's path
	// (upstream of RX, downstream of TX) are flushed too: a stream stopped
	// mid-packet leaves them holding part of a packet (a flush keeps their
	// registers).
	void setPortHeaders(const Stream *s, bool on)
	{
		if (!shell || readRegister("FPGA", REG_VERSION) < SHELL_VERSION_HEADERS)
			return;
		const HostPort &hp = HOST_PORTS[s->port];
		bool rx = s->direction == SOAPY_SDR_RX;
		unsigned bit = rx ? hp.rxHdr : hp.txHdr;
		unsigned cfg = readRegister("FPGA", REG_CONFIG);
		cfg = on ? (cfg | bit) : (cfg & ~bit);
		unsigned slot = slotsOnPath(rx ? hp.rxSink : hp.txSource, rx);
		if (rx) {
			unsigned addr = REG_ROUTE + 4 * hp.rxSink;
			unsigned route = readRegister("FPGA", addr);
			if (route == ROUTE_NONE && s->port == 0)
				route = SRC_RF_RX;
			writeRegister("FPGA", addr, ROUTE_NONE);
			writeRegister("FPGA", REG_PORT_RESET, hp.rxReset | slot);
			writeRegister("FPGA", REG_CONFIG, cfg);
			writeRegister("FPGA", addr, route);
		} else {
			writeRegister("FPGA", REG_PORT_RESET, hp.txReset | slot);
			writeRegister("FPGA", REG_CONFIG, cfg);
			unsigned addr = REG_ROUTE + 4 * SINK_RF_TX;
			if (s->port == 0 && readRegister("FPGA", addr) == ROUTE_NONE)
				writeRegister("FPGA", addr, hp.txSource);
		}
	}

	template <typename F> void slow(F f)
	{
		iio_context_set_timeout(ctx, SLOW_TIMEOUT_MS);
		try {
			f();
		} catch (...) {
			iio_context_set_timeout(ctx, DEFAULT_TIMEOUT_MS);
			throw;
		}
		iio_context_set_timeout(ctx, DEFAULT_TIMEOUT_MS);
	}

	// PORT_RESET bits of the slots chained to a port: upstream of sink `from`
	// (rx) or downstream of source `from`
	unsigned slotsOnPath(unsigned from, bool rx)
	{
		unsigned n = (readRegister("FPGA", 0x008) >> 24) & 0xff;
		std::vector<unsigned> route(3 + n);
		for (unsigned j = 0; j < route.size(); j++)
			route[j] = readRegister("FPGA", REG_ROUTE + 4 * j);
		auto slotOf = [&](unsigned port) {
			for (unsigned k = 0; k < n; k++)
				if (slotPort(k) == port)
					return int(k);
			return -1;
		};
		unsigned bits = 0;
		unsigned at = from;
		for (unsigned hops = 0; hops < n; hops++) {
			int k;
			if (rx) {                       // the source feeding sink `at`
				if (at >= route.size() || (k = slotOf(route[at])) < 0)
					break;
			} else {                        // the sink fed by source `at`
				unsigned j = 0;
				while (j < route.size() && route[j] != at)
					j++;
				if (j == route.size() || (k = slotOf(j)) < 0)
					break;
			}
			bits |= slotReset(k);
			at = slotPort(k);
		}
		return bits;
	}

	// driver re-initialisation, then the standard parameters as they were
	void initialize()
	{
		size_t nrx = getNumChannels(SOAPY_SDR_RX), ntx = getNumChannels(SOAPY_SDR_TX);
		double rate = sampleRate();
		double rxLo = getFrequency(SOAPY_SDR_RX, 0, "RF"), txLo = getFrequency(SOAPY_SDR_TX, 0, "RF");
		double rxBw = getBandwidth(SOAPY_SDR_RX, 0), txBw = getBandwidth(SOAPY_SDR_TX, 0);
		std::vector<std::string> rxPort, txPort, mode;
		std::vector<double> rxGain, txGain;
		for (size_t ch = 0; ch < nrx; ch++) {
			rxPort.push_back(getAntenna(SOAPY_SDR_RX, ch));
			mode.push_back(readAttr(phyChan(SOAPY_SDR_RX, ch), "gain_control_mode"));
			rxGain.push_back(getGain(SOAPY_SDR_RX, ch));
		}
		for (size_t ch = 0; ch < ntx; ch++) {
			txPort.push_back(getAntenna(SOAPY_SDR_TX, ch));
			txGain.push_back(getGain(SOAPY_SDR_TX, ch));
		}

		slow([&] {
			std::lock_guard<std::mutex> lock(mutex);
			if (iio_device_debug_attr_write(phy, SETTING_INIT, "1") < 0)
				throw std::runtime_error("GlideLink: AD9361 re-initialisation failed");
		});

		auto keep = [this](const char *key) { return written.count(key) == 0; };
		setSampleRate(SOAPY_SDR_RX, 0, rate);
		if (keep(DT_RX_BW))
			setBandwidth(SOAPY_SDR_RX, 0, rxBw);
		if (keep(DT_TX_BW))
			setBandwidth(SOAPY_SDR_TX, 0, txBw);
		setFrequency(SOAPY_SDR_RX, 0, "RF", rxLo, {});
		setFrequency(SOAPY_SDR_TX, 0, "RF", txLo, {});
		for (size_t ch = 0; ch < nrx; ch++) {
			if (keep(DT_RX_PORT))
				setAntenna(SOAPY_SDR_RX, ch, rxPort[ch]);
			if (ch < 2 && keep(DT_GC_MODE[ch])) {
				writeAttr(phyChan(SOAPY_SDR_RX, ch), "gain_control_mode", mode[ch]);
				if (mode[ch] == "manual")
					setGain(SOAPY_SDR_RX, ch, rxGain[ch]);
			}
		}
		for (size_t ch = 0; ch < ntx; ch++) {
			if (keep(DT_TX_PORT))
				setAntenna(SOAPY_SDR_TX, ch, txPort[ch]);
			if (keep(DT_TX_ATTEN))
				setGain(SOAPY_SDR_TX, ch, txGain[ch]);
		}
		written.clear();
	}

	// debug attributes offered as settings ("initialize" and the register
	// access have their own interfaces)
	static bool isSettingAttr(const std::string &key)
	{
		return key != SETTING_INIT && key != "direct_reg_access";
	}

	std::vector<std::string> debugAttrs() const
	{
		std::vector<std::string> keys;
		for (unsigned i = 0; i < iio_device_get_debug_attrs_count(phy); i++) {
			std::string key = iio_device_get_debug_attr(phy, i);
			if (isSettingAttr(key))
				keys.push_back(key);
		}
		return keys;
	}

	void checkDebugAttr(const std::string &key) const
	{
		if (!isSettingAttr(key) || !iio_device_find_debug_attr(phy, key.c_str()))
			throw std::runtime_error("GlideLink: unknown setting " + key);
	}

	std::string readDebug(const std::string &key) const
	{
		char buf[1024];
		std::lock_guard<std::mutex> lock(mutex);
		if (iio_device_debug_attr_read(phy, key.c_str(), buf, sizeof(buf)) < 0)
			return "";                    // write-only attributes
		std::string v = buf;
		while (!v.empty() && (v.back() == '\n' || v.back() == ' '))
			v.pop_back();
		return v;
	}

	static std::vector<std::string> splitWords(const std::string &s)
	{
		std::vector<std::string> words;
		size_t p = 0;
		while (p < s.size()) {
			size_t q = s.find_first_of(" \n", p);
			if (q == std::string::npos)
				q = s.size();
			if (q > p)
				words.push_back(s.substr(p, q - p));
			p = q + 1;
		}
		return words;
	}

	void stopBuffer(Stream *s)
	{
		if (!active(s))
			return;
		if (s->direction == SOAPY_SDR_TX && s->pos > 0)
			pushBuffer(s);
		if (s->buf)
			iio_buffer_destroy(s->buf);
		s->buf = nullptr;
		closeStreamd(s);
		for (int fd : s->socks)
			close(fd);
		s->socks.clear();
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
	iio_device *host1Rx = nullptr, *host1Tx = nullptr;
	std::set<std::string> written;  // device-tree parameters written since the last initialisation
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
