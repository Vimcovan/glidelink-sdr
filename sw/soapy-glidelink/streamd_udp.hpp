// Client of glidelink-streamd (sw/streamd/glidelink_streamd.c): one sample stream between the
// PC and the board's IIO DMA buffers over UDP, set up over TCP port 7040. Linux and Windows.
//
// As UHD streams to network USRPs: data in UDP packets with a sequence number, flow control in
// both directions with status packets going the other way (RX: this side reports every 1/32 of
// its socket buffer consumed, the board keeps its data in flight within that; TX: the board
// reports every 1/8 of its capacity consumed, this side keeps within it). A sequence gap marks
// the buffer it falls in as lost. The first UDP packet goes from the PC to the board, so that
// firewalls (Windows, WSL) let the board's packets in.
//
// Packet size (frame bytes, header included): Windows 8000 (the boards' USB network link has
// jumbo frames, MTU 9000, and Windows sets its side by itself); Linux the path MTU of the
// connection less 28 (WSL: 1472 with its interfaces at MTU 1500), at most 8000.

#pragma once

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace streamd {

#ifdef _WIN32
using sock_t = SOCKET;
const sock_t BAD_SOCK = INVALID_SOCKET;
inline void sockClose(sock_t s) { closesocket(s); }
const int SHUT_SEND = SD_SEND;
inline int sockPoll(sock_t s, int ms)
{
	WSAPOLLFD p = {s, POLLRDNORM, 0};
	return WSAPoll(&p, 1, ms);
}
inline void setNonBlocking(sock_t s)
{
	u_long on = 1;
	ioctlsocket(s, FIONBIO, &on);
}
inline bool netInit()
{
	static bool ok = [] {
		WSADATA w;
		return WSAStartup(MAKEWORD(2, 2), &w) == 0;
	}();
	return ok;
}
const int SEND_FLAGS = 0;
#else
using sock_t = int;
const sock_t BAD_SOCK = -1;
inline void sockClose(sock_t s) { close(s); }
const int SHUT_SEND = SHUT_WR;
inline int sockPoll(sock_t s, int ms)
{
	pollfd p = {s, POLLIN, 0};
	return poll(&p, 1, ms);
}
inline void setNonBlocking(sock_t s) { fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK); }
inline bool netInit() { return true; }
const int SEND_FLAGS = MSG_NOSIGNAL;
#endif

const uint32_t MAGIC = 0x31554C47;          // "GLU1"
const uint16_t TYPE_DATA = 0, TYPE_STATUS = 1, FLAG_END = 1;
const size_t HDR = 16;

struct Header {
	uint32_t magic;
	uint16_t type, flags;
	uint32_t seq, reserved;
};

class Stream {
public:
	struct Buf {
		std::vector<char> data;
		size_t len = 0;
		bool lost = false;
	};

	// set up a stream; nullptr and a message on failure
	static std::unique_ptr<Stream> open(const std::string &host, bool rx, const std::string &dev, size_t samples,
					    unsigned kbufs, const std::string &chans, size_t frame, std::string &err)
	{
		if (!netInit()) {
			err = "network init failed";
			return nullptr;
		}
		std::unique_ptr<Stream> s(new Stream);
		s->rx_ = rx;
		addrinfo hints = {}, *res = nullptr;
		hints.ai_socktype = SOCK_STREAM;
		if (getaddrinfo(host.c_str(), "7040", &hints, &res) != 0) {
			err = "cannot resolve " + host;
			return nullptr;
		}
		s->tcp_ = socket(res->ai_family, SOCK_STREAM, 0);
		bool connected = s->tcp_ != BAD_SOCK && connect(s->tcp_, res->ai_addr, (int)res->ai_addrlen) == 0;
		freeaddrinfo(res);
		if (!connected) {
			err = "cannot connect";
			return nullptr;
		}
		int one = 1;
		setsockopt(s->tcp_, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
		if (frame == 0)
			frame = defaultFrame(s->tcp_);

		// the UDP socket, its buffers, its capacity
		sockaddr_storage peer = {};
		socklen_t plen = sizeof peer;
		getpeername(s->tcp_, (sockaddr *)&peer, &plen);
		s->udp_ = socket(peer.ss_family, SOCK_DGRAM, 0);
		if (s->udp_ == BAD_SOCK) {
			err = "cannot open a UDP socket";
			return nullptr;
		}
		setBuffers(s->udp_);
		sockaddr_storage me = {};
		me.ss_family = peer.ss_family;
		bind(s->udp_, (sockaddr *)&me, peer.ss_family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6));
		socklen_t mlen = sizeof me;
		getsockname(s->udp_, (sockaddr *)&me, &mlen);
		int rcv = 0;
		socklen_t rl = sizeof rcv;
		getsockopt(s->udp_, SOL_SOCKET, SO_RCVBUF, (char *)&rcv, &rl);
		s->myCapacity_ = std::max<uint64_t>(uint64_t(rcv) / 4, 1 << 20);

		char line[512];
		snprintf(line, sizeof line, "GLU1 %s %s %zu %u %s %u %zu %llu\n", rx ? "rx" : "tx", dev.c_str(), samples,
			 kbufs, chans.c_str(), port(me), frame, (unsigned long long)s->myCapacity_);
		std::string reply;
		if (!sendAll(s->tcp_, line, strlen(line)) || !readLine(s->tcp_, reply)) {
			err = "no reply";
			return nullptr;
		}
		unsigned long step = 0;
		unsigned bport = 0;
		unsigned long long bcap = 0;
		if (sscanf(reply.c_str(), "OK %lu %u %llu", &step, &bport, &bcap) != 3) {
			err = reply;
			return nullptr;
		}
		setPort(peer, bport);
		if (connect(s->udp_, (sockaddr *)&peer, plen) != 0) {
			err = "cannot connect the UDP socket";
			return nullptr;
		}
		s->step_ = step;
		s->frame_ = frame;
		s->payload_ = (frame - HDR) / step * step;
		s->bufBytes_ = samples * step;
		s->boardCapacity_ = bcap;
		setNonBlocking(s->udp_);
		s->sendStatus(0);                   // the first packet from this side (firewalls)
		s->th_ = std::thread([p = s.get()] { p->rx_ ? p->rxLoop() : p->txLoop(); });
		return s;
	}

	~Stream()
	{
		{
			std::unique_lock<std::mutex> lock(m_);
			if (!rx_)                       // TX: send what is queued first
				cv_.wait_for(lock, std::chrono::seconds(10), [&] { return (q_.empty() && !busy_) || error_; });
			stop_ = true;
			cv_.notify_all();
		}
		if (th_.joinable())
			th_.join();
		if (udp_ != BAD_SOCK)
			sockClose(udp_);
		if (tcp_ == BAD_SOCK)
			return;
		// TX: tell the board how many packets were sent (the close can overtake packets still
		// queued on the way, e.g. by fq_codel). The board closes its end once the stream is
		// over (TX: its DMA has sent all), so the device is free again when this returns.
		if (!rx_) {
			char line[32];
			snprintf(line, sizeof line, "END %u\n", dataSeq_);
			sendAll(tcp_, line, strlen(line));
		}
		shutdown(tcp_, SHUT_SEND);          // ends the stream on the board
		char c;
		while (sockPoll(tcp_, 10000) > 0 && recv(tcp_, &c, 1, 0) > 0)
			;
		sockClose(tcp_);
	}

	size_t step() const { return step_; }
	size_t bufBytes() const { return bufBytes_; }
	size_t frame() const { return frame_; }

	// RX: the next buffer into buf (the old one goes back as a spare); bytes, 0 = timeout, -1 = error
	long take(std::vector<char> &buf, int timeoutMs, bool &lost)
	{
		std::unique_lock<std::mutex> lock(m_);
		if (!cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [&] { return !q_.empty() || error_; }))
			return 0;
		if (q_.empty())
			return -1;
		Buf b = std::move(q_.front());
		q_.pop_front();
		std::swap(buf, b.data);
		if (!b.data.empty())
			spare_.push_back(std::move(b.data));
		cv_.notify_all();
		lost = b.lost;
		return (long)b.len;
	}

	// TX: queue len bytes of buf (buf gets a spare to fill next); 0, -1 = error, -2 = timeout
	int put(std::vector<char> &buf, size_t len, int timeoutMs)
	{
		std::unique_lock<std::mutex> lock(m_);
		if (!cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [&] { return q_.size() < DEPTH || error_; }))
			return -2;
		if (error_)
			return -1;
		Buf b;
		b.len = len;
		b.data = takeSpare();
		std::swap(buf, b.data);
		q_.push_back(std::move(b));
		cv_.notify_all();
		return 0;
	}

private:
	static const size_t DEPTH = 8;          // buffers queued between the thread and the stream

	Stream() = default;

	static void setBuffers(sock_t s)
	{
		int sz = 32 << 20;
#ifdef SO_RCVBUFFORCE
		if (setsockopt(s, SOL_SOCKET, SO_RCVBUFFORCE, &sz, sizeof sz) != 0)
#endif
			setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&sz, sizeof sz);
#ifdef SO_SNDBUFFORCE
		if (setsockopt(s, SOL_SOCKET, SO_SNDBUFFORCE, &sz, sizeof sz) != 0)
#endif
			setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&sz, sizeof sz);
	}

	static size_t defaultFrame(sock_t tcp)
	{
#if defined(_WIN32)
		(void)tcp;
		return 8000;
#elif defined(IP_MTU)
		int mtu = 0;
		socklen_t l = sizeof mtu;
		if (getsockopt(tcp, IPPROTO_IP, IP_MTU, &mtu, &l) == 0 && mtu > 576)
			return std::min<size_t>(size_t(mtu) - 28, 8000);
		return 1472;
#else
		(void)tcp;
		return 1472;
#endif
	}

	static unsigned port(const sockaddr_storage &a)
	{
		return ntohs(a.ss_family == AF_INET ? ((const sockaddr_in &)a).sin_port : ((const sockaddr_in6 &)a).sin6_port);
	}

	static void setPort(sockaddr_storage &a, unsigned p)
	{
		if (a.ss_family == AF_INET)
			((sockaddr_in &)a).sin_port = htons((uint16_t)p);
		else
			((sockaddr_in6 &)a).sin6_port = htons((uint16_t)p);
	}

	static bool sendAll(sock_t s, const char *p, size_t n)
	{
		while (n) {
			int k = send(s, p, (int)n, SEND_FLAGS);
			if (k <= 0)
				return false;
			p += k;
			n -= k;
		}
		return true;
	}

	static bool readLine(sock_t s, std::string &line)
	{
		line.clear();
		char c;
		while (sockPoll(s, 5000) > 0 && recv(s, &c, 1, 0) == 1) {
			if (c == '\n')
				return true;
			line += c;
		}
		return false;
	}

	std::vector<char> takeSpare()           // caller holds m_
	{
		if (spare_.empty())
			return std::vector<char>(bufBytes_);
		std::vector<char> b = std::move(spare_.back());
		spare_.pop_back();
		return b;
	}

	void sendStatus(uint64_t consumed)
	{
		char pkt[HDR + 8];
		Header h = {MAGIC, TYPE_STATUS, 0, statusSeq_++, 0};
		memcpy(pkt, &h, HDR);
		memcpy(pkt + HDR, &consumed, 8);
		send(udp_, pkt, sizeof pkt, 0);
	}

	void fail()
	{
		std::lock_guard<std::mutex> lock(m_);
		error_ = true;
		cv_.notify_all();
	}

	// RX: packets into buffers (ended by the board's end-of-buffer flag or a full buffer); while the
	// queue is full, the socket is not read, the reports stop, and the board stops sending
	void rxLoop()
	{
		std::vector<char> pkt(frame_);
		Buf cur;
		{
			std::lock_guard<std::mutex> lock(m_);
			cur.data = takeSpare();
		}
		uint64_t consumed = 0, reported = 0, every = std::max<uint64_t>(myCapacity_ / 32, 1);
		uint32_t expect = 0;
		bool first = true;
		for (;;) {
			{
				std::unique_lock<std::mutex> lock(m_);
				cv_.wait(lock, [&] { return stop_ || q_.size() < DEPTH; });
				if (stop_)
					return;
			}
			if (sockPoll(udp_, 100) <= 0)
				continue;
			for (int i = 0; i < 256; i++) {     // what is waiting, then check the queue again
				int k = recv(udp_, pkt.data(), (int)frame_, 0);
				if (k < 0)
					break;
				Header h;
				if (k < (int)HDR)
					continue;
				memcpy(&h, pkt.data(), HDR);
				if (h.magic != MAGIC || h.type != TYPE_DATA)
					continue;
				if (!first && h.seq != expect)
					cur.lost = true;
				first = false;
				expect = h.seq + 1;
				size_t len = std::min<size_t>(size_t(k) - HDR, bufBytes_ - cur.len);
				memcpy(cur.data.data() + cur.len, pkt.data() + HDR, len);
				cur.len += len;
				consumed += size_t(k) - HDR;
				if (cur.len == bufBytes_ || (h.flags & FLAG_END)) {
					std::lock_guard<std::mutex> lock(m_);
					q_.push_back(std::move(cur));
					cur = Buf();
					cur.data = takeSpare();
					cv_.notify_all();
					if (q_.size() >= DEPTH)
						break;
				}
				if (consumed - reported >= every) {
					sendStatus(consumed);
					reported = consumed;
				}
			}
		}
	}

	// TX: buffers into packets within the board's capacity
	void txLoop()
	{
		std::vector<char> pkt(frame_);
		uint64_t sent = 0, boardConsumed = 0;
		char st[64];
		auto readStatus = [&](int ms) {
			if (ms > 0 && sockPoll(udp_, ms) <= 0)
				return;
			for (;;) {
				int k = recv(udp_, st, sizeof st, 0);
				if (k < 0)
					break;          // nothing more waiting (non-blocking socket)
				Header h;
				memcpy(&h, st, HDR);
				if (k >= int(HDR + 8) && h.magic == MAGIC && h.type == TYPE_STATUS) {
					uint64_t c;
					memcpy(&c, st + HDR, 8);
					boardConsumed = std::max(boardConsumed, c);
				}
			}
		};
		for (;;) {
			Buf b;
			{
				std::unique_lock<std::mutex> lock(m_);
				cv_.wait(lock, [&] { return stop_ || !q_.empty(); });
				if (q_.empty())
					return;                 // stopped, nothing left to send
				b = std::move(q_.front());
				q_.pop_front();
				busy_ = true;
			}
			for (size_t off = 0; off < b.len;) {
				size_t len = std::min(payload_, b.len - off);
				readStatus(0);
				while (sent + len - boardConsumed > boardCapacity_ && !stop_)
					readStatus(100);
				Header h = {MAGIC, TYPE_DATA, uint16_t(off + len == b.len ? FLAG_END : 0), dataSeq_++, 0};
				memcpy(pkt.data(), &h, HDR);
				memcpy(pkt.data() + HDR, b.data.data() + off, len);
				int k;
				while ((k = send(udp_, pkt.data(), int(HDR + len), 0)) < 0 && !stop_)
					std::this_thread::sleep_for(std::chrono::microseconds(50));    // send buffer full
				if (k < 0) {
					fail();
					return;
				}
				off += len;
				sent += len;
			}
			std::lock_guard<std::mutex> lock(m_);
			spare_.push_back(std::move(b.data));
			busy_ = false;
			cv_.notify_all();
		}
	}

	bool rx_ = true;
	sock_t tcp_ = BAD_SOCK, udp_ = BAD_SOCK;
	size_t step_ = 0, frame_ = 0, payload_ = 0, bufBytes_ = 0;
	uint64_t myCapacity_ = 0, boardCapacity_ = 0;
	uint32_t statusSeq_ = 0;
	uint32_t dataSeq_ = 0;                  // TX: data packets sent
	std::thread th_;
	std::mutex m_;
	std::condition_variable cv_;
	std::deque<Buf> q_;
	std::vector<std::vector<char>> spare_;
	bool stop_ = false, error_ = false, busy_ = false;
};

} // namespace streamd
