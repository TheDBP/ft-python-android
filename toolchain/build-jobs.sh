#!/bin/bash
# build-jobs.sh - print a memory-aware parallel-job count for the native builds.
#
# The heavy C/C++/Fortran compiles (scipy's ducc0 templates especially) can each
# need ~2 GB of RAM. Running one per core OOM-kills the build on modest machines -
# measured: scipy at -j(all cores) on a 16 GB host dies with no error, just a
# SIGKILL. This bounds the job count by AVAILABLE memory, leaving a headroom
# margin, and never exceeds the CPU count:
#
#   jobs = clamp(1, nproc, floor((MemAvailable_GB - HEADROOM_GB) / PER_JOB_GB))
#
# Overrides (environment):
#   FT_BUILD_JOBS       force an exact job count (skips the model entirely) -
#                       useful for CI, or a container with a --memory limit whose
#                       cap /proc/meminfo does not reflect.
#   FT_JOB_HEADROOM_GB  RAM (GB) to leave free for the OS + linker (default 2)
#   FT_MEM_PER_JOB_GB   RAM (GB) budgeted per compile job (default 2)
#
# The supported RAM floor and this model are documented in docs/BUILD.md
# ("Memory and parallelism").
set -euo pipefail

ncpu="$(nproc 2>/dev/null || echo 1)"

# An explicit override wins.
if [ -n "${FT_BUILD_JOBS:-}" ]; then
    echo "${FT_BUILD_JOBS}"
    exit 0
fi

headroom_gb="${FT_JOB_HEADROOM_GB:-2}"
per_job_gb="${FT_MEM_PER_JOB_GB:-2}"

# MemAvailable is the honest "what can we use right now" figure. Note: Docker does
# NOT virtualise /proc/meminfo, so inside a container this reads the HOST/VM total,
# not a --memory cgroup cap; use FT_BUILD_JOBS to pin the count in that case.
avail_kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${avail_kb:-0}" -le 0 ]; then
    echo "${ncpu}"          # meminfo unreadable - fall back to the CPU count
    exit 0
fi

avail_gb=$(( avail_kb / 1024 / 1024 ))
usable_gb=$(( avail_gb - headroom_gb ))
[ "${usable_gb}" -lt "${per_job_gb}" ] && usable_gb="${per_job_gb}"

jobs=$(( usable_gb / per_job_gb ))
[ "${jobs}" -lt 1 ] && jobs=1
[ "${jobs}" -gt "${ncpu}" ] && jobs="${ncpu}"
echo "${jobs}"
