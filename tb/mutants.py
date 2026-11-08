#!/usr/bin/env python3
"""
mutants.py -- hand-written bugs that the tests must catch

    make mutants              all of them (a few minutes)
    python3 tb/mutants.py ib_room_always slice_no_store    just these

Each mutant is an exact text replacement in one RTL file. The script copies rtl/
to build/mut/<name>/, applies the change, builds the testbench that should catch
it, and runs it. The target fails if:

  - a testbench fails on the unmodified RTL (then "caught" would mean nothing;
    each one used is run once without changes first), or
  - a mutant's test still passes (the bug went unnoticed), or
  - a mutant's original text is no longer in the RTL (the code changed, so the
    mutant must be rewritten, or it would silently stop testing anything).

These complement the `ifdef` bugs in `make bugs`. Those stay in the RTL because
the whole-switch test (`make sysbugs`) also runs them. These would clutter it.
No packages needed.
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

VFLAGS = ["--binary", "--timing", "-Wno-fatal", "-Wno-WIDTH", "-Wno-DECLFILENAME",
          "-Wno-TIMESCALEMOD", "-Wno-PINCONNECTEMPTY", "-j", "2"]
CDC = ["cdc/reset_sync.v", "cdc/sync_2ff.v", "cdc/fifo_mem.v", "cdc/wptr_full.v",
       "cdc/rptr_empty.v", "cdc/async_fifo.v"]
MAC = ["eth_mac_tx.v", "eth_mac_rx.v", "axis_skid.v", "eth_mac.v"]
SW = ["ingress_buf.v", "mac_table.v", "switch_core.v", "eth_switch_4port.v"]

# testbench -> (RTL files it builds, list of runs; caught if ANY run fails)
TESTS = {
    "tb_ingress_buf": (["ingress_buf.v"], [[]]),
    "tb_mac_table":   (["mac_table.v"], [[]]),
    "tb_switch_core": (["switch_core.v"], [[]]),
    "tb_mac_loop":    (CDC + MAC, [["+verilator+error+limit+1000"] + c.split() for c in
                                   ["+SYS_MHZ=156.25", "+SYS_MHZ=125 +GMII_MHZ=125", "+SYS_MHZ=125.0125",
                                    "+SYS_MHZ=250", "+SYS_MHZ=100 +SLOW"]]),
    "tb_switch":      (CDC + MAC + SW, [["+N=300", "+LOAD=20"]]),
}

# name, what the bug is, RTL file, [(original text, replacement)], testbench
MUTANTS = [
    # ingress buffer
    ("ib_room_no_wrap", "Room check ignores the wrap bit", "ingress_buf.v",
     [("wire        room = !((wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]));",
       "wire        room = (wr_ptr[AW-1:0] != rd_ptr[AW-1:0]);")], "tb_ingress_buf"),
    ("ib_room_always", "Room check always true", "ingress_buf.v",
     [("wire        room = !((wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]));",
       "wire        room = 1'b1;")], "tb_ingress_buf"),
    ("ib_learn_mcast", "Learn request ignores the multicast check", "ingress_buf.v",
     [("if (commit_q && !cap_src[40])", "if (commit_q)")], "tb_ingress_buf"),
    ("ib_learn_never", "Learn request never raised", "ingress_buf.v",
     [("learn_valid <= 1'b1; learn_mac <= cap_src;", "learn_valid <= 1'b0; learn_mac <= cap_src;")],
     "tb_ingress_buf"),
    ("ib_pf_no_room", "Prefetch ignores FIFO room", "ingress_buf.v",
     [("rd_en   = (f_state == F_FETCH) && (pf_used != 3'd4);", "rd_en   = (f_state == F_FETCH);")],
     "tb_ingress_buf"),
    ("ib_pf_one_byte", "Prefetch allows only one byte at a time", "ingress_buf.v",
     [("rd_en   = (f_state == F_FETCH) && (pf_used != 3'd4);",
       "rd_en   = (f_state == F_FETCH) && (pf_used == 3'd0);")], "tb_ingress_buf"),
    ("ib_free_on_fetch", "Space released on fetch, not delivery", "ingress_buf.v",
     [("fetch_ptr <= fetch_ptr + 1'b1;", "fetch_ptr <= fetch_ptr + 1'b1; rd_ptr <= rd_ptr + 1'b1;"),
      ("rd_ptr <= rd_ptr + 1'b1;\n                    if (out_tlast) begin", "if (out_tlast) begin")],
     "tb_ingress_buf"),
    ("ib_tlast_early", "`tlast` one byte early", "ingress_buf.v",
     [("if (rd_en)    rd_last <= f_last;", "if (rd_en)    rd_last <= (f_cnt == head_len - 2'd2);")],
     "tb_ingress_buf"),
    ("ib_drop_no_fetch", "`drop` does not advance `fetch_ptr`", "ingress_buf.v",
     [("fetch_ptr <= fetch_ptr + {{(AW-10){1'b0}}, head_len};", "")], "tb_ingress_buf"),
    ("ib_no_pop_gap", "No `head_valid` gap after a pop", "ingress_buf.v",
     [("assign head_valid = !q_empty && !just_popped;", "assign head_valid = !q_empty;")], "tb_switch"),
    # MAC table
    ("tbl_valid_kept", "Result not cleared when `lk_en` falls", "mac_table.v",
     [("if (!lk_en[p])", "if (1'b0)")], "tb_mac_table"),
    ("tbl_stage_a_kept", "Stage A lookup not discarded when `lk_en` falls", "mac_table.v",
     [("b_look  <= a_look && lk_en[a_port];", "b_look  <= a_look;")], "tb_mac_table"),
    ("tbl_learn_overlap", "Learns allowed to overlap in the pipeline", "mac_table.v",
     [("take_learn = any && !a_learn && !b_learn;", "take_learn = any;")], "tb_mac_table"),
    ("tbl_hit_stale", "Result never refreshed after the first answer (hit)", "mac_table.v",
     [("lk_hit[p]         <= b_hit;", "if (!lk_valid[p]) lk_hit[p] <= b_hit;")], "tb_mac_table"),
    ("tbl_port_stale", "Result never refreshed after the first answer (port)", "mac_table.v",
     [("lk_port[2*p +: 2] <= b_prt;", "if (!lk_valid[p]) lk_port[2*p +: 2] <= b_prt;")], "tb_mac_table"),
    # switch core
    ("core_no_lk_valid", "Core ignores `lk_valid`", "switch_core.v",
     [("req_q[i]   <= head_valid[i] && lk_valid[i] &&", "req_q[i]   <= head_valid[i] &&"),
      ("drop_q[i]  <= head_valid[i] && lk_valid[i] &&", "drop_q[i]  <= head_valid[i] &&")], "tb_switch_core"),
    ("core_req_active", "`req` not gated with `active`", "switch_core.v",
     [("req[i] = req_q[i] && !active[i];", "req[i] = req_q[i];")], "tb_switch_core"),
    ("core_req_q_active", "`req_q` not computed with `!active`", "switch_core.v",
     [("req_q[i]   <= head_valid[i] && lk_valid[i] && !active[i] &&",
       "req_q[i]   <= head_valid[i] && lk_valid[i] &&")], "tb_switch_core"),
    ("core_drop_head", "`drop` not gated with `head_valid`", "switch_core.v",
     [("drop[i]      = drop_q[i] && head_valid[i];", "drop[i]      = drop_q[i];")], "tb_switch_core"),
    ("core_drop_q_lk", "`drop_q` ignores `lk_valid`", "switch_core.v",
     [("drop_q[i]  <= head_valid[i] && lk_valid[i] &&", "drop_q[i]  <= head_valid[i] &&")], "tb_switch_core"),
    ("core_xmask_d", "`xmask` uses the unregistered mask", "switch_core.v",
     [("xmask[i]  <= mask[i];", "xmask[i]  <= mask_d[i];")], "tb_switch_core"),
    ("core_own_v_d", "`own_v` uses the unregistered mask", "switch_core.v",
     [("if (mask[i][e]) begin own_v[e] <= 1'b1;", "if (mask_d[i][e]) begin own_v[e] <= 1'b1;")],
     "tb_switch_core"),
    # TX register slice and the empty flag
    ("mac_empty_no_slice", "Empty flag ignores the register slice", "eth_mac.v",
     [("(tx_fill == 6'd0) && skid_empty && !(tx_tvalid && tx_tready)",
       "(tx_fill == 6'd0) && !(tx_tvalid && tx_tready)")], "tb_mac_loop"),
    ("mac_empty_no_entry", "Empty flag not cleared by a word entering the slice", "eth_mac.v",
     [("(tx_fill == 6'd0) && skid_empty && !(tx_tvalid && tx_tready)", "(tx_fill == 6'd0) && skid_empty")],
     "tb_mac_loop"),
    ("slice_no_store", "Slice doesn't store the word after a stall", "axis_skid.v",
     [("if (s_fire && m_stall) skid_data <= s_tdata;", "if (1'b0) skid_data <= s_tdata;")], "tb_mac_loop"),
    ("slice_lose_word", "Slice loses the word after a stall", "axis_skid.v",
     [("skid_valid <= 1'b1;", "skid_valid <= 1'b0;")], "tb_mac_loop"),
    ("slice_order", "Slice sends the new word before the stored one", "axis_skid.v",
     [("m_tdata   <= skid_valid ? skid_data : s_tdata;", "m_tdata   <= s_tdata;")], "tb_mac_loop"),
    ("slice_drop_valid", "Slice drops `tvalid` for the stored word", "axis_skid.v",
     [("m_tvalid   <= skid_valid || s_fire;", "m_tvalid   <= s_fire;")], "tb_mac_loop"),
]


def run_mutant(m):
    name, what, rtl_file, edits, tb = m
    root = os.path.join("build", "mut", name)
    shutil.rmtree(root, ignore_errors=True)
    shutil.copytree("rtl", os.path.join(root, "rtl"))
    path = os.path.join(root, "rtl", rtl_file)
    text = open(path).read()
    for old, new in edits:
        if text.count(old) != 1:
            return name, what, tb, "STALE", f"original text found {text.count(old)} times in rtl/{rtl_file}: {old!r}"
        text = text.replace(old, new)
    open(path, "w").write(text)

    files, runs = TESTS[tb]
    rtl = os.path.join(root, "rtl")
    cmd = (["verilator"] + VFLAGS + [f"-I{rtl}", "--Mdir", os.path.join(root, "obj")]
           + [os.path.join(rtl, f) for f in files] + [f"tb/{tb}.sv", "--top-module", tb, "-o", "sim"])
    b = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if b.returncode != 0:
        return name, what, tb, "BUILD FAILED", (b.stdout + b.stderr).strip().splitlines()[-1]
    for args in runs:
        try:
            r = subprocess.run([os.path.join(root, "obj", "sim")] + args, capture_output=True,
                               text=True, check=False, timeout=600)
            out = r.stdout
        except subprocess.TimeoutExpired:
            return name, what, tb, "caught", "simulation hung (timeout)"
        if "RESULT: PASS" not in out:
            first = next((l for l in out.splitlines() if "ERROR" in l), "no RESULT: PASS")
            return name, what, tb, "caught", (" ".join(args) + ": " if len(runs) > 1 else "") + first.strip()
    return name, what, tb, "NOT CAUGHT", "every run passed"


def main():
    want = set(sys.argv[1:])
    unknown = want - {m[0] for m in MUTANTS}
    if unknown:
        sys.exit(f"unknown mutant(s): {', '.join(sorted(unknown))}")
    todo = [m for m in MUTANTS if not want or m[0] in want]
    # one unmodified run per testbench used, which must pass
    baselines = [(f"baseline_{tb}", "unmodified RTL", "eth_mac.v", [], tb)
                 for tb in sorted({m[4] for m in todo})]
    with ThreadPoolExecutor(max_workers=max(1, min(8, (os.cpu_count() or 2) // 2))) as pool:
        base = list(pool.map(run_mutant, baselines))
        results = list(pool.map(run_mutant, todo))
    bad = 0
    for name, what, tb, state, detail in base:
        if state != "NOT CAUGHT":                    # i.e. every run passed
            bad += 1
            print(f"  BASELINE FAILED  {tb}: {detail}")
    if bad:
        sys.exit(f"RESULT: FAIL ({bad} testbench(es) fail without any mutant, so the results would mean nothing)")
    for name, what, tb, state, detail in results:
        print(f"  {state:12} {name:20} {tb:15} {what}")
        if state != "caught":
            bad += 1
            print(f"               {detail}")
    if bad:
        sys.exit(f"RESULT: FAIL ({bad} of {len(results)} mutants not caught or not applicable)")
    print(f"RESULT: PASS (all {len(results)} mutants caught)")


if __name__ == "__main__":
    main()
