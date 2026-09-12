#!/usr/bin/env bash
#
# deploy-caddy.sh — apply a Caddyfile with a hot reload, never a restart.
#
#   sudo ./deploy-caddy.sh /path/to/new/Caddyfile
#
# The contract this script enforces:
#
#   1. validate before install   — a broken config never reaches /etc/caddy
#   2. hot reload, never restart — `systemctl reload caddy` keeps existing
#                                  connections alive, so www.lingxifox.cn and
#                                  lingxiagent.lingxifox.cn never blink
#   3. roll back on failure      — if the reload or the health check fails, the
#                                  previous config is restored and reloaded
#
# A restart is required exactly once, when moving a host from `admin off` to the
# admin socket (the running process has no API to receive a reload). That path is
# a separate, explicit command — see --bootstrap — and is not part of normal
# deployment.
set -euo pipefail

CONFIG="${CONFIG:-/etc/caddy/Caddyfile}"
ADMIN_ADDRESS="${ADMIN_ADDRESS:-unix//run/caddy/admin.sock}"
BACKUP_DIR="${BACKUP_DIR:-/etc/caddy/backups}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1/schema/config.json}"
HEALTH_HOST="${HEALTH_HOST:-lingxiagent.lingxifox.cn}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"

log()  { printf '  %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Strips the "unix/" scheme from an admin address such as
# "unix//run/caddy/admin.sock", leaving the absolute socket path. Only the
# scheme is removed — the path's own leading slash is part of the path.
admin_socket_path() { printf '%s' "${ADMIN_ADDRESS#unix/}"; }

require_root() {
	[[ $EUID -eq 0 ]] || fail "must run as root (sudo $0 ...)"
}

# health_check probes the local origin, bypassing the CDN, so it verifies what
# Caddy is actually serving right now.
health_check() {
	local code
	code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
		-H "Host: ${HEALTH_HOST}" "${HEALTH_URL}" 2>/dev/null || echo 000)"
	[[ "$code" == "200" ]]
}

reload_caddy() {
	systemctl reload caddy
}

# reload_with_rollback installs a config, reloads, and restores the previous
# config if anything goes wrong.
reload_with_rollback() {
	local staged="$1" backup="$2"

	# Skip the copy when the staged file already is the live config — either the
	# same path or byte-identical content. `install` errors on same-file copies,
	# and re-installing identical bytes would only churn the mtime. The reload
	# still runs, so this path doubles as a no-op convergence check.
	if ! cmp -s "$staged" "$CONFIG" 2>/dev/null; then
		install -m 0644 "$staged" "$CONFIG"
	fi

	if ! reload_caddy; then
		log "reload failed — rolling back to the previous configuration"
		install -m 0644 "$backup" "$CONFIG"
		reload_caddy || fail "rollback reload also failed; a restart is now required"
		fail "deployment rolled back; the live configuration is unchanged"
	fi

	# Give the reload a moment to take effect before probing.
	sleep 1
	if ! health_check; then
		log "health check failed after reload — rolling back"
		install -m 0644 "$backup" "$CONFIG"
		reload_caddy || fail "rollback reload also failed; a restart is now required"
		fail "deployment rolled back; the live configuration is unchanged"
	fi
}

prune_backups() {
	# Keep the most recent backups, drop the rest. Backups are tiny.
	find "$BACKUP_DIR" -maxdepth 1 -name 'Caddyfile.*' -type f -printf '%T@ %p\n' 2>/dev/null \
		| sort -rn | tail -n "+$((KEEP_BACKUPS + 1))" | cut -d' ' -f2- \
		| while read -r old; do rm -f -- "$old"; done
}

bootstrap() {
	# One-time migration from `admin off` to the admin socket. This is the only
	# sanctioned restart, it is not used for routine configuration updates.
	log "bootstrap: migrating from 'admin off' to the admin socket"
	log "this restarts Caddy once; every subsequent deploy is a hot reload"

	local backup="${BACKUP_DIR}/Caddyfile.bootstrap.$(date -u +%Y%m%dT%H%M%SZ)"
	install -m 0644 "$CONFIG" "$backup"
	log "backed up current config to $backup"

	systemctl restart caddy
	sleep 2

	[[ -S "$(admin_socket_path)" ]] || fail "admin socket was not created at $(admin_socket_path)"
	systemctl is-active --quiet caddy || fail "caddy is not active after the restart"
	health_check || fail "health check failed after the restart"

	log "bootstrap complete; the admin socket is live and hot reloads now work"
	ls -l "$(admin_socket_path)" >&2
}

main() {
	require_root
	mkdir -p "$BACKUP_DIR"

	if [[ "${1:-}" == "--bootstrap" ]]; then
		bootstrap
		return
	fi

	local new_config="${1:-}"
	[[ -n "$new_config" ]] || fail "usage: $0 <new-Caddyfile> | $0 --bootstrap"
	[[ -f "$new_config" ]] || fail "no such file: $new_config"

	# Refuse to hot reload when the running process has no admin API — which is
	# exactly the state `admin off` leaves behind. Failing loudly here is better
	# than a reload that silently does nothing.
	if [[ ! -S "$(admin_socket_path)" ]]; then
		fail "no admin socket at $(admin_socket_path); the running Caddy predates the socket (run '$0 --bootstrap' once) or has admin disabled"
	fi

	log "validating $(basename "$new_config")"
	caddy validate --config "$new_config" --adapter caddyfile >/dev/null 2>&1 \
		|| { caddy validate --config "$new_config" --adapter caddyfile; fail "configuration is invalid; nothing was changed"; }

	local backup="${BACKUP_DIR}/Caddyfile.$(date -u +%Y%m%dT%H%M%SZ)"
	install -m 0644 "$CONFIG" "$backup"
	log "backed up current config to $backup"

	log "reloading"
	reload_with_rollback "$new_config" "$backup"

	log "deployment applied; $HEALTH_HOST is serving the new configuration"
	prune_backups
}

main "$@"
