# What this machine and its Docker runtime can take, a lock that works
# with or without flock, and the waits derived from them.

# The host profile, filled once per process by system_profile:
#   os             darwin | linux | ...
#   arch           arm64 | x86_64 | ... (uname -m)
#   cores          host CPUs online
#   ram_mb         host memory, MiB
#   docker_mem_mb  memory of the Docker VM or host, MiB
#   docker_cpus    CPUs Docker can use
#   has_flock      1 when flock(1) is installed, otherwise 0
# A probe that fails leaves its key unset; every consumer then falls back
# to Chalk's fixed defaults.
declare -gA SYS=()
SYS_PROBED=0

system_profile() {
  (( ! SYS_PROBED )) || return 0
  SYS_PROBED=1
  local value mem cpus
  value="$(uname -s 2>/dev/null || true)"
  [[ -z $value ]] || SYS[os]="${value@L}"
  value="$(uname -m 2>/dev/null || true)"
  [[ -z $value ]] || SYS[arch]="$value"

  value="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [[ ! $value =~ ^[1-9][0-9]*$ ]] || SYS[cores]="$value"

  case "${SYS[os]:-}" in
    darwin) value="$(sysctl -n hw.memsize 2>/dev/null || true)" ;;
    linux)  value="$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null || true)" ;;
    *)      value="" ;;
  esac
  [[ ! $value =~ ^[1-9][0-9]*$ ]] || SYS[ram_mb]=$((value / 1048576))

  if command -v docker >/dev/null 2>&1; then
    value="$(docker info --format '{{.MemTotal}} {{.NCPU}}' 2>/dev/null || true)"
    read -r mem cpus _ <<<"$value" || true
    [[ ! ${mem:-} =~ ^[1-9][0-9]*$ ]] || SYS[docker_mem_mb]=$((mem / 1048576))
    [[ ! ${cpus:-} =~ ^[1-9][0-9]*$ ]] || SYS[docker_cpus]="$cpus"
  fi

  if command -v flock >/dev/null 2>&1; then SYS[has_flock]=1; else SYS[has_flock]=0; fi
}

# True when Docker is known to have little room: under 4 CPUs or 4 GiB.
system_docker_small() {
  system_profile
  (( ${SYS[docker_cpus]:-4} < 4 || ${SYS[docker_mem_mb]:-4096} < 4096 ))
}

# system_timeout BASE OVERRIDE [FRESH] -> REPLY: seconds to wait for a
# service. OVERRIDE, a CHALK_*_TIMEOUT value, wins when it is a positive
# whole number. Otherwise BASE, doubled on a small Docker or when FRESH is 1
# (the container is initialising its data for the first time).
system_timeout() {
  if [[ $2 =~ ^[1-9][0-9]*$ ]]; then
    REPLY="$2"
  elif [[ ${3:-0} == 1 ]] || system_docker_small; then
    REPLY=$(($1 * 2))
  else
    REPLY="$1"
  fi
}

# Machine-wide locks. With flock the kernel releases a lock when its holder
# exits. Without it (stock macOS) a lock is a directory made with mkdir,
# which is atomic, and a lock whose holder died is cleared by the next
# process that wants it (chalk_lock_clear). Either way the holder's pid is
# written into it.
#
#   chalk_lock db 300 || die "..."
#   ... create the thing only one process may create ...
#   chalk_unlock db
#
# Under flock the lock lives on an open file descriptor, which child
# processes inherit: start a long-lived child with {fd}>&- or release first.

declare -gA CHALK_LOCK_FDS=()   # name -> fd, for locks held through flock

# chalk_lock_path NAME -> REPLY
chalk_lock_path() {
  REPLY="${XDG_STATE_HOME:-$HOME/.local/state}/chalk/locks/$1"
}

# chalk_lock NAME [SECONDS]: takes the lock NAME, waiting up to SECONDS
# (default 60; 0 tries once). Returns non-zero when it is still held by
# someone else after that.
chalk_lock() {
  local name="$1" wait="${2:-60}" path fd deadline
  path="${| chalk_lock_path "$name"; }"
  mkdir -p "${path%/*}"
  system_profile

  if [[ ${SYS[has_flock]:-0} == 1 ]]; then
    local -a mode=(-w "$wait")
    (( wait > 0 )) || mode=(-n)
    exec {fd}>>"$path.lock"
    if ! flock "${mode[@]}" "$fd"; then
      exec {fd}>&-
      return 1
    fi
    printf '%s\n' "$BASHPID" > "$path.lock"
    CHALK_LOCK_FDS[$name]="$fd"
    return 0
  fi

  deadline=$((EPOCHSECONDS + wait))
  until mkdir "$path" 2>/dev/null; do
    # A holder that died left its lock behind: clear it, then try again.
    if chalk_lock_stale "$path" && chalk_lock_clear "$path"; then continue; fi
    (( EPOCHSECONDS < deadline )) || return 1
    sleep 0.1
  done
  printf '%s\n' "$BASHPID" > "$path/pid"
}

# Seconds a mkdir lock may go without a pid before it counts as abandoned.
# Its holder writes the pid straight after mkdir, so a lock with none for
# this long belongs to a process that died in between.
CHALK_LOCK_GRACE=10

# chalk_lock_age PATH -> REPLY: seconds since PATH was last modified; empty
# when it is missing or its age cannot be read.
chalk_lock_age() {
  local mtime
  REPLY=""
  # GNU stat first, then BSD (macOS) stat.
  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)"
  [[ ! $mtime =~ ^[0-9]+$ ]] || REPLY=$((EPOCHSECONDS - mtime))
}

# True when the mkdir lock at PATH names a holder that is no longer alive,
# or has had no pid for CHALK_LOCK_GRACE seconds. A lock that got no pid
# more recently is being taken right now, so it is not stale.
chalk_lock_stale() {
  local pid="" age
  [[ -d $1 ]] || return 1
  { read -r pid < "$1/pid"; } 2>/dev/null || true
  if [[ -n $pid ]]; then
    ! kill -0 "$pid" 2>/dev/null
  else
    age="${| chalk_lock_age "$1"; }"
    [[ -n $age ]] && (( age >= CHALK_LOCK_GRACE ))
  fi
}

# chalk_lock_clear PATH: removes the stale mkdir lock at PATH. Returns
# non-zero when it removed nothing.
#
# Two waiters can find the same lock stale. If both removed it, the first
# could remove it and take it afresh, then lose it to the second's removal,
# and both would hold it. So clearing has a lock of its own, PATH.clear,
# also taken with mkdir: one waiter at a time clears, and only after
# checking again, under it, that the lock is still stale. PATH.clear is held
# for a moment; one left by a process that died holding it is removed once
# it is CHALK_LOCK_GRACE seconds old.
chalk_lock_clear() {
  local path="$1" guard="$1.clear" age status=1
  if ! mkdir "$guard" 2>/dev/null; then
    age="${| chalk_lock_age "$guard"; }"
    if [[ -n $age ]] && (( age >= CHALK_LOCK_GRACE )); then rmdir "$guard" 2>/dev/null || true; fi
    return 1
  fi
  if chalk_lock_stale "$path"; then
    rm -rf "$path"
    status=0
  fi
  rmdir "$guard" 2>/dev/null || true
  return "$status"
}

# chalk_unlock NAME: releases a lock this process holds; otherwise does nothing.
chalk_unlock() {
  local name="$1" path pid fd
  if [[ -v CHALK_LOCK_FDS[$name] ]]; then
    fd="${CHALK_LOCK_FDS[$name]}"
    unset 'CHALK_LOCK_FDS[$name]'
    exec {fd}>&-
    return 0
  fi
  path="${| chalk_lock_path "$name"; }"
  { read -r pid < "$path/pid"; } 2>/dev/null || return 0
  [[ $pid != "$BASHPID" ]] || rm -rf "$path"
}
