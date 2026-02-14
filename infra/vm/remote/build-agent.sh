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
: "${CODEX_VM_LINUX_WORKSPACE:?/home/ubuntu/codex-linux}"
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
      if ssh -i "$CODEX_VM_GUEST_KEY" \
        -o PasswordAuthentication=no -o PubkeyAuthentication=yes \
        "${ssh_opts[@]}" \
        "$user@127.0.0.1" "$cmd" ; then
        CODEX_VM_GUEST_USER="$user"
        return 0
      fi
      log "SSH key attempt ${attempt}/8 failed for $user@127.0.0.1:$port; retrying..."
      ((attempt += 1))
      sleep 2
    done
  fi

  if [[ -z "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
    fatal "SSH key auth failed and CODEX_VM_GUEST_PASSWORD is empty for user '$user' on port $port"
  fi

  askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"

  local attempt=1
  while ((attempt <= 8)); do
    log "Falling back to password SSH for $user@127.0.0.1:$port (attempt ${attempt}/8)"
    if command -v sshpass >/dev/null 2>&1; then
      if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
        ssh "${askpass_cmd[@]}" "${ssh_opts[@]}" "$user@127.0.0.1" "$cmd"; then
        rm -f "$askpass_script"
        CODEX_VM_GUEST_USER="$user"
        return 0
      fi
    fi

    if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:0 \
      setsid ssh "${askpass_cmd[@]}" "${ssh_opts[@]}" "$user@127.0.0.1" "$cmd" < /dev/null; then
      rm -f "$askpass_script"
      CODEX_VM_GUEST_USER="$user"
      return 0
    fi
    ((attempt += 1))
    sleep 2
  done

  rm -f "$askpass_script"
  fatal "Password SSH failed for $user@127.0.0.1:$port"
}

run_guest_ssh() {
  local user="$1"
  local port="$2"
  local cmd="$3"
  local fallback_user

  if run_guest_ssh_once "$user" "$port" "$cmd"; then
    return 0
  fi

  for fallback_user in ubuntu root; do
    if [[ "$fallback_user" == "$user" ]]; then
      continue
    fi
    if run_guest_ssh_once "$fallback_user" "$port" "$cmd"; then
      CODEX_VM_GUEST_USER="$fallback_user"
      return 0
    fi
  done

  return 1
}

run_guest_scp_from() {
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
  local scp_opts=(
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -P "$port"
  )

  if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
    local attempt=1
    while ((attempt <= 8)); do
      if scp -i "$CODEX_VM_GUEST_KEY" "${scp_opts[@]}" \
        -o BatchMode=yes \
        "$user@127.0.0.1:$src" "$dst" ; then
        CODEX_VM_GUEST_USER="$user"
        return 0
      fi
      log "SCP key attempt ${attempt}/8 failed for $user@127.0.0.1:$port; retrying..."
      ((attempt += 1))
      sleep 2
    done
  fi

  if [[ -z "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
    fatal "SCP key auth failed and CODEX_VM_GUEST_PASSWORD is empty for user '$user' on port $port"
  fi

  askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"

  local attempt=1
  while ((attempt <= 8)); do
    log "Falling back to password SCP for $user@127.0.0.1:$port"
    if command -v sshpass >/dev/null 2>&1; then
      if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force \
        sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
        scp "${askpass_cmd[@]}" "${scp_opts[@]}" "$user@127.0.0.1:$src" "$dst"; then
        rm -f "$askpass_script"
        CODEX_VM_GUEST_USER="$user"
        return 0
      fi
    fi

      if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:0 \
      setsid scp "${askpass_cmd[@]}" "${scp_opts[@]}" "$user@127.0.0.1:$src" "$dst" < /dev/null; then
      rm -f "$askpass_script"
      CODEX_VM_GUEST_USER="$user"
      return 0
    fi
    log "Password SCP attempt ${attempt}/8 failed for $user@127.0.0.1:$port; retrying..."
    ((attempt += 1))
    sleep 2
  done

  rm -f "$askpass_script"
  fatal "Password SCP failed for $user@127.0.0.1:$port"
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
  local user="$1"
  local port="$2"
  local timeout="${3:-900}"
  local i=0
  local last_log=0

  while ((i < timeout)); do
    if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
      if ssh -i "$CODEX_VM_GUEST_KEY" \
        -o PasswordAuthentication=no -o PubkeyAuthentication=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -p "$port" \
        "$user@127.0.0.1" "echo codex-vm-ready" >/dev/null 2>&1; then
        return 0
      fi
    fi

    if (( (i - last_log) >= 30 )); then
      log "Waiting for guest SSH login: ${user}@127.0.0.1:${port} (${i}s/${timeout}s)"
      last_log="$i"
    fi

    sleep 2
    i=$((i + 2))
  done

  return 1
}

vm_refresh() {
  local vm="$1"
  if [[ "$CODEX_VM_LIFECYCLE_MODE" == "recreate" ]] && vm_exists "$vm"; then
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
      if ! grep -qE '^[[:space:]]+ssh:[[:space:]]*$' "$script_template"; then
        local template_tmp="${script_template}.tmp.$$"
        awk '
          {
            print
            if ($0 ~ /^[[:space:]]*shutdown:[[:space:]]*reboot[[:space:]]*$/) {
              print ""
              print "  ssh:"
              print "    install-server: true"
              print "    allow-pw: true"
            }
          }
        ' "$script_template" > "$template_tmp"
        mv "$template_tmp" "$script_template"
      fi

      # Some environments still end up without an SSH daemon. Force installation/enabling
      # via curtin late-commands so the NAT forward can be used immediately after install.
      if ! grep -q "codex-vm-ensure-ssh" "$script_template"; then
        local template_tmp="${script_template}.tmp.$$"
        awk '
          {
            print
            if ($0 ~ /^[[:space:]]*late-commands:[[:space:]]*$/) {
              print "    - echo codex-vm-ensure-ssh"
              print "    - curtin in-target --target=/target -- apt-get update"
              print "    - curtin in-target --target=/target -- apt-get install -y openssh-server"
              print "    - curtin in-target --target=/target -- systemctl enable ssh --now || true"
            }
          }
        ' "$script_template" > "$template_tmp"
        mv "$template_tmp" "$script_template"
      fi

      if [[ -f "${CODEX_VM_GUEST_KEY}.pub" ]]; then
        public_key="$(cat "${CODEX_VM_GUEST_KEY}.pub")"
        local template_tmp="${script_template}.tmp.$$"
        awk -v key="$public_key" '
          {
            print
            if ($0 ~ /^        shell: \/bin\/bash$/) {
              print "        ssh_authorized_keys:"
              print "          - \"" key "\""
            }
          }
        ' "$script_template" > "$template_tmp"
        mv "$template_tmp" "$script_template"
      fi
    fi
  fi

  if [[ -f /usr/share/virtualbox/VBoxGuestAdditions.iso ]]; then
    install_additions_flag="--install-additions"
  fi

  if [[ -f "${CODEX_VM_GUEST_KEY}.pub" ]] && command -v base64 >/dev/null 2>&1; then
    encoded_key="$(base64 -w 0 "${CODEX_VM_GUEST_KEY}.pub" 2>/dev/null || base64 "${CODEX_VM_GUEST_KEY}.pub")"
  fi

  post_install_command="mkdir -p /home/${user}/.ssh && chmod 700 /home/${user}/.ssh && "
  if [[ -n "$encoded_key" ]]; then
    post_install_command+="printf '%s\n' '${encoded_key}' | base64 -d > /home/${user}/.ssh/authorized_keys && chmod 600 /home/${user}/.ssh/authorized_keys && "
  fi
  post_install_command+="mkdir -p /home/${user}/.ssh && chown -R ${user}:${user} /home/${user}/.ssh && "
  post_install_command+="printf '%s\n' \"PasswordAuthentication yes\" \"ChallengeResponseAuthentication yes\" \"PubkeyAuthentication yes\" > /etc/ssh/sshd_config.d/99-codex-vm-auth.conf && "
  post_install_command+="chmod 600 /etc/ssh/sshd_config.d/99-codex-vm-auth.conf && "
  # Keep fallback users aligned with the configured guest password so SSH recovery works.
  post_install_command+="printf '%s\n%s\n%s\n' '${user}:${password}' 'ubuntu:${password}' 'root:${password}' | chpasswd && "
  post_install_command+="systemctl daemon-reload || true; "
  post_install_command+="(systemctl restart ssh || service ssh restart || service sshd restart) || true; "
  post_install_command+="systemctl enable ssh --now || true"

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
    >/dev/null

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
  local reused_vm=0

  if ! vm_refresh "$vm"; then
    fatal "Failed to reset VM in recreate mode for $vm"
  fi

  if vm_exists "$vm" && [[ "$CODEX_VM_LIFECYCLE_MODE" != "recreate" ]]; then
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
  vm_wait_for_guest_login "$user" "$port" "$login_timeout" || fatal "guest SSH login did not become ready on port $port (timeout ${login_timeout}s)"
}

copy_to_guest_once() {
  local user="$1"
  local port="$2"
  local src="$3"
  local dst="$4"
  local attempt=1
  local askpass_script=""
  local askpass_cmd=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o PasswordAuthentication=yes
    -o KbdInteractiveAuthentication=no
  )

  if [[ -f "$CODEX_VM_GUEST_KEY" ]]; then
    attempt=1
    while ((attempt <= 8)); do
      if rsync -az --delete \
        --exclude '.git' --exclude 'dist' --exclude '.mise' --exclude '.github' --exclude 'infra/vm/artifacts' \
        -e "ssh -i '$CODEX_VM_GUEST_KEY' -p '$port' -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no" \
        "$src/" "${user}@127.0.0.1:$dst/"; then
        return 0
      fi
      log "rsync key attempt ${attempt}/8 failed for ${user}@127.0.0.1:$port; retrying..."
      ((attempt += 1))
      sleep 2
    done
  fi

  log "copy_to_guest using password-based rsync fallback for ${user}@127.0.0.1:$port"
  if [[ -z "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
    fatal "GUEST key missing or invalid and CODEX_VM_GUEST_PASSWORD is empty."
  fi

  askpass_script="$(guest_askpass_script "$CODEX_VM_GUEST_PASSWORD")"

  attempt=1
  while ((attempt <= 8)); do
    if command -v sshpass >/dev/null 2>&1; then
      if SSH_AUTH_SOCK= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=force \
        sshpass -p "$CODEX_VM_GUEST_PASSWORD" \
        rsync -az --delete \
        --exclude '.git' --exclude 'dist' --exclude '.mise' --exclude '.github' --exclude 'infra/vm/artifacts' \
        -e "ssh ${askpass_cmd[*]} -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p '$port'" \
        "$src/" "${user}@127.0.0.1:$dst/" ; then
        rm -f "$askpass_script"
        return 0
      fi
    fi

    if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass_script" DISPLAY=:0 \
      setsid rsync -az --delete \
        --exclude '.git' --exclude 'dist' --exclude '.mise' --exclude '.github' --exclude 'infra/vm/artifacts' \
        -e "ssh ${askpass_cmd[*]} -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p '$port'" \
        "$src/" "${user}@127.0.0.1:$dst/" < /dev/null; then
      rm -f "$askpass_script"
      return 0
    fi
    log "Password rsync attempt ${attempt}/8 failed for ${user}@127.0.0.1:$port; retrying..."
    ((attempt += 1))
    sleep 2
  done

  rm -f "$askpass_script"
  fatal "Password rsync failed for ${user}@127.0.0.1:$port"
}

copy_to_guest() {
  local user="$1"
  local port="$2"
  local src="$3"
  local dst="$4"
  local fallback_user

  if copy_to_guest_once "$user" "$port" "$src" "$dst"; then
    return 0
  fi

  for fallback_user in ubuntu root; do
    if [[ "$fallback_user" == "$user" ]]; then
      continue
    fi
    if copy_to_guest_once "$fallback_user" "$port" "$src" "$dst"; then
      CODEX_VM_GUEST_USER="$fallback_user"
      return 0
    fi
  done

  fatal "copy_to_guest failed for ${user}@127.0.0.1:$port"
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

run_linux() {
  CODEX_VM_GUEST_PASSWORD="${CODEX_VM_GUEST_PASSWORD:-$CODEX_VM_LINUX_GUEST_PASSWORD}"

  vm_prepare "$CODEX_VM_LINUX_VM_NAME" "$CODEX_VM_LINUX_BASE_OVA" "$CODEX_VM_LINUX_BASE_ISO" \
    "$CODEX_VM_LINUX_VM_CPUS" "$CODEX_VM_LINUX_VM_MEMORY_MB" "$CODEX_VM_LINUX_VM_DISK_GB" "$CODEX_VM_LINUX_VM_OSTYPE" \
    "$CODEX_VM_LINUX_SSH_PORT" "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_GUEST_PASSWORD"

  copy_to_guest "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_SSH_PORT" "$SOURCE_DIR" "$CODEX_VM_LINUX_WORKSPACE"

  run_guest_ssh "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_SSH_PORT" "
    mkdir -p '$CODEX_VM_LINUX_WORKSPACE/.codex-vm-output'
    export CODEX_VM_GUEST_WORKDIR='$CODEX_VM_LINUX_WORKSPACE'
    export CODEX_VM_OUTPUT_DIR='$CODEX_VM_LINUX_WORKSPACE/.codex-vm-output'
    export CODEX_VM_RUN_ID='$RUN_ID'
    export CODEX_VM_CODEX_GIT_REF='$CODEX_VM_CODEX_GIT_REF'
    export CODEX_VM_CODEX_DMG_URL='$CODEX_VM_CODEX_DMG_URL'
    export CODEX_VM_ENABLE_LINUX_UI_POLISH='$CODEX_VM_ENABLE_LINUX_UI_POLISH'
    cd '$CODEX_VM_LINUX_WORKSPACE'
    bash infra/vm/guest/linux-build.sh
  "

  local out_dir="$ARTIFACT_ROOT/$RUN_ID/linux"
  mkdir -p "$out_dir"
  run_guest_scp_from "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_SSH_PORT" "$CODEX_VM_LINUX_WORKSPACE/.codex-vm-output/Codex.AppImage" "$out_dir/Codex.AppImage"
  run_guest_scp_from "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_SSH_PORT" "$CODEX_VM_LINUX_WORKSPACE/.codex-vm-output/versions.json" "$out_dir/versions.json"
  run_guest_scp_from "$CODEX_VM_LINUX_GUEST_USER" "$CODEX_VM_LINUX_SSH_PORT" "$CODEX_VM_LINUX_WORKSPACE/.codex-vm-output/manifest.json" "$out_dir/manifest.json"
}

run_windows() {
  CODEX_VM_GUEST_PASSWORD="${CODEX_VM_GUEST_PASSWORD:-$CODEX_VM_WINDOWS_GUEST_PASSWORD}"

  vm_prepare "$CODEX_VM_WINDOWS_VM_NAME" "$CODEX_VM_WINDOWS_BASE_OVA" "$CODEX_VM_WINDOWS_BASE_ISO" \
    "$CODEX_VM_WINDOWS_VM_CPUS" "$CODEX_VM_WINDOWS_VM_MEMORY_MB" "$CODEX_VM_WINDOWS_VM_DISK_GB" "$CODEX_VM_WINDOWS_VM_OSTYPE" \
    "$CODEX_VM_WINDOWS_SSH_PORT" "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_GUEST_PASSWORD"

  copy_to_guest "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "$SOURCE_DIR" "$CODEX_VM_WINDOWS_WORKSPACE"

  if [[ -n "$CODEX_VM_WINDOWS_ISO_PATH" ]]; then
    run_guest_ssh "$CODEX_VM_WINDOWS_GUEST_USER" "$CODEX_VM_WINDOWS_SSH_PORT" "New-Item -ItemType Directory -Path '$CODEX_VM_WINDOWS_WORKSPACE/.codex-vm-output' -Force | Out-Null"
  fi

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
