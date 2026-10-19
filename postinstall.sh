#!/bin/bash
# Post-installation script: creates the admin user and grants sudo.
# Run as root at the end of the OS install (preseed late_command, kickstart %post, etc.).
#
# Logging goes to three places, best effort:
#   1. $LOG_FILE (local file, always)
#   2. syslog via logger (journalctl -t parsa-postinstall)
#   3. every log line is POSTed to $NOTIFY_URL (ntfy.sh topic) the moment it is written,
#      so you can follow progress live, and see where it stopped if the script dies.
#      Subscribe at https://ntfy.sh/<topic> or in the ntfy app. Anyone who knows the
#      topic name can read it, so keep this repo private.
#      Uses curl, or wget if curl is missing. After REMOTE_MAX_FAILS consecutive failures
#      it stops trying (so a dead network can't stall the install); at the end, if any
#      line was lost, the whole log file is sent once more.

set -u

ADMIN_USER="annai"
# SHA-512 crypt hash (generate with: openssl passwd -6 '<password>'). Never put the plaintext here.
ADMIN_PASS_HASH='$6$Ab379Sngk/UZJvLT$wNWiVRb3OVszdDFzuG/Hb2d7WgjEKIU132Di3Pi.HzFnFYZUmhcso3HhQBWdeHIA2Z30158o6fOTKt/B4VUyS/'

LOG_FILE="/var/log/parsa-postinstall.log"
NOTIFY_URL="${NOTIFY_URL:-https://ntfy.sh/parsa-postinstall-419daa00c6443961}"

HOST="$(hostname 2>/dev/null || echo unknown)"
FAILED=0

REMOTE_FAILS=0      # consecutive failed POSTs
REMOTE_MAX_FAILS=3
REMOTE_LOST=0       # 1 if any message did not reach the server

# POST one message to $NOTIFY_URL. Returns non-zero on failure.
post() {
    local title="$1" body="$2" rc
    [ -n "$NOTIFY_URL" ] || return 1
    if [ "$REMOTE_FAILS" -ge "$REMOTE_MAX_FAILS" ]; then
        REMOTE_LOST=1
        return 1
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --connect-timeout 3 --max-time 8 -H "Title: $title" -d "$body" "$NOTIFY_URL" >/dev/null 2>&1
        rc=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 8 -O /dev/null --header="Title: $title" --post-data="$body" "$NOTIFY_URL" >/dev/null 2>&1
        rc=$?
    else
        REMOTE_FAILS=$REMOTE_MAX_FAILS
        REMOTE_LOST=1
        return 1
    fi
    if [ $rc -eq 0 ]; then
        REMOTE_FAILS=0
    else
        REMOTE_FAILS=$((REMOTE_FAILS + 1))
        REMOTE_LOST=1
    fi
    return $rc
}

log() {
    local line
    line="$(date '+%F %T') [$HOST] $*"
    echo "$line" >>"$LOG_FILE" 2>/dev/null
    echo "$line" >&2
    logger -t parsa-postinstall -- "$*" 2>/dev/null
    post "$HOST post-install" "$line"
    return 0
}

# Run a command, log its output and exit status, remember failures.
run() {
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    [ -n "$out" ] && log "  output: $out"
    if [ $rc -ne 0 ]; then
        log "FAILED (rc=$rc): $*"
        FAILED=1
    fi
    return $rc
}

tmo() { if command -v timeout >/dev/null 2>&1; then timeout 300 "$@"; else "$@"; fi; }

# Install curl/wget (and CA certificates, needed for https) if missing, so live logging works
# on minimal systems. Prints what it did on stdout; main logs that once logging is possible.
ensure_tools() {
    local need=() out rc
    command -v curl >/dev/null 2>&1 || need+=(curl)
    command -v wget >/dev/null 2>&1 || need+=(wget)
    [ ${#need[@]} -eq 0 ] && return 0
    if [ "$(id -u)" -ne 0 ]; then
        echo "missing ${need[*]} but not root, cannot install"
        return 1
    fi
    echo "missing: ${need[*]}; installing"
    if command -v apt-get >/dev/null 2>&1; then
        out="$(export DEBIAN_FRONTEND=noninteractive
               tmo apt-get update -qq 2>&1
               tmo apt-get install -y -qq "${need[@]}" ca-certificates 2>&1)"; rc=$?
    elif command -v dnf >/dev/null 2>&1; then
        out="$(tmo dnf install -y "${need[@]}" ca-certificates 2>&1)"; rc=$?
    elif command -v yum >/dev/null 2>&1; then
        out="$(tmo yum install -y "${need[@]}" ca-certificates 2>&1)"; rc=$?
    elif command -v zypper >/dev/null 2>&1; then
        out="$(tmo zypper -n install "${need[@]}" ca-certificates 2>&1)"; rc=$?
    elif command -v pacman >/dev/null 2>&1; then
        out="$(tmo pacman -Sy --noconfirm "${need[@]}" ca-certificates 2>&1)"; rc=$?
    else
        echo "no supported package manager (apt-get/dnf/yum/zypper/pacman)"
        return 1
    fi
    echo "package install rc=$rc"
    echo "$out" | tail -n 5
    return $rc
}

# Final status message. If any live message was lost, resend the whole log file once.
notify() {
    local subject="$1"
    REMOTE_FAILS=0   # the network may be back; give it one more chance
    if [ $REMOTE_LOST -eq 1 ]; then
        post "$subject (full log)" "$(cat "$LOG_FILE" 2>/dev/null)"
    else
        post "$subject" "$subject"
    fi
}

main() {
    # Before the first log line, so failed posts don't count against REMOTE_MAX_FAILS.
    local tools_msg
    tools_msg="$(ensure_tools 2>&1)"

    log "=== post-install start ==="
    log "OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")  kernel: $(uname -r)"
    [ -n "$tools_msg" ] && log "ensure_tools: $tools_msg"
    log "tools: curl=$(command -v curl || echo no) wget=$(command -v wget || echo no) uid=$(id -u)"

    if [ "$(id -u)" -ne 0 ]; then
        log "must run as root (uid=$(id -u)); aborting"
        FAILED=1
        return 1
    fi

    # Pick the admin group: 'sudo' on Debian/Ubuntu, 'wheel' on RHEL/Fedora/Arch.
    local group
    if getent group sudo >/dev/null; then group=sudo
    elif getent group wheel >/dev/null; then group=wheel
    else
        log "no sudo/wheel group found; creating 'sudo'"
        run groupadd sudo || return 1
        group=sudo
    fi
    log "admin group: $group"

    if id "$ADMIN_USER" >/dev/null 2>&1; then
        log "user $ADMIN_USER already exists; updating password and group membership"
    else
        log "creating user $ADMIN_USER"
        run useradd -m -s /bin/bash "$ADMIN_USER" || return 1
    fi

    run usermod -p "$ADMIN_PASS_HASH" "$ADMIN_USER"
    run usermod -aG "$group" "$ADMIN_USER"

    # Make sure the group actually has sudo rights (already true by default on Debian/Ubuntu/RHEL).
    if [ "$group" = "sudo" ] && ! grep -rqE '^%sudo\s' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        log "no %sudo rule found; adding /etc/sudoers.d/90-sudo-group"
        echo '%sudo ALL=(ALL:ALL) ALL' >/etc/sudoers.d/90-sudo-group
        chmod 0440 /etc/sudoers.d/90-sudo-group
        run visudo -cf /etc/sudoers.d/90-sudo-group
    fi

    # Verify the result.
    log "verify: $(id "$ADMIN_USER" 2>&1)"
    if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx "$group"; then
        log "verify: $ADMIN_USER is in $group"
    else
        log "verify FAILED: $ADMIN_USER not in $group"
        FAILED=1
    fi
    if [ "$(getent shadow "$ADMIN_USER" | cut -d: -f2)" = "$ADMIN_PASS_HASH" ]; then
        log "verify: password hash set"
    else
        log "verify FAILED: password hash mismatch"
        FAILED=1
    fi
}

main
if [ $FAILED -eq 0 ]; then
    log "=== post-install finished OK ==="
    notify "[$HOST] post-install OK"
else
    log "=== post-install finished WITH ERRORS ==="
    notify "[$HOST] post-install FAILED"
fi
exit $FAILED
