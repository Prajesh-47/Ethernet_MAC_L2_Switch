// -----------------------------------------------------------------------------
// tap_switch.cpp -- the switch RTL (Verilator) bridged to 4 Linux TAP devices
//
//   tapN  <->  GMII port N of eth_switch_4port
//
// Linux -> switch: each frame read from tapN is padded to 60 bytes (as a real
//   NIC does), given its FCS, and driven on GMII rx with preamble, SFD and a
//   12-byte gap.
// switch -> Linux: each burst on GMII tx is checked (preamble, SFD, FCS, no
//   tx_er), its FCS is removed, and the frame is written to tapN.
//
// Simulated time only moves while there is work: frames waiting to go in, or
// recent activity on any port. The design has no timers, so pausing changes
// nothing, and an idle network costs no CPU.
//
// Output, in the directory given as the only argument:
//   portN.pcap  every frame on port N, both directions (nanosecond timestamps
//               in simulated time), for Wireshark
//   frames.csv  one line per frame per port, read by demo/check_capture.py
// Timestamps are when the frame's first preamble byte is on the wire.
//
// Prints READY once the taps exist and reset is done. SIGINT/SIGTERM ends the
// run and prints a summary.
// -----------------------------------------------------------------------------
#include "Veth_switch_4port.h"
#include "verilated.h"

#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

static const int NP = 4;
static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

// ---------------- CRC-32 (IEEE 802.3, reflected) ----------------
static uint32_t crc_table[256];
static void crc_init() {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
        crc_table[i] = c;
    }
}
static uint32_t crc32(const uint8_t* d, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = crc_table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
    return ~c;
}
static uint64_t fnv1a(const std::vector<uint8_t>& d) {
    uint64_t h = 1469598103934665603ull;
    for (uint8_t b : d) { h ^= b; h *= 1099511628211ull; }
    return h;
}

// ---------------- capture files ----------------
static FILE* g_csv = nullptr;
static FILE* g_pcap[NP];
static void pcap_open(int p, const std::string& dir) {
    std::string path = dir + "/port" + std::to_string(p) + ".pcap";
    g_pcap[p] = fopen(path.c_str(), "wb");
    if (!g_pcap[p]) { perror(path.c_str()); exit(1); }
    // nanosecond-resolution pcap header, link type 1 (Ethernet)
    uint32_t h[6] = {0xA1B23C4Du, 0x00040002u, 0, 0, 65535, 1};
    fwrite(h, 1, 24, g_pcap[p]);
}
static void record(int p, const char* dir, uint64_t t_ps, const std::vector<uint8_t>& f) {
    uint64_t ns = t_ps / 1000;
    uint32_t r[4] = {uint32_t(ns / 1000000000ull), uint32_t(ns % 1000000000ull), uint32_t(f.size()), uint32_t(f.size())};
    fwrite(r, 1, 16, g_pcap[p]);
    fwrite(f.data(), 1, f.size(), g_pcap[p]);
    auto mac = [&](int o) {
        char s[18];
        snprintf(s, sizeof s, "%02x:%02x:%02x:%02x:%02x:%02x", f[o], f[o + 1], f[o + 2], f[o + 3], f[o + 4], f[o + 5]);
        return std::string(s);
    };
    fprintf(g_csv, "%llu,%d,%s,%zu,%s,%s,%02x%02x,%016llx\n", (unsigned long long)ns, p, dir, f.size(),
            mac(0).c_str(), mac(6).c_str(), f[12], f[13], (unsigned long long)fnv1a(f));
}

// ---------------- TAP ----------------
static int tap_open(const char* name) {
    int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK);
    if (fd < 0) { perror("/dev/net/tun"); exit(1); }
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) { perror("TUNSETIFF (needs a user + network namespace, see demo/run_demo.sh)"); exit(1); }
    return fd;
}

// ---------------- per-port GMII driver and monitor ----------------
struct Port {
    int fd = -1;
    std::deque<std::vector<uint8_t>> inq;   // frames from Linux, not yet on the wire
    std::vector<uint8_t> wire;              // the frame being driven, with preamble and FCS
    size_t pos = 0;
    int gap = 12;                           // idle bytes since the last frame
    std::vector<uint8_t> txbuf;             // GMII tx burst being collected
    bool tx_err = false;
    uint64_t tx_start = 0;                  // time of the burst's first byte
    uint64_t n_in = 0, n_out = 0, n_bad = 0, n_flood = 0, n_filter = 0, n_drop = 0;
};

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <output dir>\n", argv[0]); return 2; }
    std::string dir = argv[1];
    crc_init();
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    Port port[NP];
    for (int p = 0; p < NP; p++) {
        port[p].fd = tap_open(("tap" + std::to_string(p)).c_str());
        pcap_open(p, dir);
    }
    g_csv = fopen((dir + "/frames.csv").c_str(), "w");
    if (!g_csv) { perror("frames.csv"); return 1; }
    fprintf(g_csv, "time_ns,port,dir,len,dst,src,ethertype,hash\n");

    VerilatedContext ctx;
    Veth_switch_4port top{&ctx};
    // all four rx clocks and the tx clock at 125 MHz, system clock at 156.25 MHz
    const uint64_t SYS_HALF = 3200, GMII_HALF = 4000;   // ps
    uint64_t t = 0, next_sys = SYS_HALF, next_gmii = GMII_HALF;
    uint64_t sys_cycles = 0, gmii_cycles = 0;
    top.sys_clk = 0; top.gmii_rx_clk = 0; top.gmii_tx_clk = 0; top.rst_n = 0;
    top.gmii_rxd = 0; top.gmii_rx_dv = 0; top.gmii_rx_er = 0;
    top.eval();

    // Advance to the next clock edge. On a GMII falling edge, sample tx (it
    // changes on the rising edge) and drive the next rx byte of every port.
    // Returns true if any port is busy.
    auto step = [&]() -> bool {
        bool busy = false;
        if (next_sys <= next_gmii) {
            t = next_sys; next_sys += SYS_HALF;
            top.sys_clk = !top.sys_clk;
            if (top.sys_clk) {
                sys_cycles++;
                if (sys_cycles == 50) top.rst_n = 1;
                for (int p = 0; p < NP; p++) {   // sys-clock statistics
                    port[p].n_flood  += (top.stat_flood >> p) & 1;
                    port[p].n_filter += (top.stat_filter >> p) & 1;
                    port[p].n_drop   += (top.stat_ingress_drop >> p) & 1;
                }
            }
            top.eval();
            return false;
        }
        t = next_gmii; next_gmii += GMII_HALF;
        bool rising = !top.gmii_tx_clk;
        top.gmii_rx_clk = rising ? 0xF : 0; top.gmii_tx_clk = rising ? 0xF : 0;
        if (rising) { gmii_cycles++; top.eval(); return false; }
        uint32_t rxd = 0; uint8_t dv = 0;
        for (int p = 0; p < NP; p++) {
            Port& P = port[p];
            // monitor
            bool en = (top.gmii_tx_en >> p) & 1;
            if (en) {
                if (P.txbuf.empty()) P.tx_start = t;
                P.txbuf.push_back((top.gmii_txd >> (8 * p)) & 0xFF);
                if ((top.gmii_tx_er >> p) & 1) P.tx_err = true;
                busy = true;
            } else if (!P.txbuf.empty()) {
                std::vector<uint8_t>& w = P.txbuf;
                bool ok = !P.tx_err && w.size() >= 8 + 64 && w[7] == 0xD5;
                for (int i = 0; ok && i < 7; i++) ok = (w[i] == 0x55);
                if (ok) {
                    std::vector<uint8_t> f(w.begin() + 8, w.end() - 4);
                    uint32_t fcs = w[w.size() - 4] | w[w.size() - 3] << 8 | w[w.size() - 2] << 16 | uint32_t(w[w.size() - 1]) << 24;
                    ok = (crc32(f.data(), f.size()) == fcs);
                    if (ok) {
                        record(p, "out", P.tx_start, f);
                        if (write(P.fd, f.data(), f.size()) < 0) perror("tap write");
                        P.n_out++;
                    }
                }
                if (!ok) { P.n_bad++; fprintf(stderr, "ERROR: port %d: bad frame on GMII tx (%zu bytes)\n", p, w.size()); }
                w.clear(); P.tx_err = false;
                busy = true;
            }
            // driver
            if (P.pos < P.wire.size()) {
                rxd |= uint32_t(P.wire[P.pos++]) << (8 * p); dv |= 1 << p;
                if (P.pos == P.wire.size()) P.gap = 0;
                busy = true;
            } else if (P.gap < 12) {
                P.gap++; busy = true;
            } else if (!P.inq.empty() && top.rst_n) {
                std::vector<uint8_t> f = std::move(P.inq.front());
                P.inq.pop_front();
                while (f.size() < 60) f.push_back(0);                 // a NIC pads to the minimum
                record(p, "in", t, f);
                P.n_in++;
                uint32_t fcs = crc32(f.data(), f.size());
                P.wire.assign(7, 0x55); P.wire.push_back(0xD5);
                P.wire.insert(P.wire.end(), f.begin(), f.end());
                for (int i = 0; i < 4; i++) P.wire.push_back((fcs >> (8 * i)) & 0xFF);
                P.pos = 0;
                rxd |= uint32_t(P.wire[P.pos++]) << (8 * p); dv |= 1 << p;
                busy = true;
            }
        }
        top.gmii_rxd = rxd; top.gmii_rx_dv = dv;
        top.eval();
        return busy;
    };

    auto read_taps = [&](int timeout_ms) {
        struct pollfd pf[NP];
        for (int p = 0; p < NP; p++) pf[p] = {port[p].fd, POLLIN, 0};
        if (poll(pf, NP, timeout_ms) <= 0) return;
        for (int p = 0; p < NP; p++) {
            if (!(pf[p].revents & POLLIN)) continue;
            uint8_t buf[2048];
            ssize_t n;
            while ((n = read(port[p].fd, buf, sizeof buf)) > 0) {
                if (n < 14 || n > 1514) continue;                       // not a frame the switch takes
                port[p].inq.emplace_back(buf, buf + n);
            }
        }
    };

    // reset, then let the clock-domain crossings settle
    while (sys_cycles < 2000) step();
    printf("READY\n");
    fflush(stdout);

    uint64_t active_ps = 0;
    double active_wall = 0;
    // after the last activity, keep running this long (simulated) before
    // pausing: enough for any frame still inside the switch to come out
    const uint64_t IDLE_RUN_PS = 200ull * 1000 * 1000;   // 200 us
    uint64_t last_busy = 0;
    while (!g_stop) {
        bool pending = false;
        for (int p = 0; p < NP; p++) pending |= !port[p].inq.empty();
        if (!pending && t - last_busy > IDLE_RUN_PS) { read_taps(100); continue; }   // paused
        uint64_t t0 = t;
        auto w0 = std::chrono::steady_clock::now();
        for (int i = 0; i < 4000; i++) if (step()) last_busy = t;
        active_wall += std::chrono::duration<double>(std::chrono::steady_clock::now() - w0).count();
        active_ps += t - t0;
        read_taps(0);
    }

    printf("---- summary ----\n");
    for (int p = 0; p < NP; p++)
        printf("port %d: in %llu, out %llu, flooded %llu, filtered %llu, ingress drops %llu, bad on tx %llu\n", p,
               (unsigned long long)port[p].n_in, (unsigned long long)port[p].n_out, (unsigned long long)port[p].n_flood,
               (unsigned long long)port[p].n_filter, (unsigned long long)port[p].n_drop, (unsigned long long)port[p].n_bad);
    printf("simulated %.3f ms while active, which took %.1f s (%.0fx slower than real time)\n",
           active_ps / 1e9, active_wall, active_ps ? active_wall / (active_ps / 1e12) : 0.0);
    for (int p = 0; p < NP; p++) fclose(g_pcap[p]);
    fclose(g_csv);
    top.final();
    return 0;
}
