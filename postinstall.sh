#!/bin/bash
# Post-installation script: creates the admin user and grants sudo.
# Run as root at the end of the OS install (preseed late_command, kickstart %post, etc.).
#
# Logging goes to three places, best effort:
#   1. $LOG_FILE (local file, always)
#   2. syslog via logger (journalctl -t parsa-postinstall)
#   3. a POST of the full log to $NOTIFY_URL when the script finishes (ntfy.sh topic).
#      Subscribe at https://ntfy.sh/<topic> or in the ntfy app. Anyone who knows the
#      topic name can read it, so keep this repo private.

set -u

ADMIN_USER="annai"
# SHA-512 crypt hash (generate with: openssl passwd -6 '<password>'). Never put the plaintext here.
ADMIN_PASS_HASH='$6$Ab379Sngk/UZJvLT$wNWiVRb3OVszdDFzuG/Hb2d7WgjEKIU132Di3Pi.HzFnFYZUmhcso3HhQBWdeHIA2Z30158o6fOTKt/B4VUyS/'

LOG_FILE="/var/log/parsa-postinstall.log"
NOTIFY_URL="${NOTIFY_URL:-https://ntfy.sh/parsa-postinstall-419daa00c6443961}"

HOST="$(hostname 2>/dev/null || echo unknown)"
FAILED=0

log() {
    local line
    line="$(date '+%F %T') [$HOST] $*"
    echo "$line" >>"$LOG_FILE" 2>/dev/null
    echo "$line" >&2
    logger -t parsa-postinstall -- "$*" 2>/dev/null
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

notify() {
    local subject="$1"
    if [ -n "$NOTIFY_URL" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsS --max-time 15 -H "Title: $subject" --data-binary "@$LOG_FILE" "$NOTIFY_URL" >/dev/null 2>&1 \
                && log "log posted to notify URL" || log "POST to notify URL failed"
        else
            log "NOTIFY_URL set but curl not available"
        fi
    fi
}

main() {
    log "=== post-install start ==="
    log "OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")  kernel: $(uname -r)"

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
