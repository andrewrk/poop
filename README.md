# Performance Optimizer Observation Platform

Stop flushing your performance down the drain.

## Overview

This command line tool uses Linux's `perf_event_open` functionality to compare the performance of multiple commands
with a colorful terminal user interface.

![image](https://github.com/andrewrk/poop/assets/106511/6fc9d22b-f95b-46ce-8dc5-d5cecc77c226)

## Usage

```
Usage: poop [options] <command1> ... <commandN>

Compares the performance of the provided commands.

Options:
 --duration <ms>    (default: 5000) how long to repeatedly sample each command

```

## Building from Source
`poop` is build using [Zig-0.11](https://ziglang.org/). With Zig 0.11 installed,
building is as simple as running `zig build` in the root directory of the
repository. The resulting binary will be located in `zig-out/bin/poop`.

Most Linux distributions
still ship with Zig 0.10 or even Zig 0.9, so you may download the latest version of
Zig from the [Zig website](https://ziglang.org/download/). Most likely you'll
need the linux-x86_64 xz tarball for your system, that comes with a pre-built
`zig` binary. In order to install it, you can simply extract the tarball using
`xz --decompress` and adding the resulting directory to your `PATH` environment.
Further information can be found [here](https://ziglang.org/learn/getting-started/#direct-download).

Zig has a very fast release cycle, and development of `poop` is tightly coupled
to the development of Zig. Hence, it's possible that updating `poop` may require
updating Zig as well. 

Tested with [Zig](https://ziglang.org/) `0.11.0-dev.3771+128fd7dd0`.

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

While Hyperfine is cross-platform, Poop is Linux-only.
