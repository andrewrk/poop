# Performance Optimizer Observation Platform

Stop flushing your performance down the drain.

## Overview

This command line tool uses Linux's `perf` / Darwin's `kperf` functionality to compare the performance of multiple commands with a colorful terminal user interface.

![image](https://github.com/andrewrk/poop/assets/106511/6fc9d22b-f95b-46ce-8dc5-d5cecc77c226)

## Usage

```
Usage: poop [options] <command1> ... <commandN>

Compares the performance of the provided commands.

Options:
 --duration <ms>    (default: 5000) how long to repeatedly sample each command

```

## Building from Source

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

Poop does not support running the commands in a shell. This has the upside of
not including shell spawning noise in the data points collected, and the
downside of not supporting strings inside the commands. Hyperfine by default
runs the commands in a shell, with command line options to disable this.

Poop treats the first command as a reference and the subsequent ones relative
to it, giving the user the choice of the meaning of the coloring of the deltas.
Hyperfine by default prints the wall-clock-fastest command first, with a command
line option to select a different reference command explicitly.

While Hyperfine is cross-platform, Poop is Linux-only.
