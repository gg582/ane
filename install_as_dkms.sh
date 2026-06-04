#!/usr/bin/env bash
set -euo pipefail

ANE_DKMS_NAME="${ANE_DKMS_NAME:-ane}"
ANE_REPO_URL="${ANE_DKMS_REPO_URL:-https://github.com/eiln/ane.git}"
ANE_REPO_REF="${ANE_DKMS_REF:-HEAD}"
ANE_SOURCE_OVERRIDE="${ANE_DKMS_SOURCE:-}"

ALTMODES_DKMS_NAME="${ALTMODES_DKMS_NAME:-asahi-typec-altmodes}"
ALTMODES_REPO_URL="${ALTMODES_REPO_URL:-https://github.com/AsahiLinux/linux.git}"
ALTMODES_REPO_REF="${ALTMODES_REPO_REF:-fairydust}"
ALTMODES_SOURCE_OVERRIDE="${ALTMODES_SOURCE:-${ASAHI_LINUX_SOURCE:-}}"

KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"
RC_SCRIPT_PATH="${RC_SCRIPT_PATH:-/usr/local/sbin/asahi-ane-dkms-rc.sh}"
RC_SERVICE_PATH="${RC_SERVICE_PATH:-/etc/systemd/system/asahi-ane-dkms-rc.service}"

TYPEC_MODULES=(typec_displayport typec_nvidia typec_thunderbolt)
TMP_DIRS=()

cleanup_tmp_dirs() {
  local dir

  for dir in "${TMP_DIRS[@]:-}"; do
    safe_rm_tmp_dir "${dir}"
  done
}
trap cleanup_tmp_dirs EXIT

usage() {
  cat <<EOF
Usage: $0 [install|install-ane|install-altmodes|uninstall|uninstall-ane|uninstall-altmodes|status|logs]

Default install/uninstall handles both ANE and Type-C DP alt mode DKMS packages.

ANE environment:
  ANE_DKMS_REPO_URL   Driver repository URL. Default: ${ANE_REPO_URL}
  ANE_DKMS_REF        Git ref to install. Default: ${ANE_REPO_REF}
  ANE_DKMS_VERSION    DKMS package version. Default: git-<commit>
  ANE_DKMS_SOURCE     Existing ane repo checkout to use instead of cloning.

Type-C altmode environment:
  ALTMODES_REPO_URL   Kernel repository URL. Default: ${ALTMODES_REPO_URL}
  ALTMODES_REPO_REF   Kernel git ref. Default: ${ALTMODES_REPO_REF}
  ALTMODES_VERSION    DKMS package version. Default: git-<commit>
  ALTMODES_SOURCE     Existing kernel checkout containing drivers/usb/typec/altmodes.
  ASAHI_LINUX_SOURCE  Alias for ALTMODES_SOURCE.

Common:
  KERNEL_VERSION      Kernel to build for. Default: ${KERNEL_VERSION}
  RC_SCRIPT_PATH      Boot-time rc helper path. Default: ${RC_SCRIPT_PATH}
  RC_SERVICE_PATH     systemd unit path. Default: ${RC_SERVICE_PATH}
EOF
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "error: this command needs root, and sudo is not available" >&2
    exit 1
  fi

  exec sudo -E bash "$0" "$@"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

ensure_dkms() {
  if command -v dkms >/dev/null 2>&1; then
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y dkms
  else
    echo "error: dkms is not installed. Install dkms and rerun this script." >&2
    exit 1
  fi
}

kernel_build_dir() {
  printf '/lib/modules/%s/build' "${KERNEL_VERSION}"
}

check_kernel_headers() {
  local build_dir
  build_dir="$(kernel_build_dir)"

  if [[ ! -d "${build_dir}" ]]; then
    cat >&2 <<EOF
error: kernel build directory not found: ${build_dir}

Install headers/devel files for ${KERNEL_VERSION}, or run with:
  KERNEL_VERSION=<installed-kernel-version> $0 install
EOF
    exit 1
  fi
}

sanitize_version() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._+-' '-'
}

validate_package_name() {
  local name="$1"

  if [[ ! "${name}" =~ ^[A-Za-z0-9_.+-]+$ ]]; then
    echo "error: invalid DKMS package name: ${name}" >&2
    exit 1
  fi
}

validate_version() {
  local version="$1"

  if [[ -z "${version}" || "${version}" == "." || "${version}" == ".." || "${version}" == */* ]]; then
    echo "error: invalid DKMS version: ${version}" >&2
    exit 1
  fi
}

validate_config() {
  validate_package_name "${ANE_DKMS_NAME}"
  validate_package_name "${ALTMODES_DKMS_NAME}"
  if [[ "${KERNEL_VERSION}" == */* || -z "${KERNEL_VERSION}" ]]; then
    echo "error: invalid KERNEL_VERSION: ${KERNEL_VERSION}" >&2
    exit 1
  fi
  if [[ "${RC_SCRIPT_PATH}" != /usr/local/sbin/*.sh ]]; then
    echo "error: RC_SCRIPT_PATH must be under /usr/local/sbin and end with .sh: ${RC_SCRIPT_PATH}" >&2
    exit 1
  fi
  if [[ "${RC_SERVICE_PATH}" != /etc/systemd/system/*.service ]]; then
    echo "error: RC_SERVICE_PATH must be under /etc/systemd/system and end with .service: ${RC_SERVICE_PATH}" >&2
    exit 1
  fi
}

register_tmp_dir() {
  local dir="$1"

  if [[ -z "${dir}" || ! -d "${dir}" ]]; then
    echo "error: refusing to register invalid temporary directory: ${dir}" >&2
    exit 1
  fi
  TMP_DIRS+=("${dir}")
}

safe_rm_tmp_dir() {
  local dir="$1"

  if [[ -z "${dir}" || ! -d "${dir}" ]]; then
    return
  fi

  case "${dir}" in
    /tmp/tmp.*|/var/tmp/tmp.*)
      rm -rf --one-file-system -- "${dir}"
      ;;
    *)
      echo "warning: refusing to remove non-mktemp directory: ${dir}" >&2
      ;;
  esac
}

safe_rm_dkms_src_dir() {
  local package="$1"
  local version="$2"
  local dir="$3"
  local expected="/usr/src/${package}-${version}"

  validate_package_name "${package}"
  validate_version "${version}"

  if [[ "${dir}" != "${expected}" ]]; then
    echo "error: refusing to remove unexpected DKMS source dir: ${dir}" >&2
    echo "       expected: ${expected}" >&2
    exit 1
  fi

  case "${dir}" in
    /usr/src/*)
      ;;
    *)
      echo "error: refusing to remove non-/usr/src path: ${dir}" >&2
      exit 1
      ;;
  esac

  case "${dir}" in
    /|/usr|/usr/src|/lib|/lib/modules|/boot|/boot/*|/lib/modules/*)
      echo "error: refusing to remove protected kernel/system path: ${dir}" >&2
      exit 1
      ;;
  esac

  if [[ -e "${dir}" && ! -f "${dir}/.install_as_dkms.managed" ]]; then
    if [[ ! -f "${dir}/dkms.conf" ]] ||
      ! grep -q "^PACKAGE_NAME=\"${package}\"$" "${dir}/dkms.conf" ||
      ! grep -q "^PACKAGE_VERSION=\"${version}\"$" "${dir}/dkms.conf"; then
      cat >&2 <<EOF
error: refusing to remove unrecognized source directory: ${dir}

This guard prevents accidental deletion of external kernel source trees.
Move it aside manually if this really is disposable DKMS source.
EOF
      exit 1
    fi
  fi

  rm -rf --one-file-system -- "${dir}"
}

harden_dkms_src_dir() {
  local dir="$1"

  if [[ -z "${dir}" || ! -d "${dir}" || "${dir}" != /usr/src/* ]]; then
    echo "error: refusing to harden unexpected DKMS source dir: ${dir}" >&2
    exit 1
  fi

  chown -R root:root "${dir}"
  touch "${dir}/.install_as_dkms.managed"
  chmod -R go-w "${dir}"
  find "${dir}" -type d -exec chmod 0755 {} +
  find "${dir}" -type f -exec chmod 0644 {} +
  find "${dir}" -type f -name '*.sh' -exec chmod 0755 {} +
}

git_version_or_timestamp() {
  local checkout="$1"
  local env_version="$2"
  local commit

  if [[ -n "${env_version}" ]]; then
    sanitize_version "${env_version}"
    return
  fi

  commit="$(git -C "${checkout}" rev-parse --short=12 HEAD 2>/dev/null || true)"
  if [[ -n "${commit}" ]]; then
    sanitize_version "git-${commit}"
  else
    sanitize_version "local-$(date +%Y%m%d%H%M%S)"
  fi
}

clone_or_copy_ane_repo() {
  local workdir="$1"
  local checkout="${workdir}/ane-repo"

  if [[ -n "${ANE_SOURCE_OVERRIDE}" ]]; then
    if [[ ! -d "${ANE_SOURCE_OVERRIDE}/ane" ]]; then
      echo "error: ANE_DKMS_SOURCE must point to a checkout containing ane/" >&2
      exit 1
    fi
    cp -a "${ANE_SOURCE_OVERRIDE}" "${checkout}"
  else
    git clone --depth 1 "${ANE_REPO_URL}" "${checkout}"
    if [[ "${ANE_REPO_REF}" != "HEAD" ]]; then
      git -C "${checkout}" fetch --depth 1 origin "${ANE_REPO_REF}"
      git -C "${checkout}" checkout --detach FETCH_HEAD
    fi
  fi

  if [[ ! -f "${checkout}/ane/Makefile" ]]; then
    echo "error: driver Makefile not found at ane/Makefile in source checkout" >&2
    exit 1
  fi

  printf '%s\n' "${checkout}"
}

clone_or_use_kernel_repo() {
  local workdir="$1"
  local checkout="${workdir}/linux"

  if [[ -n "${ALTMODES_SOURCE_OVERRIDE}" ]]; then
    if [[ ! -f "${ALTMODES_SOURCE_OVERRIDE}/drivers/usb/typec/altmodes/displayport.c" ]]; then
      echo "error: ALTMODES_SOURCE must point to a kernel checkout containing drivers/usb/typec/altmodes" >&2
      exit 1
    fi
    printf '%s\n' "${ALTMODES_SOURCE_OVERRIDE}"
    return
  fi

  git clone --filter=blob:none --depth 1 --sparse "${ALTMODES_REPO_URL}" "${checkout}"
  if [[ "${ALTMODES_REPO_REF}" != "HEAD" ]]; then
    git -C "${checkout}" fetch --depth 1 origin "${ALTMODES_REPO_REF}"
    git -C "${checkout}" checkout --detach FETCH_HEAD
  fi
  git -C "${checkout}" sparse-checkout set drivers/usb/typec/altmodes

  printf '%s\n' "${checkout}"
}

remove_dkms_package() {
  local package="$1"

  while IFS= read -r line; do
    local version
    version="$(printf '%s\n' "${line}" | sed -n "s/^${package}\\/\\([^, ]*\\).*/\\1/p")"
    if [[ -n "${version}" ]]; then
      dkms remove -m "${package}" -v "${version}" --all || true
      safe_rm_dkms_src_dir "${package}" "${version}" "/usr/src/${package}-${version}"
    fi
  done < <(dkms status -m "${package}" || true)
}

write_ane_dkms_files() {
  local srcdir="$1"
  local version="$2"

  cat >"${srcdir}/Makefile" <<'EOF'
ifneq ($(KERNELRELEASE),)
ccflags-y += -I$(src)/src
obj-m := ane.o
ane-y := src/ane_drv.o src/ane_tm.o
else
KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

default:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

install:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules_install
	depmod -a
	modprobe ane
	if [ -e /dev/accel/accel0 ]; then chmod 666 /dev/accel/accel0; fi

uninstall:
	modprobe -r ane

clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
endif
EOF

  cat >"${srcdir}/dkms.conf" <<EOF
PACKAGE_NAME="${ANE_DKMS_NAME}"
PACKAGE_VERSION="${version}"
BUILT_MODULE_NAME[0]="${ANE_DKMS_NAME}"
DEST_MODULE_LOCATION[0]="/kernel/drivers/accel"
AUTOINSTALL="yes"
BUILD_EXCLUSIVE_ARCH="aarch64|arm64"
MAKE[0]="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
EOF
}

write_altmodes_dkms_files() {
  local srcdir="$1"
  local version="$2"

  cat >"${srcdir}/Makefile" <<'EOF'
ifneq ($(KERNELRELEASE),)
ccflags-y += -DCONFIG_TYPEC_DP_ALTMODE_MODULE=1
ccflags-y += -DCONFIG_TYPEC_NVIDIA_ALTMODE_MODULE=1
ccflags-y += -DCONFIG_TYPEC_TBT_ALTMODE_MODULE=1
obj-m := typec_displayport.o typec_nvidia.o typec_thunderbolt.o
typec_displayport-y := displayport.o
typec_nvidia-y := nvidia.o
typec_thunderbolt-y := thunderbolt.o
else
KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

default:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
endif
EOF

  cat >"${srcdir}/dkms.conf" <<EOF
PACKAGE_NAME="${ALTMODES_DKMS_NAME}"
PACKAGE_VERSION="${version}"
BUILT_MODULE_NAME[0]="typec_displayport"
BUILT_MODULE_NAME[1]="typec_nvidia"
BUILT_MODULE_NAME[2]="typec_thunderbolt"
DEST_MODULE_LOCATION[0]="/kernel/drivers/usb/typec/altmodes"
DEST_MODULE_LOCATION[1]="/kernel/drivers/usb/typec/altmodes"
DEST_MODULE_LOCATION[2]="/kernel/drivers/usb/typec/altmodes"
AUTOINSTALL="yes"
BUILD_EXCLUSIVE_ARCH="aarch64|arm64"
MAKE[0]="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
EOF
}

patch_altmodes_for_kernel_api() {
  local srcdir="$1"
  local typec_altmode_header

  typec_altmode_header="$(kernel_build_dir)/include/linux/usb/typec_altmode.h"
  if [[ ! -f "${typec_altmode_header}" ]]; then
    echo "warning: Type-C altmode header not found, skipping kernel API compatibility patch: ${typec_altmode_header}" >&2
    return
  fi

  if grep -qw 'mode_selection' "${typec_altmode_header}"; then
    return
  fi

  if grep -q 'alt->mode_selection' "${srcdir}/displayport.c"; then
    sed -i 's/if (!alt->mode_selection) {/if (1) {/' "${srcdir}/displayport.c"
  fi

  if grep -q 'alt->mode_selection' "${srcdir}/thunderbolt.c"; then
    sed -i 's/if (!alt->mode_selection && tbt_ready(alt)) {/if (tbt_ready(alt)) {/' "${srcdir}/thunderbolt.c"
  fi

  if grep -Rqw 'mode_selection' "${srcdir}/displayport.c" "${srcdir}/thunderbolt.c"; then
    echo "error: failed to patch Type-C altmode sources for kernel headers without mode_selection" >&2
    exit 1
  fi
}

kernel_struct_has_member() {
  local header="$1"
  local struct_name="$2"
  local member="$3"

  awk -v struct_name="${struct_name}" -v member="${member}" '
    $0 ~ "struct[[:space:]]+" struct_name "[[:space:]]*\\{" { in_struct = 1 }
    in_struct && $0 ~ ("[[:space:]]" member "[[:space:]]*;") { found = 1 }
    in_struct && /^};/ { in_struct = 0 }
    END { exit found ? 0 : 1 }
  ' "${header}"
}

patch_ane_for_kernel_api() {
  local srcdir="$1"
  local drm_drv_header platform_device_header

  drm_drv_header="$(kernel_build_dir)/include/drm/drm_drv.h"
  platform_device_header="$(kernel_build_dir)/include/linux/platform_device.h"

  if grep -q 'dev_err(ane->dev' "${srcdir}/src/ane_tm.c" &&
    ! grep -q '^#include <linux/device.h>$' "${srcdir}/src/ane_tm.c"; then
    sed -i '/^#include <linux\/iopoll.h>$/a #include <linux/device.h>' "${srcdir}/src/ane_tm.c"
  fi

  if [[ -f "${drm_drv_header}" ]] &&
    ! kernel_struct_has_member "${drm_drv_header}" drm_driver date; then
    sed -i '/^[[:space:]]*\.date[[:space:]]*=.*,$/d' "${srcdir}/src/ane_drv.c"
  fi

  if [[ -f "${platform_device_header}" ]] &&
    grep -q 'void (\*remove)(struct platform_device' "${platform_device_header}"; then
    sed -i 's/^static int ane_platform_remove(struct platform_device \*pdev)$/static void ane_platform_remove(struct platform_device *pdev)/' "${srcdir}/src/ane_drv.c"
    sed -i '/^static void ane_platform_remove(struct platform_device \*pdev)$/,/^}/{/^[[:space:]]*return 0;$/d;}' "${srcdir}/src/ane_drv.c"
  fi
}

install_ane_runtime_files() {
  install -d /etc/modules-load.d /etc/udev/rules.d
  printf '%s\n' "${ANE_DKMS_NAME}" >/etc/modules-load.d/ane.conf
  printf 'KERNEL=="accel[0-9]*", SUBSYSTEM=="accel", MODE="0666"\n' >/etc/udev/rules.d/99-ane.rules

  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=accel || true
  fi
}

install_altmodes_runtime_files() {
  install -d /etc/modules-load.d
  printf '%s\n' "${TYPEC_MODULES[@]}" >/etc/modules-load.d/asahi-typec-altmodes.conf
}

install_rc_service() {
  install -d "$(dirname "${RC_SCRIPT_PATH}")" "$(dirname "${RC_SERVICE_PATH}")"

  cat >"${RC_SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

for module in ${TYPEC_MODULES[*]} ${ANE_DKMS_NAME}; do
  modprobe "\${module}" >/dev/null 2>&1 || true
done

for _ in \$(seq 1 20); do
  if [[ -e /dev/accel/accel0 ]]; then
    chmod 666 /dev/accel/accel0 || true
    exit 0
  fi
  sleep 0.2
done
EOF
  chown root:root "${RC_SCRIPT_PATH}"
  chmod 0755 "${RC_SCRIPT_PATH}"

  cat >"${RC_SERVICE_PATH}" <<EOF
[Unit]
Description=Load Asahi ANE and Type-C altmode modules
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=${RC_SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "${RC_SERVICE_PATH}"
  chmod 0644 "${RC_SERVICE_PATH}"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable --now "$(basename "${RC_SERVICE_PATH}")" || true
  fi
}

dkms_package_present() {
  local package="$1"

  dkms status -m "${package}" 2>/dev/null | grep -q "^${package}/"
}

remove_rc_service_if_unused() {
  if dkms_package_present "${ANE_DKMS_NAME}" || dkms_package_present "${ALTMODES_DKMS_NAME}"; then
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$(basename "${RC_SERVICE_PATH}")" >/dev/null 2>&1 || true
    systemctl daemon-reload || true
  fi

  rm -f -- "${RC_SCRIPT_PATH}" "${RC_SERVICE_PATH}"
}

install_ane() {
  run_as_root "$@"
  validate_config
  need_cmd git
  need_cmd make
  need_cmd modprobe
  need_cmd depmod
  ensure_dkms
  check_kernel_headers

  local workdir checkout version srcdir
  workdir="$(mktemp -d)"
  register_tmp_dir "${workdir}"

  checkout="$(clone_or_copy_ane_repo "${workdir}")"
  version="$(git_version_or_timestamp "${checkout}" "${ANE_DKMS_VERSION:-}")"
  srcdir="/usr/src/${ANE_DKMS_NAME}-${version}"

  if dkms status -m "${ANE_DKMS_NAME}" -v "${version}" >/dev/null 2>&1; then
    dkms remove -m "${ANE_DKMS_NAME}" -v "${version}" --all || true
  fi

  safe_rm_dkms_src_dir "${ANE_DKMS_NAME}" "${version}" "${srcdir}"
  install -d "${srcdir}"
  cp -a "${checkout}/ane/." "${srcdir}/"
  patch_ane_for_kernel_api "${srcdir}"
  write_ane_dkms_files "${srcdir}" "${version}"
  harden_dkms_src_dir "${srcdir}"

  dkms add -m "${ANE_DKMS_NAME}" -v "${version}"
  dkms build -m "${ANE_DKMS_NAME}" -v "${version}" -k "${KERNEL_VERSION}"
  dkms install -m "${ANE_DKMS_NAME}" -v "${version}" -k "${KERNEL_VERSION}"

  install_ane_runtime_files
  install_rc_service

  if lsmod | awk '{print $1}' | grep -qx "${ANE_DKMS_NAME}"; then
    modprobe -r "${ANE_DKMS_NAME}" || true
  fi
  modprobe "${ANE_DKMS_NAME}"
  if [[ -e /dev/accel/accel0 ]]; then
    chmod 666 /dev/accel/accel0
  fi

  echo "installed ${ANE_DKMS_NAME}/${version} for ${KERNEL_VERSION}"
}

install_altmodes() {
  run_as_root "$@"
  validate_config
  need_cmd git
  need_cmd make
  need_cmd modprobe
  need_cmd depmod
  ensure_dkms
  check_kernel_headers

  local workdir checkout version srcdir alt_src
  workdir="$(mktemp -d)"
  register_tmp_dir "${workdir}"

  checkout="$(clone_or_use_kernel_repo "${workdir}")"
  version="$(git_version_or_timestamp "${checkout}" "${ALTMODES_VERSION:-}")"
  srcdir="/usr/src/${ALTMODES_DKMS_NAME}-${version}"
  alt_src="${checkout}/drivers/usb/typec/altmodes"

  if [[ ! -f "${alt_src}/displayport.c" || ! -f "${alt_src}/nvidia.c" || ! -f "${alt_src}/thunderbolt.c" ]]; then
    echo "error: Type-C altmode source files are incomplete under ${alt_src}" >&2
    exit 1
  fi

  if dkms status -m "${ALTMODES_DKMS_NAME}" -v "${version}" >/dev/null 2>&1; then
    dkms remove -m "${ALTMODES_DKMS_NAME}" -v "${version}" --all || true
  fi

  safe_rm_dkms_src_dir "${ALTMODES_DKMS_NAME}" "${version}" "${srcdir}"
  install -d "${srcdir}"
  cp "${alt_src}/displayport.c" "${srcdir}/"
  cp "${alt_src}/displayport.h" "${srcdir}/"
  cp "${alt_src}/nvidia.c" "${srcdir}/"
  cp "${alt_src}/thunderbolt.c" "${srcdir}/"
  patch_altmodes_for_kernel_api "${srcdir}"
  write_altmodes_dkms_files "${srcdir}" "${version}"
  harden_dkms_src_dir "${srcdir}"

  dkms add -m "${ALTMODES_DKMS_NAME}" -v "${version}"
  dkms build -m "${ALTMODES_DKMS_NAME}" -v "${version}" -k "${KERNEL_VERSION}"
  dkms install -m "${ALTMODES_DKMS_NAME}" -v "${version}" -k "${KERNEL_VERSION}"

  install_altmodes_runtime_files
  install_rc_service

  modprobe -r typec_nvidia typec_thunderbolt typec_displayport || true
  modprobe typec_displayport
  modprobe typec_nvidia
  modprobe typec_thunderbolt

  echo "installed ${ALTMODES_DKMS_NAME}/${version} for ${KERNEL_VERSION}"
}

uninstall_ane() {
  run_as_root "$@"
  validate_config
  ensure_dkms

  if lsmod | awk '{print $1}' | grep -qx "${ANE_DKMS_NAME}"; then
    modprobe -r "${ANE_DKMS_NAME}" || true
  fi

  remove_dkms_package "${ANE_DKMS_NAME}"
  rm -f /etc/modules-load.d/ane.conf /etc/udev/rules.d/99-ane.rules
  remove_rc_service_if_unused
}

uninstall_altmodes() {
  run_as_root "$@"
  validate_config
  ensure_dkms

  modprobe -r typec_nvidia typec_thunderbolt typec_displayport || true
  remove_dkms_package "${ALTMODES_DKMS_NAME}"
  rm -f /etc/modules-load.d/asahi-typec-altmodes.conf
  remove_rc_service_if_unused
}

status_driver() {
  if command -v dkms >/dev/null 2>&1; then
    dkms status -m "${ANE_DKMS_NAME}" || true
    dkms status -m "${ALTMODES_DKMS_NAME}" || true
  else
    echo "dkms is not installed"
  fi

  lsmod | awk -v ane="${ANE_DKMS_NAME}" '
    NR == 1 { print; next }
    $1 == ane || $1 == "typec_displayport" || $1 == "typec_nvidia" || $1 == "typec_thunderbolt" { print }
  '

  if [[ -e /dev/accel/accel0 ]]; then
    ls -l /dev/accel/accel0
  fi
}

logs_driver() {
  dmesg -k --color=always | grep -Ei 'ane|typec|displayport|thunderbolt' || true
}

cmd="${1:-install}"
case "${cmd}" in
  install)
    install_altmodes "$@"
    install_ane "$@"
    ;;
  install-ane)
    install_ane "$@"
    ;;
  install-altmodes)
    install_altmodes "$@"
    ;;
  uninstall)
    uninstall_ane "$@"
    uninstall_altmodes "$@"
    ;;
  uninstall-ane)
    uninstall_ane "$@"
    ;;
  uninstall-altmodes)
    uninstall_altmodes "$@"
    ;;
  status)
    status_driver
    ;;
  logs)
    logs_driver
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
