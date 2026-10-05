#!/usr/bin/env bash
# lib/core/system.sh: the host profile, adaptive waits, fleet width and locks.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime core/system fleet

export XDG_STATE_HOME="$tmp/state"
mkdir -p "$tmp/bin"
PATH="$tmp/bin:$PATH"

# profile [DOCKER_MEM_MB DOCKER_CPUS]: sets the host profile by hand, empty
# when no values are given, as when Docker cannot be asked.
profile() {
  SYS=() SYS_PROBED=1
  if (( $# )); then SYS["docker_mem_mb"]="$1" SYS["docker_cpus"]="$2"; fi
}

fails() { ! "$@"; }

# The probe reads Docker's memory in bytes and its CPUs, once per process.
printf '#!/bin/sh\necho "8217751552 12"\n' > "$tmp/bin/docker"
chmod +x "$tmp/bin/docker"
SYS=() SYS_PROBED=0
system_profile
check "docker memory is read in MiB" test "${SYS[docker_mem_mb]}" = 7837
check "docker CPUs are read" test "${SYS[docker_cpus]}" = 12
check "host CPUs are read" test "${SYS[cores]}" -ge 1
check "host memory is read" test "${SYS[ram_mb]}" -ge 1
printf '#!/bin/sh\necho "1 1"\n' > "$tmp/bin/docker"
system_profile
check "the profile is probed once per process" test "${SYS[docker_cpus]}" = 12
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/docker"
SYS=() SYS_PROBED=0
system_profile
check "a failed probe leaves its keys unset" \
  test "${SYS[docker_cpus]-unset}:${SYS[docker_mem_mb]-unset}" = "unset:unset"
check "the other probes still run" test -n "${SYS[cores]}"
rm "$tmp/bin/docker"

# CHALK_MAX_PARALLEL (eng review T2): explicit numbers win, auto adapts,
# an unknown profile keeps the old default of 4.
CHALK_SANDBOX_MEM_MB=2048
CHALK_MAX_PARALLEL=6; profile 8217 12
check "an explicit number is used as given" test "${| fleet_parallel; }" = 6
CHALK_MAX_PARALLEL=auto; profile
check "auto is 4 when the profile is unknown" test "${| fleet_parallel; }" = 4
profile 8217 12
check "auto on an 8 GB, 12 CPU Docker is 3 (memory bound)" test "${| fleet_parallel; }" = 3
profile 32768 16
check "auto on a 32 GB, 16 CPU Docker is 8 (the cap)" test "${| fleet_parallel; }" = 8
profile 65536 6
check "auto on a 6 CPU Docker is 3 (CPU bound)" test "${| fleet_parallel; }" = 3
profile 2048 1
check "auto is never below 1" test "${| fleet_parallel; }" = 1
CHALK_SANDBOX_MEM_MB=4096; profile 32768 16
check "auto follows CHALK_SANDBOX_MEM_MB" test "${| fleet_parallel; }" = 7
CHALK_SANDBOX_MEM_MB=2048

# Waits double on a small Docker or a first initialisation; a number wins.
profile
check "an unknown profile keeps the base wait" test "${| system_timeout 30 auto; }" = 30
profile 8217 12
check "a roomy Docker keeps the base wait" test "${| system_timeout 30 auto; }" = 30
check "a first initialisation doubles the wait" test "${| system_timeout 30 auto 1; }" = 60
profile 3000 12
check "under 4 GiB doubles the wait" test "${| system_timeout 30 auto; }" = 60
profile 8217 2
check "under 4 CPUs doubles the wait" test "${| system_timeout 30 auto; }" = 60
check "a CHALK_*_TIMEOUT number wins" test "${| system_timeout 30 45 1; }" = 45

# Locks, with flock and with mkdir. Without a real flock, a stand-in on the
# same flock(2) call plays it.
if ! command -v flock >/dev/null 2>&1; then
  cat > "$tmp/bin/flock" <<'PERL'
#!/usr/bin/perl
# Stand-in for flock(1): flock [-n | -w SECONDS] FD
use strict; use warnings; use Fcntl qw(:flock); use Time::HiRes qw(sleep time);
my ($nonblock, $wait) = (0, 0);
while (@ARGV > 1) {
  my $arg = shift @ARGV;
  if ($arg eq '-n') { $nonblock = 1 } elsif ($arg eq '-w') { $wait = shift @ARGV }
}
open(my $fh, '>>&=', $ARGV[0]) or die "flock: fd $ARGV[0]: $!\n";
my $deadline = time + $wait;
while (1) {
  exit 0 if flock($fh, LOCK_EX | LOCK_NB);
  exit 1 if $nonblock || time >= $deadline;
  sleep 0.05;
}
PERL
  chmod +x "$tmp/bin/flock"
fi

# other_takes NAME [SECONDS]: tries to take the lock from another process.
other_takes() { ( chalk_lock "$1" "${2:-0}" ); }

lock="${| chalk_lock_path t; }"
for has_flock in 1 0; do
  kind="mkdir"
  (( ! has_flock )) || kind=flock
  profile
  SYS[has_flock]="$has_flock"

  check "$kind: a free lock is taken" chalk_lock t 0
  if (( has_flock )); then holder="$(<"$lock.lock")"; else holder="$(<"$lock/pid")"; fi
  check "$kind: the holder's pid is recorded" test "$holder" = "$BASHPID"
  check "$kind: another process cannot take a held lock" fails other_takes t
  chalk_unlock t
  check "$kind: a released lock can be taken" other_takes t
  # That process ended without releasing it.
  check "$kind: a lock whose holder died is taken over" chalk_lock t 0
  chalk_unlock t

  rm -f "$tmp/held" "$tmp/released"
  ( chalk_lock t 0; touch "$tmp/held"; sleep 0.5; touch "$tmp/released"; chalk_unlock t ) &
  for _ in $(seq 1 50); do [[ -e $tmp/held ]] && break; sleep 0.1; done
  check "$kind: a locker that will not wait gives up" fails other_takes t 0
  check "$kind: a locker that waits gets the lock" chalk_lock t 5
  check "$kind: ... only once the holder released it" test -e "$tmp/released"
  chalk_unlock t
  wait
done

# A mkdir lock left by a dead process, with its pid inside, is cleared.
SYS[has_flock]=0
sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir -p "$lock"
echo "$dead" > "$lock/pid"
check "mkdir: a stale lock left by a dead pid is cleared" chalk_lock t 0
chalk_unlock t
check "mkdir: releasing removes the lock" test ! -e "$lock"
mkdir -p "$lock"
check "mkdir: a lock still being taken (no pid yet) is not cleared" fails chalk_lock t 0

# A holder that died between mkdir and writing its pid left a lock with no
# pid. Once that is older than the grace period, it is cleared.
touch -t 202001010000 "$lock"
check "mkdir: a lock with no pid past the grace period is cleared" chalk_lock t 0
check "mkdir: ... and taken" test "$(<"$lock/pid")" = "$BASHPID"
chalk_unlock t

# Two waiters find the same dead lock stale. The first clears it and takes
# it before the second gets to clear it. Played in that order: A takes the
# lock in another process, then B, having found it stale, clears.
mkdir -p "$lock"
echo "$dead" > "$lock/pid"
check "race: both waiters find the dead lock stale" chalk_lock_stale "$lock"
rm -f "$tmp/a-held" "$tmp/a-done"
( chalk_lock t 0; touch "$tmp/a-held"; until [[ -e $tmp/a-done ]]; do sleep 0.05; done; chalk_unlock t ) &
for _ in $(seq 1 50); do [[ -e $tmp/a-held ]] && break; sleep 0.1; done
holder="$(<"$lock/pid")"
check "race: the first waiter cleared the lock and holds it" kill -0 "$holder"
check "race: the second waiter's clear removes nothing" fails chalk_lock_clear "$lock"
check "race: the first waiter still holds the lock" test "$(<"$lock/pid")" = "$holder"
check "race: the second waiter cannot take it" fails other_takes t
touch "$tmp/a-done"
wait

# The same, when the first waiter has made the lock but not yet written
# its pid: the second must not take that for a dead holder.
mkdir -p "$lock"
check "race: a lock just made, with no pid yet, is not cleared" fails chalk_lock_clear "$lock"
check "race: ... and is kept" test -d "$lock"
rmdir "$lock"

# Clearing has a lock of its own. While another waiter is clearing, a dead
# lock is left to it; a clearing lock abandoned past the grace period is
# removed, and the dead lock is then cleared.
mkdir -p "$lock" "$lock.clear"
echo "$dead" > "$lock/pid"
check "clear: a dead lock is left to the waiter already clearing it" fails chalk_lock_clear "$lock"
check "clear: ... and is kept" test "$(<"$lock/pid")" = "$dead"
touch -t 202001010000 "$lock.clear"
# A generous wait: the check is that it ends at all, and it returns as soon
# as the lock is taken, so a busy machine does not make it fail.
check "clear: an abandoned clearing lock does not block forever" chalk_lock t 10
check "clear: ... the clearing lock is gone" test ! -e "$lock.clear"
chalk_unlock t
