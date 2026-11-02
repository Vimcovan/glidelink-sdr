# pfb_clock_sync_ccf: unbounded input index in general_work (stall / out-of-bounds read)

**Version:** GNU Radio 3.10.12.0 (radioconda, Windows 11, x86-64); same behaviour on 3.10.9.2 (Ubuntu, WSL2).

## What happens

`digital.pfb_clock_sync_ccf` sometimes

1. stops consuming input while producing output without end (upstream blocks stall), or
2. reads outside its input buffer and the process dies with an access violation / segfault.

## Where

`gr-digital/lib/pfb_clock_sync_ccf_impl.cc`, `general_work`:

- the main loop runs `while (i < noutput_items)` and never compares `count` (the input index) with
  `ninput_items[0]`; `forecast` only asks for `(noutput_items + history()) * sps / osps` items;
- per symbol, `d_k` changes by `sps * (d_rate_f + d_alpha * d_error)`; `d_rate_f` is clipped to
  `±max_dev`, but `d_alpha * d_error` is not bounded, and `d_error` grows with the square of the input
  amplitude;
- when the jump of `d_k` cancels the `sps` samples that `count` advances per symbol, the block keeps
  filtering the same input position, `d_error` stays the same and the state sustains itself (case 1);
  when it overshoots, `count` goes negative or beyond the buffer (case 2). A negative `d_k` at the start
  of a call also makes `count` start at -1 (reads `in[-1]`).

## Evidence

- Windows crash dumps (8 of 8): access violation in volk's complex x real dot product called from
  `fir_filter_ccf::filter`, called from `pfb_clock_sync_ccf` (same return address each time); the first
  element read is already unmapped: once 4 samples before a buffer's start, once past the end of a mapping.
- Offline reproduction, sps 4, 32 filters, loop bw 6.28/200, max_dev 1.5, osps 1: QPSK (RRC 0.35) whose
  amplitude alternates between 1 and 10 every 2 ms. From 0.02 s of input (100 k symbols expected) the block
  produced 12.6 M outputs within 1 s and kept going; error -18.8, rate pinned at -1.5. Alternating between
  1 and 3 runs normally.
- Over the air, sps 2, max_dev 0.05, input from an AGC (normal amplitude): in 3 of 40 runs the block
  stalled right at start-up: 25 k input items read, 174 M items written in 10 s.

## Suggested fix

Stop the loop when `count + d_taps_per_filter + d_sps` would exceed `ninput_items[0]` (return the outputs
produced so far), and keep `count >= 0` (or bound the per-symbol phase change, e.g. clip `d_alpha * d_error`).
