#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:?usage: build-agent.sh <check|linux|windows|both> [run_id] [source_dir] [artifact_root]}"
RUN_ID="${2:-$(date -u +%Y%m%dT%H%M%SZ)}"
SOURCE_DIR="${3:-${CODEX_VM_SOURCE_DIR:?missing CODEX_VM_SOURCE_DIR}}"
ARTIFACT_ROOT="${4:-${CODEX_VM_ARTIFACT_DIR:?missing CODEX_VM_ARTIFACT_DIR}}"

: "${CODEX_VM_BASE_DIR:?missing CODEX_VM_BASE_DIR}"
: "${CODEX_VM_LIFECYCLE_MODE:?reuse}"
: "${CODEX_VM_CODEX_DMG_URL:?missing CODEX_VM_CODEX_DMG_URL}"
: "${CODEX_VM_CODEX_GIT_REF:?missing CODEX_VM_CODEX_GIT_REF}"
: "${CODEX_VM_ENABLE_LINUX_UI_POLISH:?1}"
: "${CODEX_VM_LINUX_ISO_URL:=https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso}"
: "${CODEX_VM_USE_DEFAULT_UBUNTU_TEMPLATE:=0}"
: "${CODEX_VM_LINUX_VM_NAME:?missing CODEX_VM_LINUX_VM_NAME}"
: "${CODEX_VM_LINUX_VM_CPUS:?4}"
: "${CODEX_VM_LINUX_VM_MEMORY_MB:?8192}"
: "${CODEX_VM_LINUX_VM_DISK_GB:?80}"
: "${CODEX_VM_LINUX_VM_OSTYPE:?Ubuntu_64}"
: "${CODEX_VM_LINUX_SSH_PORT:?2222}"
: "${CODEX_VM_LINUX_GUEST_USER:=ramarivera}"
: "${CODEX_VM_LINUX_GUEST_PASSWORD:=ramarivera}"
: "${CODEX_VM_LINUX_WORKSPACE:=/home/${CODEX_VM_LINUX_GUEST_USER}/codex-linux}"
: "${CODEX_VM_GUEST_AUTH_USERS:=}"
: "${CODEX_VM_RETRY_RECREATE_ON_AUTH_FAILURE:=1}"
: "${CODEX_VM_LINUX_BASE_OVA:=}"
: "${CODEX_VM_LINUX_BASE_ISO:=}"
: "${CODEX_VM_WINDOWS_VM_NAME:?missing CODEX_VM_WINDOWS_VM_NAME}"
: "${CODEX_VM_WINDOWS_VM_CPUS:?6}"
: "${CODEX_VM_WINDOWS_VM_MEMORY_MB:?12288}"
: "${CODEX_VM_WINDOWS_VM_DISK_GB:?120}"
: "${CODEX_VM_WINDOWS_VM_OSTYPE:?Windows2019_64}"
: "${CODEX_VM_WINDOWS_SSH_PORT:?2232}"
: "${CODEX_VM_WINDOWS_GUEST_USER:=ramarivera}"
: "${CODEX_VM_WINDOWS_GUEST_PASSWORD:=ramarivera}"
: "${CODEX_VM_WINDOWS_WORKSPACE:?/c/codex-windows/codex-linux}"
: "${CODEX_VM_WINDOWS_BASE_OVA:=}"
: "${CODEX_VM_WINDOWS_BASE_ISO:=}"
: "${CODEX_VM_GUEST_KEY:?$HOME/.ssh/id_ed25519}"

CODEX_VM_WINDOWS_ISO_PATH="${CODEX_VM_WINDOWS_ISO_PATH:-}"
CODEX_VM_BASE_MEDIA_DIR="${CODEX_VM_BASE_MEDIA_DIR:-$CODEX_VM_BASE_DIR/media}"

CODEX_VM_BASE_DIR="${CODEX_VM_BASE_DIR/#\~/$HOME}"
CODEX_VM_BASE_MEDIA_DIR="${CODEX_VM_BASE_MEDIA_DIR/#\~/$HOME}"
CODEX_VM_ARTIFACT_DIR="${CODEX_VM_ARTIFACT_DIR:-$ARTIFACT_ROOT}"
CODEX_VM_ARTIFACT_DIR="${CODEX_VM_ARTIFACT_DIR/#\~/$HOME}"
SOURCE_DIR="${SOURCE_DIR/#\~/$HOME}"
ARTIFACT_ROOT="${ARTIFACT_ROOT/#\~/$HOME}"
CODEX_VM_WINDOWS_ISO_PATH="${CODEX_VM_WINDOWS_ISO_PATH/#\~/$HOME}"
CODEX_VM_LINUX_BASE_ISO="${CODEX_VM_LINUX_BASE_ISO/#\~/$HOME}"
CODEX_VM_WINDOWS_BASE_ISO="${CODEX_VM_WINDOWS_BASE_ISO/#\~/$HOME}"
CODEX_VM_LINUX_BASE_OVA="${CODEX_VM_LINUX_BASE_OVA/#\~/$HOME}"
CODEX_VM_WINDOWS_BASE_OVA="${CODEX_VM_WINDOWS_BASE_OVA/#\~/$HOME}"

mkdir -p "$CODEX_VM_BASE_DIR" "$CODEX_VM_BASE_MEDIA_DIR" "$ARTIFACT_ROOT"

log() { printf '[codex-vm:remote] %s\n' "$*" >&2; }
fatal() { printf '[codex-vm:remote] ERROR: %s\n' "$*" >&2; exit 1; }

port_is_free() {
  local port="$1"
  # Use a bind test (no root required) to detect whether something already
  # listens on the host port. This prevents NAT port-forward rules that appear
  # configured but never actually work due to collisions (common cause of
  # "connection reset by peer" on 127.0.0.1:<forwarded-port>).
  python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
  s.bind(("0.0.0.0", port))
  ok = True
except OSError:
  ok = False
finally:
  try: s.close()
  except Exception: pass
sys.exit(0 if ok else 1)
PY
}

pick_free_port() {
  local preferred="$1"
  local port="$preferred"
  local attempt=0

  if [[ -z "$port" ]]; then
    port="2222"
  fi

  # Try preferred, then walk up a small range, then fall back to an ephemeral
  # port chosen by the kernel.
  while ((attempt < 100)); do
    if port_is_free "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
    attempt=$((attempt + 1))
  done

  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("0.0.0.0", 0))
print(s.getsockname()[1])
s.close()
PY
}

ensure_usable_guest_key() {
  local candidate_key="$1"
  local generated_key="$CODEX_VM_BASE_DIR/.codex-vm/guest-key"

  if [[ -f "$candidate_key" ]] && ssh-keygen -y -P '' -f "$candidate_key" >/dev/null 2>&1; then
    CODEX_VM_GUEST_KEY="$candidate_key"
    return 0
  fi

  mkdir -p "$(dirname "$generated_key")"
  if [[ ! -f "$generated_key" || ! -f "${generated_key}.pub" ]]; then
    ssh-keygen -t ed25519 -N '' -f "$generated_key" -C "codex-vm-autogen" >/dev/null
  fi
  CODEX_VM_GUEST_KEY="$generated_key"
}

guest_askpass_script() {
  local pass="$1"
  local script_file
  local escaped_pass
  script_file="$(mktemp /tmp/codex-vm-askpass.XXXXXX)"
  escaped_pass="$(printf '%s' "$pass" | sed "s/'/'\\''/g")"
  cat > "$script_file" <<EOF_ASKPASS
#!/bin/sh
printf '%s' '$escaped_pass'
EOF_ASKPASS
  chmod 700 "$script_file"
  echo "$script_file"
}

CODEX_VM_GUEST_AUTH_ATTEMPTS=""
CODEX_VM_GUEST_AUTH_MODE=""

reset_auth_attempts() {
  CODEX_VM_GUEST_AUTH_ATTEMPTS=""
  CODEX_VM_GUEST_AUTH_MODE=""
}

capture_auth_attempt() {
  local user="$1"
  local mode="$2"
  local attempt="$3"
  local snippet_file="$4"
  local snippet

  snippet="$(tail -n 3 "$snippet_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  if [[ -z "$snippet" ]]; then
    snippet="(no stderr)"
  fi

  if [[ -z "$CODEX_VM_GUEST_AUTH_ATTEMPTS" ]]; then
    CODEX_VM_GUEST_AUTH_ATTEMPTS="user=${user} mode=${mode} attempt=${attempt} error=${snippet}"
  else
    CODEX_VM_GUEST_AUTH_ATTEMPTS+=" | user=${user} mode=${mode} attempt=${attempt} error=${snippet}"
  fi
}

guest_auth_candidates() {
  local primary_user="$1"
  local candidate_list="${2:-}"
  local raw
  local token
  local -a result=()
  local -a raw_tokens=()
  local -A seen=()

  if [[ -z "$candidate_list" ]]; then
    if [[ -n "${CODEX_VM_GUEST_AUTH_USERS:-}" ]]; then
      candidate_list="${CODEX_VM_GUEST_AUTH_USERS}"
    else
      candidate_list="${primary_user} ubuntu root"
    fi
  fi

  raw="$(printf '%s' "$candidate_list" | tr ',' ' ')"
  raw_tokens=($raw)
  for token in "${raw_tokens[@]}"; do
    if [[ -z "$token" ]]; then
      continue
    fi
    if [[ -z "${seen[$token]-}" ]]; then
      result+=("$token")
      seen["$token"]=1
    fi
  done

  if [[ -z "${seen[$primary_user]-}" ]]; then
    result=("$primary_user" "${result[@]}")
    seen["$primary_user"]=1
  fi

  printf '%s\n' "${result[@]}"
}

guest_home_for_user() {
  local user="$1"
  local home

  home="$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}' | head -n 1)"
  if [[ -z "$home" ]]; then
    if [[ "$user" == "root" ]]; then
      home="/root"
    else
      home="/home/$user"
    fi
  fi
  printf '%s' "$home"
}

format_auth_attempts_for_error() {
  local attempts="$1"
  local max="${2:-3}"
  local IFS='|'
  local -a entries=($attempts)
  local -a kept=()
  local entry
  local i=0

  for entry in "${entries[@]}"; do
    if [[ -n "${entry// /}" ]]; then
      kept+=("$(printf '%s' "$entry" | sed 's/^ *//;s/ *$//')")
    fi
    i=$((i + 1))
    if ((i >= max)); then
      break
    fi
  done

  if (( ${#kept[@]} == 0 )); then
    echo "(no auth attempts recorded)"
    return 0
  fi

  (IFS='; '; printf '%s' "${kept[*]}")
}

run_guest_ssh_once() {
  local user="$1"
  local port="$2"
  local cmd="$3"
  local askpass_script=""
  local askpass_cmd=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o PasswordAuthentication=yes
    -o KbdInteractiveAuthentication=no
    -o BatchMode=no
  )
  local ssh_opts=(
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=15
    -o BatchMode=yes
    -p "$port"
  )

  if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
    local attempt=1
    while ((attempt <= 8)); do
      local attempt_err
      attempt_err="$(mktemp)"
      if ssh -i "$CODEX_VM_GUEST_KEY" \
        -o PasswordAuthentication=no -o PubkeyAuthentication=yes \
        "${ssh_opts[@]}" \
        "$user@127.0.0.1" "$cmd" 2>"$attempt_err"; then
        rm -f "$attempt_err"
        CODEX_VM_GUEST_USER="$user"
        CODEX_VM_GUEST_AUTH_MODE="key"
        return 0
      fi
      capture_auth_attempt "$user" "key" "$attempt" "$attempt_err"
      rm -f "$attempt_err"
      log "SSH key attempt ${attempt}/8 failed for $user@127.0.0.1:$port; retrying..."
      ((attempt += 1))
      sleep 2
    done
  fi

  if [[ -z "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
    return 1
  fi

  askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"

  local attempt=1
  while ((attempt <= 8)); do
    log "Falling back to password SSH for $user@127.0.0.1:$port (attempt ${attempt}/8)"
    local attempt_err
    attempt_err="$(mktemp)"
    if command -v sshpass >/dev/null 2>&1; then
      if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
        ssh "${askpass_cmd[@]}" "${ssh_opts[@]}" "$user@127.0.0.1" "$cmd" 2>"$attempt_err"; then
        rm -f "$askpass_script"
        CODEX_VM_GUEST_USER="$user"
        CODEX_VM_GUEST_AUTH_MODE="password"
        return 0
      fi
      capture_auth_attempt "$user" "sshpass" "$attempt" "$attempt_err"
    fi

    if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:0 \
      setsid ssh "${askpass_cmd[@]}" "${ssh_opts[@]}" "$user@127.0.0.1" "$cmd" < /dev/null 2>"$attempt_err"; then
        rm -f "$attempt_err"
        rm -f "$askpass_script"
        CODEX_VM_GUEST_USER="$user"
        CODEX_VM_GUEST_AUTH_MODE="password"
        return 0
      fi
      capture_auth_attempt "$user" "askpass" "$attempt" "$attempt_err"
      rm -f "$attempt_err"
    ((attempt += 1))
    sleep 2
  done

  rm -f "$askpass_script"
  log "Password SSH failed for $user@127.0.0.1:$port"
  return 1
}

run_guest_ssh() {
  local user="$1"
  local port="$2"
  local cmd="$3"
  local fallback_list="${4:-}"
  local fallback_user
  local -a users=()

  reset_auth_attempts
  mapfile -t users < <(guest_auth_candidates "$user" "$fallback_list")

  for fallback_user in "${users[@]}"; do
    if run_guest_ssh_once "$fallback_user" "$port" "$cmd"; then
      CODEX_VM_GUEST_USER="$fallback_user"
      return 0
    fi
  done

  if [[ -n "$CODEX_VM_GUEST_AUTH_ATTEMPTS" ]]; then
    log "SSH auth attempts: $CODEX_VM_GUEST_AUTH_ATTEMPTS"
  fi
  CODEX_VM_GUEST_AUTH_MODE="failed"
  return 1
}

run_guest_scp_from() {
  local user="$1"
  local port="$2"
  local src="$3"
  local dst="$4"
  local candidate_list="${5:-}"
  reset_auth_attempts
  local askpass_script=""
  local askpass_cmd=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o PasswordAuthentication=yes
    -o KbdInteractiveAuthentication=no
  )
  local scp_opts=(
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -P "$port"
  )
  local -a users=()
  local fallback_user

  mapfile -t users < <(guest_auth_candidates "$user" "$candidate_list")

  for fallback_user in "${users[@]}"; do
    if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
      local attempt=1
      while ((attempt <= 8)); do
        local attempt_err
        attempt_err="$(mktemp)"
        if scp -i "$CODEX_VM_GUEST_KEY" "${scp_opts[@]}" \
          -o BatchMode=yes \
          "$fallback_user@127.0.0.1:$src" "$dst" 2>"$attempt_err"; then
          rm -f "$attempt_err"
          CODEX_VM_GUEST_USER="$fallback_user"
          return 0
        fi
        capture_auth_attempt "$fallback_user" "key" "$attempt" "$attempt_err"
        log "SCP key attempt ${attempt}/8 failed for $fallback_user@127.0.0.1:$port; retrying..."
        rm -f "$attempt_err"
        ((attempt += 1))
        sleep 2
      done
    fi

    if [[ -z "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
      continue
    fi

    askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"
    local attempt=1
    while ((attempt <= 8)); do
      local attempt_err
      attempt_err="$(mktemp)"
      log "Falling back to password SCP for $fallback_user@127.0.0.1:$port (attempt ${attempt}/8)"
      if command -v sshpass >/dev/null 2>&1; then
        if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force \
          sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
          scp "${askpass_cmd[@]}" "${scp_opts[@]}" "$fallback_user@127.0.0.1:$src" "$dst" 2>"$attempt_err"; then
          rm -f "$askpass_script"
          rm -f "$attempt_err"
          CODEX_VM_GUEST_USER="$fallback_user"
          return 0
        fi
      fi

      if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:0 \
        setsid scp "${askpass_cmd[@]}" "${scp_opts[@]}" "$fallback_user@127.0.0.1:$src" "$dst" < /dev/null 2>"$attempt_err"; then
        rm -f "$askpass_script"
        rm -f "$attempt_err"
        CODEX_VM_GUEST_USER="$fallback_user"
        return 0
      fi
      capture_auth_attempt "$fallback_user" "password" "$attempt" "$attempt_err"
      log "Password SCP attempt ${attempt}/8 failed for $fallback_user@127.0.0.1:$port; retrying..."
      rm -f "$askpass_script"
      rm -f "$attempt_err"
      ((attempt += 1))
      sleep 2
    done
  done

  if [[ -n "$CODEX_VM_GUEST_AUTH_ATTEMPTS" ]]; then
    log "SCP auth attempts: $CODEX_VM_GUEST_AUTH_ATTEMPTS"
  fi
  log "Password SCP failed for $user@127.0.0.1:$port"
  return 1
}

vm_exists() {
  VBoxManage showvminfo "$1" --machinereadable >/dev/null 2>&1
}

vm_state() {
  local vm="$1"
  VBoxManage showvminfo "$vm" --machinereadable | awk -F= '/^VMState=/{print $2}'
}

vm_running() {
  local state
  state="$(vm_state "$1")"
  [[ "$state" == '"running"' ]]
}

vm_kill_stale_headless_session() {
  local vm="$1"
  local pids
  pids="$(ps -eo pid=,args= | awk -v vm="$vm" '$0 ~ "VBoxHeadless --comment " vm " --startvm" { print $1 }')"
  if [[ -z "$pids" ]]; then
    return 0
  fi

  log "Found stale VBoxHeadless session(s) for $vm: ${pids//$'\n'/, }"
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill -9 "$pid" 2>/dev/null || true
  done <<< "$pids"
  sleep 2
}

vm_wait_for_session_free() {
  local vm="$1"
  local timeout=40
  local i=0
  local state
  while ((i < timeout)); do
    state="$(vm_state "$vm")"
    if [[ "$state" == '"poweroff"' || "$state" == '"aborted"' || "$state" == '"saved"' ]]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

vm_wait_for_port() {
  local port="$1"
  local timeout="${2:-240}"
  local i=0
  while ((i < timeout)); do
    if command -v nc >/dev/null 2>&1; then
      if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        return 0
      fi
    elif (bash -c ":</dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

vm_wait_for_ssh_server() {
  local port="$1"
  local user="${2:-root}"
  local timeout="${3:-240}"
  local i=0
  local out=""

  while ((i < timeout)); do
    # Fast/accurate: if we can fetch host keys, an SSH server is definitely answering.
    if command -v ssh-keyscan >/dev/null 2>&1; then
      out="$(ssh-keyscan -T 5 -p "$port" 127.0.0.1 2>/dev/null || true)"
      if [[ "$out" == *"ssh-"* ]]; then
        return 0
      fi
    fi

    # We only care that an SSH server is answering; auth can fail.
    out="$(ssh \
      -o PreferredAuthentications=none \
      -o PubkeyAuthentication=no \
      -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o GlobalKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      -p "$port" \
      "$user@127.0.0.1" exit 2>&1 || true)"
    if [[ "$out" == *"Permission denied"* || "$out" == *"no more authentication methods"* ]]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

vm_wait_for_guest_login() {
  local primary_user="$1"
  local port="$2"
  local timeout="${3:-900}"
  local candidate_list="${4:-}"
  local i=0
  local last_log=0
  local attempt_id=1
  local user=""
  local -a users=()
  local attempt_err=""
  local askpass_script=""
  reset_auth_attempts

  mapfile -t users < <(guest_auth_candidates "$primary_user" "$candidate_list")

  while ((i < timeout)); do
    for user in "${users[@]}"; do
      if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
        attempt_err="$(mktemp)"
        if ssh -i "$CODEX_VM_GUEST_KEY" \
          -o PasswordAuthentication=no -o PubkeyAuthentication=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o GlobalKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -o BatchMode=yes \
          -p "$port" \
          "$user@127.0.0.1" "echo codex-vm-ready" >/dev/null 2>"$attempt_err"; then
          rm -f "$attempt_err"
          CODEX_VM_GUEST_USER="$user"
          CODEX_VM_GUEST_AUTH_MODE="key"
          return 0
        fi
        capture_auth_attempt "$user" "key" "$attempt_id" "$attempt_err"
        rm -f "$attempt_err"
        ((attempt_id += 1))
      fi

      if [[ -n "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
        askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"

        if command -v sshpass >/dev/null 2>&1; then
          attempt_err="$(mktemp)"
          if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
            setsid ssh \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o PasswordAuthentication=yes \
            -o KbdInteractiveAuthentication=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o GlobalKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o BatchMode=no \
            -p "$port" \
            "$user@127.0.0.1" "echo codex-vm-ready" >/dev/null 2>"$attempt_err"; then
            rm -f "$attempt_err"
            rm -f "$askpass_script"
            CODEX_VM_GUEST_USER="$user"
            CODEX_VM_GUEST_AUTH_MODE="password"
            return 0
          fi
          capture_auth_attempt "$user" "sshpass" "$attempt_id" "$attempt_err"
          rm -f "$attempt_err"
          ((attempt_id += 1))
        fi

        attempt_err="$(mktemp)"
        if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:1 \
          setsid ssh \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o PasswordAuthentication=yes \
            -o KbdInteractiveAuthentication=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o GlobalKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o BatchMode=no \
            -p "$port" \
            "$user@127.0.0.1" "echo codex-vm-ready" >/dev/null 2>"$attempt_err"; then
            rm -f "$attempt_err"
            rm -f "$askpass_script"
            CODEX_VM_GUEST_USER="$user"
            CODEX_VM_GUEST_AUTH_MODE="password"
            return 0
          fi
          capture_auth_attempt "$user" "askpass" "$attempt_id" "$attempt_err"
          rm -f "$attempt_err"
          ((attempt_id += 1))
          rm -f "$askpass_script"
      fi
    done

    if (( (i - last_log) >= 30 )); then
      log "Waiting for guest SSH login: ${user}@127.0.0.1:${port} (${i}s/${timeout}s)"
      last_log="$i"
    fi

    sleep 2
    i=$((i + 2))
  done

  CODEX_VM_GUEST_AUTH_MODE="failed"
  return 1
}

vm_refresh() {
  local vm="$1"
  local lifecycle_mode="${2:-$CODEX_VM_LIFECYCLE_MODE}"
  if [[ "$lifecycle_mode" == "recreate" ]] && vm_exists "$vm"; then
    log "Recreate mode: removing $vm"
    local attempt=1
    while ((attempt <= 4)); do
      if vm_running "$vm"; then
        VBoxManage controlvm "$vm" acpipoweroff >/dev/null 2>&1 || VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
      fi
      vm_kill_stale_headless_session "$vm"
      VBoxManage unregistervm "$vm" --delete >/dev/null 2>&1 || true
      if ! vm_exists "$vm"; then
        return 0
      fi
      sleep 2
      ((attempt += 1))
    done
    return 1
  fi
}

vm_set_nat_ssh() {
  local vm="$1"
  local port="$2"

  if ! port_is_free "$port"; then
    fatal "requested host SSH forward port is already in use on VM host: $port"
  fi

  # When a VM is running or has an active session, `modifyvm` can fail with a lock error.
  # `controlvm ... natpf1` works on a running VM without needing an exclusive write lock.
  if vm_running "$vm"; then
    VBoxManage controlvm "$vm" natpf1 delete "codex-ssh" >/dev/null 2>&1 || true
    if VBoxManage controlvm "$vm" natpf1 "codex-ssh,tcp,,${port},,22" >/dev/null 2>&1; then
      return 0
    fi
  fi

  VBoxManage modifyvm "$vm" --natpf1 delete "codex-ssh" >/dev/null 2>&1 || true
  VBoxManage modifyvm "$vm" --natpf1 "codex-ssh,tcp,,${port},,22" >/dev/null
}

vm_start() {
  local vm="$1"
  local port="$2"
  local user="${3:-root}"
  local current_state
  local attempt=1
  local started=0

  current_state="$(vm_state "$vm")"
  if [[ "$current_state" == '"running"' ]]; then
    if ! vm_set_nat_ssh "$vm" "$port"; then
      log "VM $vm is already running; keeping existing SSH forwarding to avoid lock conflict"
    fi
    return 0
  fi

  if [[ "$current_state" == '"gurumeditation"' ]]; then
    log "VM $vm is in guru meditation; clearing stale session before restart"
    vm_kill_stale_headless_session "$vm"
    VBoxManage controlvm "$vm" acpipoweroff >/dev/null 2>&1 || VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
    if ! vm_wait_for_session_free "$vm"; then
      vm_kill_stale_headless_session "$vm"
      vm_wait_for_session_free "$vm" || true
    fi
    current_state="$(vm_state "$vm")"
  fi

  if [[ "$current_state" != '"poweroff"' && "$current_state" != '"aborted"' ]]; then
    log "VM $vm state is $current_state; attempting safe stop before restart"
    VBoxManage controlvm "$vm" acpipoweroff >/dev/null 2>&1 || VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
    if ! vm_wait_for_session_free "$vm"; then
      log "VM $vm did not exit cleanly before timeout; proceeding with best-effort attach"
      vm_kill_stale_headless_session "$vm"
      vm_wait_for_session_free "$vm" || true
    fi
  fi

  while ((attempt <= 6)); do
    if ! vm_set_nat_ssh "$vm" "$port"; then
      vm_kill_stale_headless_session "$vm"
      VBoxManage controlvm "$vm" acpipoweroff >/dev/null 2>&1 || VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
      vm_set_nat_ssh "$vm" "$port" || true
    fi

    if vm_running "$vm"; then
      started=1
      break
    fi

    VBoxManage startvm "$vm" --type headless >/dev/null && started=1 && break
    log "startvm attempt ${attempt}/6 failed for $vm; retrying"
    vm_kill_stale_headless_session "$vm"
    sleep 2
    ((attempt += 1))
  done

  if [[ "$started" -ne 1 ]]; then
    if [[ "$CODEX_VM_LIFECYCLE_MODE" == "recreate" ]]; then
      VBoxManage unregistervm "$vm" --delete >/dev/null 2>&1 || true
      return 1
    fi
    VBoxManage unregistervm "$vm" --delete >/dev/null 2>&1 || true
    return 1
  fi
}

vm_import_ova() {
  local vm="$1"
  local ova="$2"
  local cpus="$3"
  local memory="$4"
  local ostype="$5"

  VBoxManage import "$ova" --vsys 0 --vmname "$vm" >/dev/null
  VBoxManage modifyvm "$vm" --cpus "$cpus" --memory "$memory" --ostype "$ostype" --ioapic on >/dev/null
  vm_apply_stability_tweaks "$vm" "$ostype"
}

vm_apply_stability_tweaks() {
  local vm="$1"
  local ostype="$2"

  # Ubuntu 24.04 guests have shown intermittent stalls/hangs under VirtualBox on some hosts.
  # These settings trade a little integration for stability/reproducibility.
  if [[ "$ostype" == Ubuntu_* || "$ostype" == "Ubuntu_64" ]]; then
    VBoxManage modifyvm "$vm" --paravirtprovider minimal >/dev/null 2>&1 || true
    VBoxManage modifyvm "$vm" --rtcuseutc on >/dev/null 2>&1 || true
    # Keep APIC/IOAPIC enabled for 64-bit guests; some VBox builds error if x2APIC is toggled.
    VBoxManage modifyvm "$vm" --apic on --ioapic on >/dev/null 2>&1 || true
    VBoxManage modifyvm "$vm" --nested-hw-virt off >/dev/null 2>&1 || true
    VBoxManage modifyvm "$vm" --hpet on >/dev/null 2>&1 || true

    # Reduce VirtualBox time sync "catch-up" behavior that can coincide with guest stalls.
    VBoxManage setextradata "$vm" "VBoxInternal/Devices/VMMDev/0/Config/GetHostTimeDisabled" "1" >/dev/null 2>&1 || true
    VBoxManage setextradata "$vm" "VBoxInternal/TM/TSCMode" "RealTSCOffset" >/dev/null 2>&1 || true
  fi
}

vm_create_from_iso() {
  local vm="$1"
  local iso="$2"
  local cpus="$3"
  local memory="$4"
  local disk_gb="$5"
  local ostype="$6"
  local user="$7"
  local password="$8"
  local install_additions_flag=""
  local script_template=""
  local public_key=""
  local post_install_command=""
  local encoded_key=""

  if [[ "$ostype" == Ubuntu_* || "$ostype" == "Ubuntu_64" ]]; then
    if [[ "$CODEX_VM_USE_DEFAULT_UBUNTU_TEMPLATE" != "1" ]]; then
      script_template="$CODEX_VM_BASE_MEDIA_DIR/ubuntu-autoinstall-user-data.template"
      cp /usr/share/virtualbox/UnattendedTemplates/ubuntu_autoinstall_user_data "$script_template"

      # Ensure OpenSSH server is installed/enabled. VirtualBox's stock template
      # sets SSH authorized_keys but does not request ssh-server installation.
      # Insert an explicit autoinstall ssh stanza once, right after shutdown.
      # Also set authorized keys here (this is the supported autoinstall schema).
      if ! grep -qE '^[[:space:]]+ssh:[[:space:]]*$' "$script_template"; then
        local template_tmp="${script_template}.tmp.$$"
        awk -v pubkey_path="${CODEX_VM_GUEST_KEY}.pub" '
          function emit_ssh_stanza() {
            print ""
            print "  ssh:"
            print "    install-server: true"
            print "    allow-pw: true"

            if (pubkey_path != "" && (getline key < pubkey_path) > 0) {
              close(pubkey_path)
              gsub(/"/, "\\\"", key)
              print "    authorized-keys:"
              print "      - \"" key "\""
            }
          }
          {
            print
            if ($0 ~ /^[[:space:]]*shutdown:[[:space:]]*reboot[[:space:]]*$/) {
              emit_ssh_stanza()
            }
          }
        ' "$script_template" > "$template_tmp"
        mv "$template_tmp" "$script_template"
      fi

      # Avoid adding fragile late-commands or cloud-init user-data key hacks here.
      # The autoinstall `ssh:` stanza above is the supported path.
    fi
  fi

  if [[ -f /usr/share/virtualbox/VBoxGuestAdditions.iso ]]; then
    install_additions_flag="--install-additions"
  fi

  if [[ -f "${CODEX_VM_GUEST_KEY}.pub" ]] && command -v base64 >/dev/null 2>&1; then
    encoded_key="$(base64 -w 0 "${CODEX_VM_GUEST_KEY}.pub" 2>/dev/null || base64 "${CODEX_VM_GUEST_KEY}.pub")"
  fi

  if [[ "$ostype" == Ubuntu_* || "$ostype" == "Ubuntu_64" ]]; then
    local bootstrap_users
    local encoded_bootstrap_password
    bootstrap_users="$(guest_auth_candidates "$user" "${CODEX_VM_GUEST_AUTH_USERS:-$user ubuntu root}" | tr '\n' ' ')"
    if command -v base64 >/dev/null 2>&1; then
      encoded_bootstrap_password="$(printf '%s' "$password" | base64 -w 0)"
    else
      encoded_bootstrap_password=""
    fi

    post_install_command="$(cat <<'BOOTSTRAP'
set -eu
LOG_FILE="/root/.codex-vm/bootstrap.log"
mkdir -p /root/.codex-vm
exec >> "$LOG_FILE" 2>&1

log() {
  printf '%s [codex-vm-bootstrap] %s\n' "$(date -Iseconds)" "$*"
}

BOOTSTRAP_USERS="__BOOTSTRAP_USERS__"
BOOTSTRAP_PASSWORD_B64="__BOOTSTRAP_PASSWORD_B64__"
BOOTSTRAP_KEY_B64="__BOOTSTRAP_KEY_B64__"
BOOTSTRAP_PASSWORD=""
if [ -n "$BOOTSTRAP_PASSWORD_B64" ]; then
  BOOTSTRAP_PASSWORD="$(printf '%s' "$BOOTSTRAP_PASSWORD_B64" | base64 -d)"
fi

log "bootstrap start user=${BOOTSTRAP_USERS}"

for BOOT_USER in $BOOTSTRAP_USERS; do
  if [ -z "$BOOT_USER" ]; then
    continue
  fi
  BOOTSTRAP_HOME=""
  if id "$BOOT_USER" >/dev/null 2>&1; then
    BOOTSTRAP_HOME="$(getent passwd "$BOOT_USER" | awk -F: '{print $6}' | head -n1)"
    if [ -z "$BOOTSTRAP_HOME" ]; then
      if [ "$BOOT_USER" = "root" ]; then
        BOOTSTRAP_HOME="/root"
      else
        BOOTSTRAP_HOME="/home/$BOOT_USER"
      fi
    fi
    log "ensure home for ${BOOT_USER}"
    install -d -m 700 -o "$BOOT_USER" -g "$BOOT_USER" "${BOOTSTRAP_HOME}/.ssh" || true
  else
    log "skip missing user ${BOOT_USER}"
    continue
  fi

  if [ -n "$BOOTSTRAP_KEY_B64" ]; then
    printf '%s' "$BOOTSTRAP_KEY_B64" | base64 -d > "/root/.codex-vm/bootstrap-key.pub" || true
    if [ -f "/root/.codex-vm/bootstrap-key.pub" ]; then
      install -m 600 "/root/.codex-vm/bootstrap-key.pub" "${BOOTSTRAP_HOME}/.ssh/authorized_keys" || true
      chown "$BOOT_USER:$BOOT_USER" "${BOOTSTRAP_HOME}/.ssh/authorized_keys" || true
      chmod 600 "${BOOTSTRAP_HOME}/.ssh/authorized_keys" || true
    fi
  fi
done

install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-codex-vm-auth.conf <<EOF_SSHD
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
AddressFamily any
EOF_SSHD

for BOOT_USER in $BOOTSTRAP_USERS; do
  if [ -z "$BOOT_USER" ]; then
    continue
  fi
  if id "$BOOT_USER" >/dev/null 2>&1; then
    printf '%s:%s\n' "$BOOT_USER" "$BOOTSTRAP_PASSWORD" | chpasswd || true
    usermod -aG docker "$BOOT_USER" >/dev/null 2>&1 || true
  fi
done

# Best effort install and ssh enable, but never abort bootstrap on optional failures.
(apt-get update >/dev/null 2>&1 || true)
(DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >/dev/null 2>&1 || true)
(ssh-keygen -A >/dev/null 2>&1 || true)
(systemctl enable --now ssh || true)
(systemctl enable --now ssh.socket || true)
(systemctl restart ssh || systemctl restart ssh.socket || true)
(DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io git rsync curl ca-certificates file libfuse2 >/dev/null 2>&1 || true)
(systemctl enable --now docker || true)
log "bootstrap complete"
BOOTSTRAP
)"
    post_install_command="${post_install_command/__BOOTSTRAP_USERS__/$bootstrap_users}"
    post_install_command="${post_install_command/__BOOTSTRAP_PASSWORD_B64__/$encoded_bootstrap_password}"
    post_install_command="${post_install_command/__BOOTSTRAP_KEY_B64__/$encoded_key}"
  else
    # Windows: enable OpenSSH server so the orchestrator can run PowerShell over SSH.
    # This is required for reproducible first-boot provisioning (fresh ISO installs).
    post_install_command="powershell -NoProfile -ExecutionPolicy Bypass -Command \"\
      try { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null } catch { } ; \
      try { dism /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 | Out-Null } catch { } ; \
      try { Start-Service sshd } catch { } ; \
      try { Set-Service -Name sshd -StartupType Automatic } catch { } ; \
      try { net localgroup administrators '${user}' /add | Out-Null } catch { } ; \
      try { New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null } catch { } ; \
      Write-Output 'codex-vm-windows-ssh-ready'\""
  fi

  VBoxManage createvm --name "$vm" --ostype "$ostype" --register >/dev/null
  # Use VMSVGA for modern Linux guests; VBoxVGA is legacy and has caused kernel crashes
  # with newer Ubuntu kernels + vboxvideo/drm stack.
  local gfx="vmsvga"
  if [[ "$ostype" == Windows* ]]; then
    gfx="vboxsvga"
  fi

  VBoxManage modifyvm "$vm" \
    --cpus "$cpus" \
    --memory "$memory" \
    --ioapic on \
    --graphicscontroller "$gfx" \
    --vram 64 \
    --audio none \
    --nic1 nat \
    --cableconnected1 on \
    >/dev/null
  vm_apply_stability_tweaks "$vm" "$ostype"

  local disk_path="$CODEX_VM_BASE_DIR/disks/${vm}.vdi"
  VBoxManage createmedium disk --filename "$disk_path" --size "$((disk_gb * 1024))" --format VDI >/dev/null

  VBoxManage storagectl "$vm" --name "SATA" --add sata --controller IntelAhci --portcount 2 >/dev/null
  VBoxManage storageattach "$vm" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "$disk_path" >/dev/null
  VBoxManage storageattach "$vm" --storagectl "SATA" --port 1 --device 0 --type dvddrive --medium "$iso" >/dev/null

  VBoxManage unattended install "$vm" \
    --iso "$iso" \
    --user "$user" \
    --password "$password" \
    --admin-password "$password" \
    --time-zone UTC \
    --locale en_US \
    ${script_template:+--script-template "$script_template"} \
    --post-install-command "$post_install_command" \
    $install_additions_flag
}

vm_prepare() {
  local vm="$1"
  local base_ova="$2"
  local base_iso="$3"
  local cpus="$4"
  local memory="$5"
  local disk="$6"
  local ostype="$7"
  local port="$8"
  local user="$9"
  local password="${10}"
  local auth_candidates="${11:-}"
  local lifecycle_mode="${12:-$CODEX_VM_LIFECYCLE_MODE}"
  local reused_vm=0

  if ! vm_refresh "$vm" "$lifecycle_mode"; then
    fatal "Failed to reset VM in recreate mode for $vm"
  fi

  if vm_exists "$vm" && [[ "$lifecycle_mode" != "recreate" ]]; then
    log "Reusing existing VM: $vm"
    if vm_start "$vm" "$port" "$user"; then
      reused_vm=1
    else
      if vm_exists "$vm"; then
        log "Existing VM $vm did not start cleanly; removing and recreating from base image"
        VBoxManage unregistervm "$vm" --delete >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ "$reused_vm" -ne 1 ]]; then
    if [[ -n "$base_ova" ]]; then
      vm_import_ova "$vm" "$base_ova" "$cpus" "$memory" "$ostype"
    elif [[ -n "$base_iso" ]]; then
      vm_create_from_iso "$vm" "$base_iso" "$cpus" "$memory" "$disk" "$ostype" "$user" "$password"
    else
      fatal "Missing Linux/Windows base OVA/ISO for $vm"
    fi

    vm_start "$vm" "$port" "$user"
  fi

  local tcp_timeout="${CODEX_VM_TCP_READY_TIMEOUT:-240}"
  local ssh_timeout="${CODEX_VM_SSH_READY_TIMEOUT:-240}"
  local login_timeout="${CODEX_VM_GUEST_LOGIN_TIMEOUT:-900}"

  if [[ -n "$base_iso" && -z "$base_ova" ]]; then
    # ISO unattended installs can take a while before first successful login.
    login_timeout="${CODEX_VM_GUEST_LOGIN_TIMEOUT:-3600}"
    ssh_timeout="${CODEX_VM_SSH_READY_TIMEOUT:-1800}"
    tcp_timeout="${CODEX_VM_TCP_READY_TIMEOUT:-1800}"
  fi

  vm_wait_for_port "$port" "$tcp_timeout" || fatal "guest TCP port did not become ready on port $port (timeout ${tcp_timeout}s)"
  vm_wait_for_ssh_server "$port" "$user" "$ssh_timeout" || fatal "guest SSH server did not become ready on port $port (timeout ${ssh_timeout}s)"
  vm_wait_for_guest_login "$user" "$port" "$login_timeout" "$auth_candidates" || return 1
}

copy_to_guest_once() {
  local user="$1"
  local port="$2"
  local src="$3"
  local dst="$4"
  local askpass_script=""
  local askpass_cmd=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o PasswordAuthentication=yes
    -o KbdInteractiveAuthentication=no
  )
  local attempt=1

  if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
    attempt=1
    while ((attempt <= 8)); do
      local attempt_err
      attempt_err="$(mktemp)"
      if rsync -az --delete \
        --exclude '.git' --exclude 'dist' --exclude '.mise' --exclude '.github' --exclude 'infra/vm/artifacts' \
        -e "ssh -i '$CODEX_VM_GUEST_KEY' -p '$port' -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no" \
        "$src/" "${user}@127.0.0.1:$dst/" 2>"$attempt_err"; then
        rm -f "$attempt_err"
        return 0
      fi
      capture_auth_attempt "$user" "key" "$attempt" "$attempt_err"
      log "rsync key attempt ${attempt}/8 failed for ${user}@127.0.0.1:$port; retrying..."
      rm -f "$attempt_err"
      ((attempt += 1))
      sleep 2
    done
  fi

  log "copy_to_guest using password-based rsync fallback for ${user}@127.0.0.1:$port"
  if [[ -z "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
    return 1
  fi

  askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"

  attempt=1
  while ((attempt <= 8)); do
    if command -v sshpass >/dev/null 2>&1; then
      local attempt_err
      attempt_err="$(mktemp)"
      if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force \
        sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
        rsync -az --delete \
        --exclude '.git' --exclude 'dist' --exclude '.mise' --exclude '.github' --exclude 'infra/vm/artifacts' \
        -e "ssh ${askpass_cmd[*]} -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p '$port'" \
        "$src/" "${user}@127.0.0.1:$dst/" 2>"$attempt_err"; then
        rm -f "$askpass_script"
        rm -f "$attempt_err"
        return 0
      fi
      capture_auth_attempt "$user" "password-sshpass" "$attempt" "$attempt_err"
      rm -f "$attempt_err"
    fi

    local attempt_err
    attempt_err="$(mktemp)"
    if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:0 \
      setsid rsync -az --delete \
        --exclude '.git' --exclude 'dist' --exclude '.mise' --exclude '.github' --exclude 'infra/vm/artifacts' \
        -e "ssh ${askpass_cmd[*]} -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p '$port'" \
        "$src/" "${user}@127.0.0.1:$dst/" < /dev/null 2>"$attempt_err"; then
      rm -f "$askpass_script"
      rm -f "$attempt_err"
      rm -f "$askpass_script"
      return 0
    fi
    capture_auth_attempt "$user" "password-askpass" "$attempt" "$attempt_err"
    log "Password rsync attempt ${attempt}/8 failed for ${user}@127.0.0.1:$port; retrying..."
    rm -f "$askpass_script"
    rm -f "$attempt_err"
    ((attempt += 1))
    sleep 2
  done

  rm -f "$askpass_script"
  log "Password rsync failed for ${user}@127.0.0.1:$port"
  return 1
}

copy_to_guest() {
  local user="$1"
  local port="$2"
  local src="$3"
  local dst="$4"
  local candidate_list="${5:-}"
  reset_auth_attempts
  local -a users=()
  local fallback_user

  mapfile -t users < <(guest_auth_candidates "$user" "$candidate_list")
  for fallback_user in "${users[@]}"; do
    if copy_to_guest_once "$fallback_user" "$port" "$src" "$dst"; then
      CODEX_VM_GUEST_USER="$fallback_user"
      return 0
    fi
  done

  if [[ -n "$CODEX_VM_GUEST_AUTH_ATTEMPTS" ]]; then
    log "copy_to_guest attempts: $CODEX_VM_GUEST_AUTH_ATTEMPTS"
  fi
  return 1
}

download_media_file() {
  local url="$1"
  local destination="$2"

  if [[ -f "$destination" ]]; then
    log "Using existing media file: $destination"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    log "Downloading media from $url to $destination"
    curl -fL "$url" -o "$destination"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    log "Downloading media from $url to $destination"
    wget -O "$destination" "$url"
    return 0
  fi

  fatal "Neither curl nor wget is installed to download $url"
}

discover_media_file() {
  local -a patterns=("$@")
  local dir pattern

  for dir in "$HOME" /home /mnt /media /opt /var /tmp; do
    for pattern in "${patterns[@]}"; do
      local found
      found="$(find "$dir" -type f -iname "$pattern" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$found" ]]; then
        echo "$found"
        return 0
      fi
    done
  done
  return 1
}

resolve_linux_base_iso() {
  local configured_iso="$1"
  local default_url="$2"

  if [[ -n "$configured_iso" ]]; then
    if [[ -f "$configured_iso" ]]; then
      echo "$configured_iso"
      return 0
    fi
    log "Configured CODEX_VM_LINUX_BASE_ISO not found, ignoring: $configured_iso"
  fi

  local found
  found="$(discover_media_file \
    "*ubuntu*server*.iso" \
    "*ubuntu*live*server*.iso" \
    "*ubuntu-24.04*.iso" \
    "*ubuntu*.iso" )"

  if [[ -n "$found" ]]; then
    log "Found Ubuntu ISO on host: $found"
    echo "$found"
    return 0
  fi

  if [[ -z "$default_url" ]]; then
    fatal "Ubuntu base ISO is not set and no remote candidate was found."
  fi

  local filename="${default_url##*/}"
  local destination="$CODEX_VM_BASE_MEDIA_DIR/$filename"
  download_media_file "$default_url" "$destination"
  echo "$destination"
}

resolve_windows_base_iso() {
  local configured_iso="$1"

  if [[ -n "$configured_iso" ]]; then
    if [[ -f "$configured_iso" ]]; then
      echo "$configured_iso"
      return 0
    fi
    log "Configured CODEX_VM_WINDOWS_BASE_ISO not found, ignoring: $configured_iso"
  fi

  local found
  found="$(discover_media_file \
    "*26100*.iso" \
    "*server*25*.iso" \
    "*windows*server*.iso" \
    "*en-us*.iso" \
    "*windows*.iso" )"

  if [[ -n "$found" ]]; then
    log "Found Windows ISO on host: $found"
    echo "$found"
    return 0
  fi

  fatal "Windows base ISO is not set and no remote candidate was found. Set CODEX_VM_WINDOWS_BASE_ISO in config."
}

prepare_base_media() {
  if [[ -z "$CODEX_VM_LINUX_BASE_OVA" ]]; then
    CODEX_VM_LINUX_BASE_ISO="$(resolve_linux_base_iso "$CODEX_VM_LINUX_BASE_ISO" "$CODEX_VM_LINUX_ISO_URL")"
  else
    CODEX_VM_LINUX_BASE_ISO=""
  fi

  if [[ -z "$CODEX_VM_WINDOWS_BASE_OVA" ]]; then
    CODEX_VM_WINDOWS_BASE_ISO="$(resolve_windows_base_iso "$CODEX_VM_WINDOWS_BASE_ISO")"
  else
    CODEX_VM_WINDOWS_BASE_ISO=""
  fi

  CODEX_VM_WINDOWS_ISO_PATH="${CODEX_VM_WINDOWS_ISO_PATH:-$CODEX_VM_WINDOWS_BASE_ISO}"
}

check_host() {
  VBoxManage --version >/dev/null
  command -v ssh >/dev/null || fatal "ssh missing"
  command -v scp >/dev/null || fatal "scp missing"
  command -v rsync >/dev/null || fatal "rsync missing"
  command -v ssh-keygen >/dev/null || fatal "ssh-keygen missing"
  prepare_base_media
  ensure_usable_guest_key "$CODEX_VM_GUEST_KEY"
  log "Host preflight checks OK"
}

json_escape() {
  local value="${1-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$value" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
  else
    printf '%s' "\"${value//\"/\\\"}\""
  fi
}

vm_log_folder() {
  local vm="$1"
  VBoxManage showvminfo "$vm" --machinereadable | awk -F= '/^LogFolder=/{print $2}' | tr -d '"'
}

collect_linux_debug_artifacts() {
  local reason="$1"
  local debug_dir="$CODEX_VM_ARTIFACT_DIR/$RUN_ID/debug/linux"
  local original_attempts="$CODEX_VM_GUEST_AUTH_ATTEMPTS"
  local original_mode="$CODEX_VM_GUEST_AUTH_MODE"
  local original_user="$CODEX_VM_GUEST_USER"
  mkdir -p "$debug_dir"

  local log_folder
  log_folder="$(vm_log_folder "$CODEX_VM_LINUX_VM_NAME")"
  if [[ -n "$log_folder" && -d "$log_folder" ]]; then
    cp "$log_folder"/*.log "$debug_dir/" 2>/dev/null || true
  fi

  run_guest_scp_from "root" "$CODEX_VM_LINUX_SSH_PORT" "/root/.codex-vm/bootstrap.log" "$debug_dir/bootstrap.log" \
    "${CODEX_VM_GUEST_AUTH_USERS:-$CODEX_VM_LINUX_GUEST_USER ubuntu root}" || true
  if [[ -n "$CODEX_VM_GUEST_AUTH_ATTEMPTS" ]]; then
    printf '%s\n' "$CODEX_VM_GUEST_AUTH_ATTEMPTS" > "$debug_dir/auth-attempts.log"
  fi
  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason" > "$debug_dir/failure-reason.txt"
  fi

  CODEX_VM_GUEST_AUTH_ATTEMPTS="$original_attempts"
  CODEX_VM_GUEST_AUTH_MODE="$original_mode"
  CODEX_VM_GUEST_USER="$original_user"
}

write_linux_run_manifest() {
  local status="$1"
  local phase="$2"
  local reason="${3:-}"
  local auth_mode="$4"
  local auth_attempts="${5:-}"
  local configured_workspace="$6"
  local used_workspace="$7"
  local configured_user="$8"
  local used_user="$9"
  local out_file="$CODEX_VM_ARTIFACT_DIR/$RUN_ID/run-manifest.json"

  local configured_user_json
  local used_user_json
  local configured_workspace_json
  local used_workspace_json
  local reason_json
  local auth_mode_json
  local auth_attempts_json

  configured_user_json="$(json_escape "$configured_user")"
  used_user_json="$(json_escape "$used_user")"
  configured_workspace_json="$(json_escape "$configured_workspace")"
  used_workspace_json="$(json_escape "$used_workspace")"
  reason_json="$(json_escape "$reason")"
  auth_mode_json="$(json_escape "$auth_mode")"
  auth_attempts_json="$(json_escape "$auth_attempts")"

  mkdir -p "$CODEX_VM_ARTIFACT_DIR/$RUN_ID"
  cat > "$out_file" <<EOF
{
  "run_id": "$RUN_ID",
  "platform": "linux",
  "status": "$status",
  "phase": "$phase",
  "reason": $reason_json,
  "linux_workspace": $used_workspace_json,
  "linux_workspace_used": $used_workspace_json,
  "linux_workspace_configured": $configured_workspace_json,
  "linux_guest_user_configured": $configured_user_json,
  "linux_guest_user_used": $used_user_json,
  "linux_auth_mode": $auth_mode_json,
  "linux_auth_attempts": $auth_attempts_json,
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

run_linux() {
  CODEX_VM_GUEST_PASSWORD="${CODEX_VM_GUEST_PASSWORD:-$CODEX_VM_LINUX_GUEST_PASSWORD}"

  local preferred_port="$CODEX_VM_LINUX_SSH_PORT"
  local auth_recreate_attempted=0
  local base_lifecycle_mode="$CODEX_VM_LIFECYCLE_MODE"
  local vm_lifecycle_mode="$base_lifecycle_mode"
  local configured_user="$CODEX_VM_LINUX_GUEST_USER"
  local configured_workspace="$CODEX_VM_LINUX_WORKSPACE"
  local auth_candidates="${CODEX_VM_GUEST_AUTH_USERS:-$CODEX_VM_LINUX_GUEST_USER ubuntu root}"
  local linux_auth_mode=""
  local linux_auth_attempts=""
  local used_user=""
  local used_workspace=""
  local auth_error=""
  local build_error=""
  local build_out_dir
  CODEX_VM_LINUX_SSH_PORT="$(pick_free_port "$preferred_port")"
  if [[ "$CODEX_VM_LINUX_SSH_PORT" != "$preferred_port" ]]; then
    log "Linux SSH forward port $preferred_port is busy; using $CODEX_VM_LINUX_SSH_PORT instead"
  fi

  while true; do
    if [[ "$auth_recreate_attempted" -eq 1 ]]; then
      vm_lifecycle_mode="recreate"
    else
      vm_lifecycle_mode="$base_lifecycle_mode"
    fi
    if ! vm_prepare "$CODEX_VM_LINUX_VM_NAME" "$CODEX_VM_LINUX_BASE_OVA" "$CODEX_VM_LINUX_BASE_ISO" \
      "$CODEX_VM_LINUX_VM_CPUS" "$CODEX_VM_LINUX_VM_MEMORY_MB" "$CODEX_VM_LINUX_VM_DISK_GB" "$CODEX_VM_LINUX_VM_OSTYPE" \
      "$CODEX_VM_LINUX_SSH_PORT" "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_GUEST_PASSWORD" "$auth_candidates" "$vm_lifecycle_mode"; then
      local auth_attempt_snapshot="$CODEX_VM_GUEST_AUTH_ATTEMPTS"
      if [[ "$auth_recreate_attempted" -eq 0 && "${CODEX_VM_RETRY_RECREATE_ON_AUTH_FAILURE:-1}" == "1" ]]; then
        log "Linux SSH auth probe failed for candidates: $auth_candidates; recreating VM once and retrying"
        auth_recreate_attempted=1
        used_user=""
        used_workspace=""
        continue
      fi

      auth_error="Linux SSH auth probe failed for candidates: $auth_candidates | $(format_auth_attempts_for_error "$auth_attempt_snapshot")"
      collect_linux_debug_artifacts "$auth_error"
      used_workspace="${used_workspace:-$configured_workspace}"
      used_user="${used_user:-$configured_user}"
      write_linux_run_manifest "failed" "auth" "$auth_error" "$CODEX_VM_GUEST_AUTH_MODE" "$auth_attempt_snapshot" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$auth_error"
    fi

    if ! run_guest_ssh "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_SSH_PORT" "true" "$auth_candidates"; then
      local auth_attempt_snapshot="$CODEX_VM_GUEST_AUTH_ATTEMPTS"
      if [[ "$auth_recreate_attempted" -eq 0 && "${CODEX_VM_RETRY_RECREATE_ON_AUTH_FAILURE:-1}" == "1" ]]; then
        log "Linux SSH auth failed with candidates: $auth_candidates; recreating VM once and retrying"
        auth_recreate_attempted=1
        used_user=""
        used_workspace=""
        continue
      fi

      auth_error="Linux SSH auth failed for candidates: $auth_candidates | $(format_auth_attempts_for_error "$auth_attempt_snapshot")"
      collect_linux_debug_artifacts "$auth_error"
      used_workspace="${used_workspace:-$configured_workspace}"
      used_user="${used_user:-$configured_user}"
      write_linux_run_manifest "failed" "auth" "$auth_error" "$CODEX_VM_GUEST_AUTH_MODE" "$auth_attempt_snapshot" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$auth_error"
    fi

    used_user="$CODEX_VM_GUEST_USER"
    used_workspace="$(guest_home_for_user "$used_user")/codex-linux"
    CODEX_VM_LINUX_WORKSPACE="$used_workspace"
    linux_auth_mode="$CODEX_VM_GUEST_AUTH_MODE"
    linux_auth_attempts="$CODEX_VM_GUEST_AUTH_ATTEMPTS"

    if ! run_guest_ssh "$used_user" "$CODEX_VM_LINUX_SSH_PORT" "mkdir -p '$used_workspace'" "$auth_candidates"; then
      build_error="Linux workspace create failed for $used_workspace"
      collect_linux_debug_artifacts "$build_error"
      write_linux_run_manifest "failed" "prepare" "$build_error" "$linux_auth_mode" "$linux_auth_attempts" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$build_error"
    fi

    if ! copy_to_guest "$used_user" "$CODEX_VM_LINUX_SSH_PORT" "$SOURCE_DIR" "$used_workspace" "$auth_candidates"; then
      build_error="source sync failed for $used_user@$CODEX_VM_LINUX_SSH_PORT"
      collect_linux_debug_artifacts "$build_error"
      write_linux_run_manifest "failed" "prepare" "$build_error" "$linux_auth_mode" "$linux_auth_attempts" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$build_error"
    fi

    if ! run_guest_ssh "$used_user" "$CODEX_VM_LINUX_SSH_PORT" "
      mkdir -p '$used_workspace/.codex-vm-output'
      export CODEX_VM_GUEST_WORKDIR='$used_workspace'
      export CODEX_VM_OUTPUT_DIR='$used_workspace/.codex-vm-output'
      export CODEX_VM_RUN_ID='$RUN_ID'
      export CODEX_VM_CODEX_GIT_REF='$CODEX_VM_CODEX_GIT_REF'
      export CODEX_VM_CODEX_DMG_URL='$CODEX_VM_CODEX_DMG_URL'
      export CODEX_VM_ENABLE_LINUX_UI_POLISH='$CODEX_VM_ENABLE_LINUX_UI_POLISH'
      cd '$used_workspace'
      bash infra/vm/guest/linux-build.sh
    " "$used_user"; then
      build_error="Linux build command failed for $used_workspace"
      collect_linux_debug_artifacts "$build_error"
      write_linux_run_manifest "failed" "build" "$build_error" "$linux_auth_mode" "$linux_auth_attempts" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$build_error"
    fi

    build_out_dir="$ARTIFACT_ROOT/$RUN_ID/linux"
    mkdir -p "$build_out_dir"
    if ! run_guest_scp_from "$used_user" "$CODEX_VM_LINUX_SSH_PORT" "$used_workspace/.codex-vm-output/Codex.AppImage" "$build_out_dir/Codex.AppImage" "$auth_candidates"; then
      build_error="artifact pull failed: Codex.AppImage"
      collect_linux_debug_artifacts "$build_error"
      write_linux_run_manifest "failed" "artifact" "$build_error" "$linux_auth_mode" "$linux_auth_attempts" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$build_error"
    fi
    if ! run_guest_scp_from "$used_user" "$CODEX_VM_LINUX_SSH_PORT" "$used_workspace/.codex-vm-output/versions.json" "$build_out_dir/versions.json" "$auth_candidates"; then
      build_error="artifact pull failed: versions.json"
      collect_linux_debug_artifacts "$build_error"
      write_linux_run_manifest "failed" "artifact" "$build_error" "$linux_auth_mode" "$linux_auth_attempts" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$build_error"
    fi
    if ! run_guest_scp_from "$used_user" "$CODEX_VM_LINUX_SSH_PORT" "$used_workspace/.codex-vm-output/manifest.json" "$build_out_dir/manifest.json" "$auth_candidates"; then
      build_error="artifact pull failed: manifest.json"
      collect_linux_debug_artifacts "$build_error"
      write_linux_run_manifest "failed" "artifact" "$build_error" "$linux_auth_mode" "$linux_auth_attempts" \
        "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
      fatal "$build_error"
    fi

    write_linux_run_manifest "success" "artifact" "" "$linux_auth_mode" "$linux_auth_attempts" \
      "$configured_workspace" "$used_workspace" "$configured_user" "$used_user"
    break
  done
}

copy_to_windows_guest() {
  local user="$1"
  local port="$2"
  local src="$3"
  local dst="$4"

  local win_dst
  win_dst="$dst"
  if [[ "$win_dst" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    win_dst="${BASH_REMATCH[1]^}:/${BASH_REMATCH[2]}"
  fi

  local tmp_tar="/tmp/codex-vm-src-${RUN_ID}.tar.gz"
  rm -f "$tmp_tar"
  tar -czf "$tmp_tar" \
    --exclude='.git' --exclude='dist' --exclude='.mise' --exclude='.github' --exclude='infra/vm/artifacts' \
    -C "$src" .

  # Copy tarball to Windows user home (OpenSSH scp understands C:/ paths).
  run_guest_ssh "$user" "$port" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path 'C:/Users/${user}/codex-vm-tmp' | Out-Null\""
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -P "$port" \
    -i "$CODEX_VM_GUEST_KEY" \
    "$tmp_tar" "${user}@127.0.0.1:C:/Users/${user}/codex-vm-tmp/src.tar.gz" >/dev/null 2>&1 || {
      fatal "Failed to scp source tarball to Windows guest (need OpenSSH + scp)."
    }

  run_guest_ssh "$user" "$port" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"
    New-Item -ItemType Directory -Force -Path '${win_dst}' | Out-Null;
    if (Test-Path '${win_dst}\\\\*') { Remove-Item -Recurse -Force '${win_dst}\\\\*' -ErrorAction SilentlyContinue };
    tar -xzf 'C:/Users/${user}/codex-vm-tmp/src.tar.gz' -C '${win_dst}';
  \""
}

run_windows() {
  CODEX_VM_GUEST_PASSWORD="${CODEX_VM_GUEST_PASSWORD:-$CODEX_VM_WINDOWS_GUEST_PASSWORD}"

  local preferred_port="$CODEX_VM_WINDOWS_SSH_PORT"
  CODEX_VM_WINDOWS_SSH_PORT="$(pick_free_port "$preferred_port")"
  if [[ "$CODEX_VM_WINDOWS_SSH_PORT" != "$preferred_port" ]]; then
    log "Windows SSH forward port $preferred_port is busy; using $CODEX_VM_WINDOWS_SSH_PORT instead"
  fi

  if ! vm_prepare "$CODEX_VM_WINDOWS_VM_NAME" "$CODEX_VM_WINDOWS_BASE_OVA" "$CODEX_VM_WINDOWS_BASE_ISO" \
    "$CODEX_VM_WINDOWS_VM_CPUS" "$CODEX_VM_WINDOWS_VM_MEMORY_MB" "$CODEX_VM_WINDOWS_VM_DISK_GB" "$CODEX_VM_WINDOWS_VM_OSTYPE" \
    "$CODEX_VM_WINDOWS_SSH_PORT" "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_GUEST_PASSWORD" "$CODEX_VM_WINDOWS_GUEST_USER"; then
    fatal "Windows SSH login did not become ready on port $CODEX_VM_WINDOWS_SSH_PORT"
  fi

  run_guest_ssh "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "New-Item -ItemType Directory -Path '$CODEX_VM_WINDOWS_WORKSPACE/.codex-vm-output' -Force | Out-Null"
  copy_to_windows_guest "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "$SOURCE_DIR" "$CODEX_VM_WINDOWS_WORKSPACE"

  run_guest_ssh "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "
    powershell -NoProfile -ExecutionPolicy Bypass -File '$CODEX_VM_WINDOWS_WORKSPACE/infra/vm/guest/windows-build.ps1' \
      -ProjectPath '$CODEX_VM_WINDOWS_WORKSPACE' -RunId '$RUN_ID' \
      -GitRef '$CODEX_VM_CODEX_GIT_REF' -DmgUrl '$CODEX_VM_CODEX_DMG_URL' \
      -OutputDir '$CODEX_VM_WINDOWS_WORKSPACE/.codex-vm-output' -EnableLinuxUiPolish '$CODEX_VM_ENABLE_LINUX_UI_POLISH'
  "

  local out_dir="$ARTIFACT_ROOT/$RUN_ID/windows"
  mkdir -p "$out_dir"
  run_guest_scp_from "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "$CODEX_VM_WINDOWS_WORKSPACE/.codex-vm-output/Codex-Setup-Windows-x64.exe" "$out_dir/Codex-Setup-Windows-x64.exe"
  run_guest_scp_from "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "$CODEX_VM_WINDOWS_WORKSPACE/.codex-vm-output/manifest.json" "$out_dir/manifest.json"
}

case "$ACTION" in
  check)
    check_host
    ;;
  linux)
    check_host
    run_linux
    ;;
  windows|win)
    check_host
    run_windows
    ;;
  both)
    check_host
    run_linux
    run_windows
    ;;
  *)
    fatal "unknown action '$ACTION'"
    ;;
esac
