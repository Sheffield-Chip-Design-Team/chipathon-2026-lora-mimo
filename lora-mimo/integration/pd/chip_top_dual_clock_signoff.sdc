# chip_top dual-clock timing constraints -- SIGNOFF-ONLY variant.
#
# This is chip_top_dual_clock.sdc (the P&R SDC) verbatim, plus THREE extra
# multicycle groups at the end -- v28 tacc_accumulate, v29 iq_samp_cnt,
# v30 pcfsm_tick_decrement -- ported from Trouper's own signoff split
# (ip/trouper/rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6_signoff.sdc,
# Trouper commit "trouper_top signoff: split SDC, add signoff-only MCP
# groups v28-v30", 2026-08-27).
#
# Used as SIGNOFF_SDC_FILE only. PNR_SDC_FILE stays chip_top_dual_clock.sdc
# so the placed/routed netlist is unchanged: at the block level Trouper
# found that folding any of these three groups into the P&R SDC perturbs
# the post-GRT resizer into stranding the IQ_CLK root clkbuf with no
# routing access point (DRT-0073, Trouper jobs 5112 / 5122). The chip-level
# floorplan is different, but the failure mode is cheap to avoid and there
# is no upside to relaxing these paths during P&R -- they are timed
# single-cycle in the P&R SDC and simply reported honestly at signoff.
#
# Keep everything above the "v28/v29/v30 signoff-only" banner byte-identical
# to chip_top_dual_clock.sdc. If that file changes, re-sync this one.
# =============================================================================

current_design chip_top
set_units -time ns

create_clock -name HCLK16  -period 62.5  [get_ports HCLK]
create_clock -name IQ_CLK32 -period 31.25 [get_ports IQ_CLK]

set_clock_groups -asynchronous \
    -group [get_clocks HCLK16] \
    -group [get_clocks IQ_CLK32]

# Do not apply I/O delay to either clock input itself. Other top-level I/O
# remains unconstrained pending the package-level pin/interface timing budget.
set_clock_uncertainty 0.5 [get_clocks HCLK16]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK32]

# =============================================================================
# ahb_to_grp_bridge CDC payload bounds (F2, branch timn/ahb-bridge-cdc-review)
#
# set_clock_groups -asynchronous above already makes every HCLK16 <-> IQ_CLK32
# path false. The bundled-data CDC inside u_bridge is safe under that cut ONLY
# if the request / response payload nets settle at their capture flop within
# about one destination-clock period of the synchronized request / ack toggle
# -- the 2-flop synchronizers on request_toggle / acknowledge_toggle give
# ~1-2 destination periods of slack and nothing else bounds the payload. Bound
# just those payload nets with -datapath_only, which checks net delay without
# reintroducing the (meaningless) launch/capture clock relationship. The bound
# is one full destination period -- conservative, meant to catch a gross
# routing blow-up, not to tighten a real path.
#
#   request_addr / request_wdata / request_write : launched by HCLK16,
#       captured in the IQ_CLK32 domain  -> bound to the IQ_CLK32 period.
#   response_rdata : launched by IQ_CLK32, captured in the HCLK16 domain
#       -> bound to the HCLK16 period. If HCLK moves to 25 MHz (Open Risks
#       #4), change 62.5 to 40.0 here and in chip_top_dual_clock.sdc.
# =============================================================================
set brg_req_payload  [get_nets -hierarchical \
    {u_bridge.request_addr[*] u_bridge.request_wdata[*] u_bridge.request_write}]
set brg_resp_payload [get_nets -hierarchical {u_bridge.response_rdata[*]}]
set_max_delay -datapath_only 31.25 -through $brg_req_payload
set_max_delay -datapath_only 62.5  -through $brg_resp_payload

# =============================================================================
# Trouper IQ_CLK32-domain multicycle exceptions, ported from Trouper's own
# standalone P&R SDC (ip/trouper/src/config/pnr_32m_scoped_v25_b6.sdc).
#
# Why this is here: chip_top's landscape P&R (job 4885,
# integration/pd/config_landscape_2235.yaml) showed a -31.71 ns max_ss_125C
# WNS on an IQ_CLK32 path entirely inside u_trouper.u_dec (the decimator's
# HB1 MAC, startpoint _86838_ / net u_trouper.u_dec.hb1_stream[1]). Trouper's
# own standalone P&R closes this same cone honestly with the multicycle
# exceptions below -- chip_top_dual_clock.sdc never had them, because it was
# written from scratch as a minimal two-clock skeleton (see history above),
# not derived from Trouper's SDC. This section ports those exceptions
# in, re-scoped one hierarchy level deeper (`u_trouper.` prefix) to match
# trouper_top's instance name in chip_top.v.
#
# Every block below is "honest" in the same sense the source file documents
# at length: the relaxed source is quasi-static (host/firmware-writable,
# write-gated, or FSM-paced at a known multi-cycle rate) and the exception is
# scoped narrowly (-through <that source> -to <the specific destination
# regs>), not a blanket relaxation of the whole endpoint. See
# ip/trouper/src/config/pnr_32m_scoped_v25_b6.sdc's own revision history
# (v8-v26) for the full derivation and the several silent-no-op bugs that
# history had to fix (Yosys flattens CELL names under hierarchy but keeps NET
# names, so every -through/-to scope below must reference nets, and only the
# nets that are verified to survive synthesis).
#
# NOT ported here (deliberately out of scope for this fix):
#   - Trouper's own create_clock/set_clock_uncertainty/input-output delay
#     statements -- chip_top_dual_clock.sdc already defines IQ_CLK32 and its
#     uncertainty above, and this file's own header says top-level I/O is
#     intentionally left unconstrained pending the package pin budget.
#   - Trouper's set_false_path on RESETB/HOST_CS/SPI_SCK -- chip_top.v's
#     reset port is named HRESETn, not RESETB (RESETB is driven from it
#     internally), and HOST_CS/SPI_SCK are slow host-facing signals that
#     deserve their own explicit review at chip level rather than inheriting
#     block-level exceptions silently.
#
# After adding these, re-run STA on the chip-level route and confirm the
# violator moves off u_dec (and check u_trouper.u_comb.* / u_sc.* / u_tacc.*
# don't have an unscoped sibling cone the way v18-v23 kept finding at the
# block level -- see that history before assuming this is the last fix
# needed).

# --- sc_detector (u_sc) quasi-static boundary-condition sources, MCP=3/2 ----
# rb_sf_cfg/rb_sample_shift/rb_bw_sel are packet-active write-gated
# (host/kHz rate); scoped to the specific symbol-boundary snapshot/reset
# registers they feed, not a blanket -to.
set sc_qs_srcs [get_nets -hierarchical {u_trouper.rb_sf_cfg* u_trouper.rb_sample_shift* u_trouper.rb_bw_sel*}]
set sc_boundary_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.u_sc.sym_cnt[*] \
        u_trouper.u_sc.eval_ci0[*] u_trouper.u_sc.eval_cq0[*] u_trouper.u_sc.eval_E0cur[*] u_trouper.u_sc.eval_E0del[*] \
        u_trouper.u_sc.eval_mag_acc[*] u_trouper.u_sc.eval_e_acc[*] u_trouper.u_sc.eval_step[*] \
        u_trouper.u_sc.eval_busy u_trouper.u_sc.mul_start u_trouper.u_sc.eval_sample_mark[*] \
        u_trouper.u_sc.acc_ci0[*] u_trouper.u_sc.acc_cq0[*] u_trouper.u_sc.acc_E0cur[*] u_trouper.u_sc.acc_E0del[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $sc_qs_srcs -to $sc_boundary_regs
set_multicycle_path 2 -hold  -through $sc_qs_srcs -to $sc_boundary_regs

# --- packet_ctrl_fsm (u_pcfsm) quasi-static timeout-register sources -------
# rb_sf_cfg/rb_sample_shift/rb_bw_sel/rb_pkt_timeout_syms/rb_tacc_window_syms
# only change at host rate; scoped to the acq_cnt/wpend_cnt/pkt_cnt
# down-counters they seed at ST_ACQ_SETUP load time, not the per-tick
# decrement path (which stays honest MCP=1 in the P&R SDC; see v30 below for
# the signoff-only relaxation of that decrement recurrence).
set pcfsm_qs_srcs [get_nets -hierarchical {u_trouper.rb_sf_cfg* u_trouper.rb_sample_shift* u_trouper.rb_bw_sel* \
    u_trouper.rb_pkt_timeout_syms* u_trouper.rb_tacc_window_syms*}]
set pcfsm_timeout_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.u_pcfsm.acq_cnt[*] u_trouper.u_pcfsm.wpend_cnt[*] \
                              u_trouper.u_pcfsm.pkt_cnt[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $pcfsm_qs_srcs -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -through $pcfsm_qs_srcs -to $pcfsm_timeout_regs

# u_pcfsm.lat_timing_ref is stable from the moment it's latched (on sc_lock)
# until the next sc_lock edge, thousands of cycles later -- honest MCP=3 into
# the same timeout regs, computed one cycle later in ST_ACQ_SETUP.
set pcfsm_lat_timing_ref [get_nets -hierarchical {u_trouper.u_pcfsm.lat_timing_ref[*]}]
set_multicycle_path 3 -setup -through $pcfsm_lat_timing_ref -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -through $pcfsm_lat_timing_ref -to $pcfsm_timeout_regs

# u_pcfsm.M_val is packet_ctrl_fsm's own copy of 1<<(sf+sample_shift),
# recomputed every cycle but only actually changing at host rate (same
# quasi-static sf/sample_shift source as above) -- same timeout-reg scope.
set pcfsm_mval [get_nets -hierarchical {u_trouper.u_pcfsm.M_val[*]}]
set_multicycle_path 3 -setup -through $pcfsm_mval -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -through $pcfsm_mval -to $pcfsm_timeout_regs

# --- training_acc (u_tacc) quasi-static window sources, MCP=3/2 ------------
set tacc_qs_srcs [get_nets -hierarchical {u_trouper.rb_tacc_window_syms* u_trouper.rb_sf_cfg* u_trouper.rb_sample_shift* u_trouper.rb_bw_sel*}]
set tacc_window_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.u_tacc.acc_start[*] u_trouper.u_tacc.acc_end[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $tacc_qs_srcs -to $tacc_window_regs
set_multicycle_path 2 -hold  -through $tacc_qs_srcs -to $tacc_window_regs

# --- timing_ref (inside u_sc, but survives synthesis under its top-level-of-
#     trouper_top name) quasi-static sources, MCP=3/2 ----------------------
set timing_ref_reg [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.timing_ref[*]}] \
    -filter {ref_name =~ *dff*}]
set timing_ref_hits_srcs [get_nets -hierarchical {u_trouper.rb_sc_hits_req*}]
set_multicycle_path 3 -setup -through $timing_ref_hits_srcs -to $timing_ref_reg
set_multicycle_path 2 -hold  -through $timing_ref_hits_srcs -to $timing_ref_reg

set timing_ref_cfg_srcs [get_nets -hierarchical {u_trouper.rb_sf_cfg* u_trouper.rb_sample_shift* u_trouper.rb_bw_sel*}]
set_multicycle_path 3 -setup -through $timing_ref_cfg_srcs -to $timing_ref_reg
set_multicycle_path 2 -hold  -through $timing_ref_cfg_srcs -to $timing_ref_reg

# --- psram_buf_ctrl (u_psram) registered barrel-shift cone, MCP=2/1 --------
# sf/sample_shift are write-locked during a packet and del_offset_r/del_n_r
# are only loaded when sf==sf_prev (stable), giving the shifter a >=2-cycle
# settle window before capture.
set bshift_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.u_psram.del_n_r[*] u_trouper.u_psram.del_offset_r[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 2 -setup -to $bshift_regs
set_multicycle_path 1 -hold  -to $bshift_regs

# --- Scoped multicycle: the four paced DSP blocks get 3 cycles ------------
# u_dec (decimator, incl. the HB1/HB2 MACs that produced the -31.71 ns
# violator this section exists to fix), u_sc (Schmidl-Cox), u_tacc (training
# accumulator), u_comb (MRC combiner) are all FSM-paced: each only produces a
# new result once every several IQ_CLK32 cycles by construction (e.g.
# mrc_combiner's states 1..10 each hold MAC_WAIT+1 = 3 clocks), so a 3-cycle
# setup budget is honest, not a hack. Net names retain hierarchy after
# flatten; cell names do not -- hence -through on nets, never -through on
# `*u_dec*`-style cell wildcards (see the v8 silent-no-op bug in the source
# file this was ported from).
set paced_nets [get_nets -hierarchical {u_trouper.u_dec.* u_trouper.u_sc.* u_trouper.u_tacc.* u_trouper.u_comb.*}]

set_multicycle_path 3 -setup -through $paced_nets
set_multicycle_path 2 -hold  -through $paced_nets

# --- 16 MHz clock-enable domain: reg_bank write decode (MCP=2) ------------
# reg_bank is gated by ce_16m (updates every other cycle) and the write bus
# is CE-latched in the same phase, so this is a genuine 2-cycle path.
set rb_write_bus [get_nets -hierarchical {u_trouper.rb_we u_trouper.rb_addr[*] u_trouper.rb_wdata[*]}]
set_multicycle_path 2 -setup -through $rb_write_bus
set_multicycle_path 1 -hold  -through $rb_write_bus

# =============================================================================
# v28 / v29 / v30 -- SIGNOFF-ONLY groups. Present in this file, ABSENT in
# chip_top_dual_clock.sdc (the P&R SDC). Ported from Trouper's
# pnr_32m_scoped_v25_b6_signoff.sdc (2026-08-27), re-scoped `u_trouper.`.
#
# All three relax paths that Trouper's `paced_dsp` -through wildcard is meant
# to cover but never matches, because the driven net keeps its top-level
# (trouper_top) name rather than a `u_*`-prefixed one after flatten -- the
# same "output net keeps its top-level name, the u_*-wildcard misses it"
# failure mode as v21 (timing_ref), v22 (acc_ci0), v27 (M_val write arc). At
# chip level those nets sit one level down under `u_trouper.`, so the scopes
# below prefix `u_trouper.` and are otherwise identical to Trouper's.
# =============================================================================

# ==== v28 -- training_acc Zpair_i*/Zpair_q*/Zdiag_* accumulate recurrence ====
# training_acc's 32-bit accumulator outputs are wired straight through to
# trouper_top's `Zpair_i/Zpair_q [0:5]` / `Zdiag [0:3]` wire arrays for
# reg_bank readback (trouper_top.v:329-332), so post-synthesis the driving
# flops' Q nets keep the trouper_top-level names `Zpair_q[3][10]` etc. -- at
# chip level `u_trouper.Zpair_q[3][10]`, never `u_trouper.u_tacc.Zpair_q3`.
# The MAC into these accumulators is the same TDM_WAIT=2 pacing that
# `paced_dsp` already covers (one advance per 3 clocks, 16 steps per 64-clock
# iq_valid sample; training_acc.v:40,89-97), proven by Trouper's
# test_mcp_tacc_settle.py (SGE job 4083, 8/8). Every functional write to
# these accumulators is that paced accumulate (guarded by
# `acc_active && active_cycle`, training_acc.v:298) or the constant zero-load
# at arm (training_acc.v:250-256) -- no fast operand -- so a bare `-to`
# endpoint scope is honest, same as the bshift_regs precedent above.
# These are 2-D wire arrays flattened to escaped names like `Zpair_q[3][10]`;
# a `[*]` bus glob is unreliable against a doubly-subscripted name, so use a
# plain trailing `*` (no other net shares the `u_trouper.Zpair*` /
# `u_trouper.Zdiag*` prefixes).
set tacc_acc_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.Zpair_i* u_trouper.Zpair_q* u_trouper.Zdiag*}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -to $tacc_acc_regs
set_multicycle_path 2 -hold  -to $tacc_acc_regs

# ==== v29 -- dcr_valid -> iq_samp_cnt[*] top-level sample counter ====
# trouper_top.v:171 `if (dcr_valid) iq_samp_cnt <= iq_samp_cnt + 32'd1`.
# iq_samp_cnt is a trouper_top-level net (chip level: u_trouper.iq_samp_cnt),
# so `paced_dsp`'s `-through u_dec.*` wildcard never covered it. Genuinely
# idle-bound, same class as paced_dsp: `dcr_valid` is a 1-clock pulse once
# per HB2 output frame (sd_decimator_poly.v:348 raises iq_valid on
# hb2_stream_last only, zeroed every other cycle; dc_removal.v:110 is a
# 1-cycle registered passthrough), so the increment recurrence has ~63 idle
# IQ_CLK cycles between launches. Consumers (u_psram circular write ptr,
# u_pcfsm per-sample deadline counters) sample it on that same
# dcr_valid/iq_tick cadence, so the value is fully settled before any read.
# PROOF: Trouper test_mcp_iq_samp_cnt_settle.py, SGE job 5120, 3/3 -- (1)
# dcr_valid never high on two consecutive IQ_CLK edges (min spacing 64), (2)
# iq_samp_cnt only ever +1, min gap 64 cycles (21x the 3-cycle budget), (3)
# reset-mid-stream clears to 0 and re-arms. No adjacent launch edge -> the
# 2-hold reference edge carries identical data, so hold is safe. Only writes
# are the async reset and the +1 -> bare `-to` scope is honest.
set iq_samp_cnt_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_trouper.iq_samp_cnt[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -to $iq_samp_cnt_regs
set_multicycle_path 2 -hold  -to $iq_samp_cnt_regs

# ==== v30 -- packet_ctrl_fsm B6 per-sample down-counters, decrement + load ====
# acq_cnt/wpend_cnt/pkt_cnt ($pcfsm_timeout_regs, defined above). Two write
# arcs land here that the v21/v24-class -through blocks above do NOT cover:
#
#  (A) LOAD, sample_count operand (ST_ACQ_SETUP, packet_ctrl_fsm.v:223-225):
#      cnt <= clamp(span + 1 - elapsed_c - iq_tick),
#      elapsed_c = sample_count[19:0] - lat_timing_ref[19:0] (v:114).
#      span/M_val/lat_timing_ref are already MCP=3 above. The ST_ACQ_SETUP
#      dwell (setup_cnt 0->3, capture at 3; v:205-227) was added specifically
#      to give this cone 3 settled edges, and the `- iq_tick` term
#      (v:115-117) corrects a tick landing in the dwell -- so MCP=3 on the
#      whole load arc, sample_count included, matches the RTL design intent.
#
#  (B) DECREMENT recurrence (ST_PREAMBLE_ACQ/ST_W_PENDING/ST_PAYLOAD_ACTIVE,
#      v:166-170): `if (iq_tick) cnt <= cnt - 1`. Fires only on
#      iq_tick == dcr_valid, proven a 1-clock pulse with >=64-cycle spacing
#      (Trouper test_mcp_iq_samp_cnt_settle.py::test_dcr_valid_single_cycle,
#      SGE job 5120) -> ~63 idle IQ_CLK cycles between launches, same
#      idle-bound class as paced_dsp / iq_samp_cnt. No adjacent launch edge
#      -> the 2-hold reference edge carries identical data.
#
# The only writes to these regs are the load, the decrement, and the async
# reset (v:135-137) -> a bare `-to` is honest (bshift_regs / v28 / v29
# precedent).
set_multicycle_path 3 -setup -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -to $pcfsm_timeout_regs

# MCP audit contract, carried over for parity with Trouper's own SDC. No
# chip-level equivalent of ip/trouper/rtl-test/ol_trouper_top/mcp_audit.tcl
# exists yet -- this table is informational until one is written to source
# this file and check the chip-level netlist against it the same way.
# The last three rows are the signoff-only v28/v29/v30 groups (empty source
# collection -> bare `-to` endpoint scope).
set mcp_audit_groups {
    {sc_quasi_static          3 2 sc_qs_srcs           sc_boundary_regs}
    {pcfsm_quasi_static       3 2 pcfsm_qs_srcs        pcfsm_timeout_regs}
    {pcfsm_latched_timing_ref 3 2 pcfsm_lat_timing_ref pcfsm_timeout_regs}
    {pcfsm_mval               3 2 pcfsm_mval           pcfsm_timeout_regs}
    {training_window          3 2 tacc_qs_srcs         tacc_window_regs}
    {timing_ref_hits          3 2 timing_ref_hits_srcs timing_ref_reg}
    {timing_ref_config        3 2 timing_ref_cfg_srcs  timing_ref_reg}
    {psram_barrel_shift       2 1 {}                   bshift_regs}
    {paced_dsp                3 2 paced_nets           {}}
    {regbank_write            2 1 rb_write_bus         {}}
    {tacc_accumulate          3 2 {}                   tacc_acc_regs}
    {iq_samp_cnt              3 2 {}                   iq_samp_cnt_regs}
    {pcfsm_tick_decrement     3 2 {}                   pcfsm_timeout_regs}
}

# --- PSRAM debug readback: quasi-static, false_path -----------------------
# u_trouper.u_psram.dbg_* is the host PSRAM debug-dump path: reads happen at
# SPI speed (kHz) and are hard-gated to idle only. Does NOT touch
# u_trouper.u_psram.state/sub (the live QSPI engine), which stays MCP=1.
set dbg_nets [get_nets -hierarchical {u_trouper.u_psram.dbg_addr_cur[*] u_trouper.u_psram.dbg_buf[*] \
              u_trouper.u_psram.dbg_idx[*] u_trouper.u_psram.dbg_fetch_busy u_trouper.u_psram.dbg_mode u_trouper.u_psram.dbg_pend}]
set_false_path -through $dbg_nets
