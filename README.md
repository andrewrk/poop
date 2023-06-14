# Performance Optimizer Observation Platform

Stop flushing your performance down the drain.

## Overview

This Linux-only command line tool compares the performance of multiple commands
with a colorful terminal user interface.

Example output (colors are lost here):

```
$ zig-out/bin/poop 'zig-out/bin/poop -h' 'hyperfine -h'
Benchmark 1 (5989 runs): zig-out/bin/poop -h:
  measurement      mean ± σ               min … max                  delta
  wall_time        156.464us ± 50.149us   114.726us … 656.436us      0%
  peak_rss         395K ± 96K             225K … 565K                0%
  cpu_cycles       28710 ± 3576           24078 … 115760             0%
  instructions     24540 ± 0              24540 … 24542              0%
  cache_references 469 ± 51               328 … 898                  0%
  cache_misses     32 ± 66                0 … 389                    0%
  branch_misses    330 ± 105              197 … 3980                 0%
Benchmark 2 (2792 runs): hyperfine -h:
  measurement      mean ± σ               min … max                  delta
  wall_time        1.004ms ± 225.862us    813.217us … 2.283ms        💩+542.1%
  peak_rss         3M ± 101K              3M … 4M                    💩+845.4%
  cpu_cycles       1292937 ± 181343       1171450 … 2589993          💩+4403.4%
  instructions     1804252 ± 977          1803273 … 1809868          💩+7252.2%
  cache_references 40985 ± 1237           35258 … 52664              💩+8641.6%
  cache_misses     5867 ± 7613            137 … 24350                💩+18101.1%
  branch_misses    12419 ± 338            11501 … 13554              💩+3666.1%
```

## Usage

```
Usage: poop [options] <command1> ... <commandN>

Compares the performance of the provided commands.

Options:
 --duration <ms>    (default: 5000) how long to repeatedly sample each command

```

## Building from Source

Tested with [Zig](https://ziglang.org/) `0.11.0-dev.3625+129afba46`.

```
zig build
```

## Comparison with Hyperfine

Poop (so far) is brand new, whereas
[Hyperfine](https://github.com/sharkdp/hyperfine) is a mature project with more
configuration options and generally more polish.

However, poop does report peak memory usage as well as 5 other hardware
counters, which I personally find useful when doing performance testing. Hey,
maybe it will inspire the Hyperfine maintainers to add the extra data points!

Poop does not run the commands in a shell. This has the upside of not
including shell spawning noise in the data points collected, and the downside
of not supporting strings inside the commands.

Poop treats the first command as a reference and the subsequent ones
relative to it, giving the user the choice of the meaning of the coloring of
the deltas. Hyperfine always prints the wall-clock-fastest command first.

Poop is also Linux-only.
