# rtl/cdc — clock-domain crossing

These six files are copied unchanged from my async FIFO project:
**https://github.com/Prajesh-47/Asynchronous_FIFO** (commit `0ac84ca`).

That repo holds the full verification for them: a 1.5M-word simulation over
10 clock ratios and a SymbiYosys proof of 19 assertions for every clock ratio.

The MAC uses two instances per port:
- receive:  GMII rx clock  → system clock, 10-bit words {tuser, tlast, data}
- transmit: system clock   → GMII tx clock,  9-bit words {tlast, data}

If you change anything here, change it in the FIFO repo first and re-run its proofs.
