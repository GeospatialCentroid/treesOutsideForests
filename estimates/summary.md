Step 1: one number per cell

The driver (00_run_estimates.R) reads the sample list and the model table and gives every sampled cell three areas: its footprint, its eligible area, and its TOF area. In table mode those come straight from the pixel counts, one count being one square metre. The cell's own TOF share is never used on its own. It only feeds the MLRA sums.

Step 2: the MLRA estimate is a ratio of sums

Every cell in an MLRA was drawn with the same probability from a regular lattice, so no cell needs an individual weight. The MLRA estimate in estimate_mlra() is simply the total TOF area in the sampled cells divided by the total denominator area in the same cells. Two things follow from that choice:

- A cell with little land in the denominator counts for less than a full cell, automatically. That is why it beats averaging per-cell percentages.
- The many zero cells pull the ratio down exactly as they should. In MLRA 64, 891 of 1,405 cells hold no TOF at all, and the ratio still comes out at 4.0 percent.

The standard error in ratio_estimate() is the linearised ratio form: the spread of each cell's residual from the fitted ratio, divided by the cell count and the mean denominator. It treats the lattice as a simple random sample, which is slightly conservative.

For 2020, total denominator:

┌──────────┬───────┬────────────────────┬─────────────────────┬──────────┬──────┐
│   MLRA   │ cells │ TOF in sample, km² │ land in sample, km² │ estimate │  SE  │
├──────────┼───────┼────────────────────┼─────────────────────┼──────────┼──────┤
│ 55D (64) │ 1,405 │ 56.3               │ 1,405               │ 4.00 %   │ 0.21 │
├──────────┼───────┼────────────────────┼─────────────────────┼──────────┼──────┤
│ 54 (60)  │ 1,393 │ 19.3               │ 1,393               │ 1.39 %   │ 0.09 │
├──────────┼───────┼────────────────────┼─────────────────────┼──────────┼──────┤
│ 52 (56)  │ 1,394 │ 35.0               │ 1,394               │ 2.51 %   │ 0.12 │
└──────────┴───────┴────────────────────┴─────────────────────┴──────────┴──────┘

Step 3: the LRR combines MLRAs by their real area

The sample says what share of an MLRA is TOF. The MLRA polygon, measured by stratum_areas() against the mask products, says how big that MLRA is. Multiplying the two gives an estimated TOF area for the whole MLRA, and estimate_lrr() sums those across the eleven strata and divides by the summed area. Each MLRA's weight is its share of the LRR's land, not its share of the sample.

This is where the weighting bites. MLRA 55D has the highest TOF share but is small, so it contributes little. MLRA 54 has one of the lowest shares but is the largest stratum, so it contributes the most.

┌────────────┬──────────┬────────────────┬────────┬───────────────┐
│    MLRA    │ estimate │ MLRA area, km² │ weight │ TOF area, km² │

  /clear                        Start a new session with empty context; previous session stays on disk (resumable with /resume)
  /code-review                  3 free /ultrareview · Review the current diff, or a PR number/branch/path target, for correctness bugs and reuse/simplification/efficiency cleanups at the
                                given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use
                                given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use
                                given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use
                                given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use                              given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use                              given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use                              given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use                              given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use
                                given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may include uncertain findings; ultra: deep multi-agent revie…
  /simplify                     Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs; use
                                given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage, may inclu