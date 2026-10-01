#!/usr/bin/env bash
# runtime-personal.sh — Exasol Personal local runtime module (macOS and Linux).
#
# Sourced by setup scripts after common.sh and detect.sh. Installs the Exasol
# launcher from the resolved GitHub release (checksum-verified) and deploys a
# local database with `exasol install local`.
#
# Launcher facts:
#   - release assets: exasol-personal_{macOS,Linux}_{arm64,x86_64}.tar.gz
#     + checksums; Linux local deployments exist from launcher 2.3 and need
#     Podman (rootless is fine) — the launcher does not install it on Linux
#   - local deployment needs at least 8 GB RAM
#   - deployment state: ~/.exasol/personal/deployments/default
#   - `exasol info` prints connection details for the current deployment
#   - rerunning `exasol install local` with the same preset is safe

EXAKIT_PERSONAL_PORT=8563
EXAKIT_PERSONAL_MIN_RAM_GB="${EXAKIT_PERSONAL_MIN_RAM_GB:-8}"
EXAKIT_PERSONAL_MIN_DISK_GB="${EXAKIT_PERSONAL_MIN_DISK_GB:-20}"
EXAKIT_PERSONAL_BIN="$EXAKIT_BIN_DIR/exasol"
EXAKIT_PERSONAL_DEPLOY_DIR="${EXAKIT_PERSONAL_DEPLOY_DIR:-$HOME/.exasol/personal/deployments/default}"

# personal_check_requirements — the compatibility gate. Incompatible machines
# get a clear explanation and a graceful exit; machines at the bare minimum
# proceed with an explicit warning; comfortable machines get one quiet OK line.
# (Replaces the old "Detected environment" panel: users don't act on a table of
# facts — they act on "this will/won't work and why".)
EXAKIT_PERSONAL_COMFORT_RAM_GB="${EXAKIT_PERSONAL_COMFORT_RAM_GB:-12}"
EXAKIT_PERSONAL_COMFORT_DISK_GB="${EXAKIT_PERSONAL_COMFORT_DISK_GB:-40}"
# personal_heal_rootless_podman — fix what stops rootless Podman, instead of
# printing a command and walking away.
#
# THE KIT HAS NEVER RUN sudo, AND THIS IS THE ONE PLACE IT ASKS TO. Everything
# else it installs goes under ~/.local and ~/.exasol-starter-kit, which is why
# it needs no privilege at all. A rootless Podman gap is the exception: the
# sub-id ranges live in /etc/subuid and /etc/subgid and the uidmap helper is a
# system package, so there is no unprivileged fix to reach for. The old
# behaviour was to print the command in red and leave; the deploy then failed
# minutes later, inside a container start, with an error naming neither Podman
# nor the missing range.
#
# So: ask, run it, verify it, and say plainly what happened either way.
#
# CONSENT IS EXPLICIT AND NEVER ASSUMED. An interactive run is asked and
# defaults to yes, because it is the fix the reader came for. A run with no
# terminal is NOT: it must set EXAKIT_PODMAN_SELFHEAL=1 to opt in. A scripted
# install that silently edits /etc on a machine nobody is watching is not a
# self-heal, it is a surprise - and the kit's whole posture is that it does not
# touch anything outside the user's home without being told to.
#
# Never fatal. Podman can work in shapes this does not model, so a declined
# offer, a missing sudo, or a fix that does not take all leave the install to
# carry on and let the deploy be the judge.
personal_heal_rootless_podman() {
    _phr_kind="$(detect_rootless_podman_gap_kind 2>/dev/null || true)"
    [ -n "$_phr_kind" ] || return 0

    _phr_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
    _phr_why="$(detect_rootless_podman_gap 2>/dev/null || true)"

    case "$_phr_kind" in
        cgroups)
            # No process can turn this on. Say so, and say it in the words of
            # the platform the reader is actually on.
            warn "Rootless Podman: ${_phr_why}"
            return 0
            ;;
        subid)
            _phr_fix="usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $_phr_user"
            _phr_what="add a user-namespace range for $_phr_user"
            ;;
        uidmap)
            _phr_fix="$(_personal_uidmap_install_cmd)"
            _phr_what="install the uidmap package rootless Podman needs"
            [ -n "$_phr_fix" ] || { warn "Rootless Podman: ${_phr_why}"; return 0; }
            ;;
        *) return 0 ;;
    esac

    warn "Rootless Podman is not ready: ${_phr_why}"

    if ! command -v sudo >/dev/null 2>&1; then
        info "The kit can fix this, but 'sudo' is not on PATH. Run this as root, then re-run the installer:"
        info "  $_phr_fix"
        return 0
    fi

    # A terminal may be asked; a scripted run must have said so in advance.
    if [ -n "$(_exakit_prompt_tty)" ]; then
        confirm_env EXAKIT_PODMAN_SELFHEAL "Let the kit $_phr_what? It runs a command as administrator and will ask for your password" y || {
            info "Not changed. To do it yourself:  sudo $_phr_fix"
            return 0
        }
    else
        case "${EXAKIT_PODMAN_SELFHEAL:-}" in
            1|y|Y|yes|YES|Yes) : ;;
            *)
                info "The kit can fix this for you, but it edits system files, so an unattended run has to opt in:"
                info "  EXAKIT_PODMAN_SELFHEAL=1  (or run it yourself: sudo $_phr_fix)"
                return 0
                ;;
        esac
    fi

    info "Running: sudo $_phr_fix"
    # shellcheck disable=SC2086
    if ! sudo $_phr_fix; then
        warn "That did not go through. Run it yourself and re-run the installer:  sudo $_phr_fix"
        return 0
    fi

    # The ranges only take effect for Podman after it rebuilds its user
    # namespace, and a machine that has already run Podman keeps the old one.
    if [ "$_phr_kind" = subid ] && command -v podman >/dev/null 2>&1; then
        podman system migrate >/dev/null 2>&1 || true
    fi

    # VERIFY, never assume: usermod can succeed and still leave the gap when a
    # distribution manages its ranges somewhere else entirely.
    if [ -n "$(detect_rootless_podman_gap_kind 2>/dev/null || true)" ]; then
        warn "Rootless Podman still looks incomplete after the fix - carrying on, and the deploy will say if it matters."
        return 0
    fi
    ok "Rootless Podman is ready ($_phr_what)"
}

# _personal_uidmap_install_cmd — the install command for THIS distribution, or
# empty when its package manager is not one the kit knows. Named separately so
# the heal above reads as one decision.
# _personal_podman_install_cmd — the one command that installs Podman on this
# machine, or nothing when the package manager is not one the kit knows.
#
# uidmap rides along on Debian and Ubuntu: rootless Podman needs newuidmap and
# newgidmap, they ship in a separate package there, and without them the
# failure arrives much later, inside a container start, naming neither Podman
# nor the package. The same reasoning as _personal_uidmap_install_cmd below,
# which stays for the machine that has Podman but not those binaries.
# _personal_podman_install_cmd - the command to SHOW someone. Short enough to
# read, short enough to retype. What the kit actually runs is the hardened
# twin below; the two are kept apart because a wall of environment variables is
# the wrong thing to print at a reader who just wants to install Podman.
_personal_podman_install_cmd() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt-get install -y podman uidmap\n'; return 0; fi
    if command -v dnf     >/dev/null 2>&1; then printf 'dnf install -y podman\n'; return 0; fi
    if command -v yum     >/dev/null 2>&1; then printf 'yum install -y podman\n'; return 0; fi
    if command -v zypper  >/dev/null 2>&1; then printf 'zypper install -y podman\n'; return 0; fi
    if command -v pacman  >/dev/null 2>&1; then printf 'pacman -S --noconfirm podman\n'; return 0; fi
    if command -v apk     >/dev/null 2>&1; then printf 'apk add --no-cache podman\n'; return 0; fi
    return 1
}

# personal_podman_installable — can this machine be given Podman by the kit?
# A command to run and a way to become root: without either, the install stays
# the user's to do and the gate says so before anything is downloaded.
# _personal_podman_install_cmd_auto - the same command, hardened for a run
# whose output nobody is watching.
#
# THIS IS WHAT A CAPTURED INSTALL COSTS. With apt writing to the screen, a
# question from needrestart ("Which services should be restarted?" - installed
# by default on Ubuntu 22.04 and later) or from dpkg about a config file was
# visible and answerable. Behind a spinner it is not: the install waits on
# stdin for an answer nobody can see, for ever, and the only thing on screen is
# a spinner counting up. Measured at over 500 seconds before anyone gave up.
#
# So the prompts are turned off at the source. DEBIAN_FRONTEND stops debconf
# asking, NEEDRESTART_MODE=a restarts services without asking, and the two
# force-conf options keep the config files already on the machine, which is
# what a non-interactive apt should do. The redirect from /dev/null is the
# belt: ANY prompt that still gets through reads EOF and the command fails in
# a second instead of hanging, which is the failure a reader can act on.
_personal_podman_install_cmd_auto() {
    _ppica_cmd="$(_personal_podman_install_cmd 2>/dev/null || true)"
    [ -n "$_ppica_cmd" ] || return 1
    case "$_ppica_cmd" in
        apt-get*)
            # `apt-get update` first: a fresh Ubuntu image or container ships
            # with empty package lists, and the install then fails with
            # "Unable to locate package podman". Run inside the same `sh -c` so
            # sudo covers both halves. The printed command stays the short one.
            printf 'DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 %s -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold </dev/null\n' \
                "$_ppica_cmd"
            ;;
        *)
            # dnf, yum, zypper, pacman and apk all take their "assume yes" flag
            # above and have no debconf equivalent. The redirect still applies:
            # a prompt nobody can answer must fail, not wait.
            printf '%s </dev/null\n' "$_ppica_cmd"
            ;;
    esac
    return 0
}

personal_podman_installable() {
    _ppi_cmd="$(_personal_podman_install_cmd 2>/dev/null || true)"
    [ -n "$_ppi_cmd" ] || return 1
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && return 0
    command -v sudo >/dev/null 2>&1
}

# personal_install_podman — Podman, when the database step finds it missing.
#
# WHERE THIS RUNS MATTERS. The launcher is installed first and the database is
# deployed second, and Podman is the thing the second step needs - so it is
# fetched between them, named, and installed once. Doing it in the gate instead
# would put a package install in front of a machine that has not yet agreed to
# anything, and refusing there (which is what happened before) sent a user off
# to a package manager and back to the beginning of the install.
#
# It asks first, because this is the one thing in the kit that touches the
# system rather than the user's home: same shape as the rootless self-heal
# above, same opt-in for an unattended run.
#
# AND IT RETURNS RATHER THAN ENDING THE RUN. Saying no used to close the whole
# install - the database step, and with it the launcher, exapump, the AI bridge
# and the exakit command itself, none of which the user had declined. Every
# other step in the kit that cannot finish records itself and lets the rest go
# on; this one now does too, and the closing summary names the one command that
# finishes it. 1 means "no database this time", and the caller stops there.
personal_install_podman() {
    command -v podman >/dev/null 2>&1 && return 0
    case "$(detect_os)" in
        linux|wsl) : ;;
        *) return 0 ;;   # macOS and Windows: the launcher brings its own
    esac

    _pin_cmd="$(_personal_podman_install_cmd 2>/dev/null || true)"
    _pin_where="on this machine"
    [ "$(detect_os)" = wsl ] && _pin_where="inside this distro"

    warn "Podman is not installed $_pin_where, and the database runs through it."
    if [ -z "$_pin_cmd" ]; then
        info "This machine's package manager is not one the kit knows, so install Podman yourself and re-run."
        exakit_note_failure "Podman is not installed and the kit does not know this machine's package manager"
        return 1
    fi
    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
        info "The kit can install it, but 'sudo' is not on PATH. Run this as root, then re-run the installer:"
        info "  $_pin_cmd"
        exakit_note_failure "Podman is not installed and 'sudo' is not on PATH ($_pin_cmd)"
        return 1
    fi

    _pin_sudo=""
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || _pin_sudo="sudo "
    # PROMISED ONLY WHEN IT WILL HAPPEN. A machine with NOPASSWD, or one where
    # sudo was used a minute ago, is never asked for a password - and a
    # question that says it will be is a question that was not read carefully
    # enough to write.
    # NOT ASKED FOR ANY MORE. The database runs through Podman and the user
    # already asked for the database; a y/n whose only sensible answer is yes is
    # a question that buys nothing and costs a keystroke in the middle of an
    # install. It is still announced - the warn above says what is missing, and
    # the spinner below says what is being done about it - and the one command
    # it runs is in the logfile.
    #
    # EXAKIT_INSTALL_PODMAN=0 is the way out for anyone who needs one: a
    # scripted run on a machine where package installs are somebody else's job.
    # It is an opt-OUT rather than an opt-in, because the kit installing what
    # the database needs is now the default on every road.
    case "${EXAKIT_INSTALL_PODMAN:-}" in
        0|n|N|no|NO|No)
            info "Not installed (EXAKIT_INSTALL_PODMAN=0). To do it yourself:  ${_pin_sudo}$_pin_cmd"
            exakit_note_failure "Podman was not installed (EXAKIT_INSTALL_PODMAN=0); the database needs it"
            return 1
            ;;
    esac

    # THE PASSWORD AND THE PACKAGE MANAGER ARE TWO DIFFERENT THINGS, and
    # running them as one is what put three screens of apt through the middle
    # of an install that shows one line per step. A captured sudo asking for a
    # password behind a spinner is a machine that looks hung - so the password
    # is asked for FIRST, in the open and on its own, and the package manager
    # then runs behind the spinner with a credential it no longer has to ask
    # about. Nothing is hidden: every line apt printed is in the logfile.
    if [ -n "$_pin_sudo" ] && ! sudo -n true 2>/dev/null; then
        if [ -z "$(_exakit_prompt_tty)" ]; then
            # No terminal to type a password on. Said, not waited on: a
            # captured sudo would sit on stdin for ever behind a spinner.
            info "This run has no terminal to type an administrator password on. Run it yourself, then re-run:  ${_pin_sudo}$_pin_cmd"
            exakit_note_failure "Podman needs an administrator password and this run has no terminal to ask for one"
            return 1
        fi
        # "this one command" UNDERSTATED IT. What is obtained is a sudo
        # timestamp, reusable for the rest of its timeout, and what is run
        # under it is `sh -c "<package manager install>"` - a root shell
        # running the distro's own maintainer scripts. That is the ordinary
        # way to install a package and it is fine; describing it as one
        # command was what was not fine, because the reader sizing the request
        # was sizing the wrong thing.
        info "Your password, to install Podman as administrator (this grants sudo for the rest of its usual timeout):"
        if ! sudo -v; then
            info "Not installed. To do it yourself:  ${_pin_sudo}$_pin_cmd"
            exakit_note_failure "The administrator password for the Podman install was not given"
            return 1
        fi
    fi
    EXAKIT_ACTIVE_LABEL="Installing Podman"
    # -n on the RUN, never on the ask above: a sudoers with timestamp_timeout=0
    # caches nothing, and without this the captured command would hang on a
    # password prompt nobody can see. It fails in a second instead, with the
    # command to run by hand.
    _pin_run="$_pin_sudo"
    [ -n "$_pin_run" ] && _pin_run="sudo -n "
    # The hardened twin, never the printed one: see
    # _personal_podman_install_cmd_auto for what a captured apt costs without it.
    _pin_auto="$(_personal_podman_install_cmd_auto 2>/dev/null || printf '%s' "$_pin_cmd")"
    # shellcheck disable=SC2086
    if ! run_logged ${_pin_run}sh -c "$_pin_auto"; then
        EXAKIT_ACTIVE_LABEL=""
        info "Run it yourself and re-run the installer:  ${_pin_sudo}$_pin_cmd"
        exakit_note_failure "Podman could not be installed (${_pin_sudo}$_pin_cmd)"
        return 1
    fi
    EXAKIT_ACTIVE_LABEL=""
    if ! command -v podman >/dev/null 2>&1; then
        warn "The install reported success, but 'podman' is still not on PATH."
        info "Open a new shell and re-run the installer."
        exakit_note_failure "Podman installed but not on PATH in this shell"
        return 1
    fi
    ok "Podman installed ($(podman --version 2>/dev/null | head -1))"
    # The sub-id ranges and uidmap are checked the moment Podman exists, so a
    # machine that has just been given it is not left one container start away
    # from a failure that names neither.
    personal_heal_rootless_podman || true
    return 0
}

_personal_uidmap_install_cmd() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt-get install -y uidmap\n'; return 0; fi
    if command -v dnf     >/dev/null 2>&1; then printf 'dnf install -y shadow-utils\n'; return 0; fi
    if command -v zypper  >/dev/null 2>&1; then printf 'zypper install -y shadow\n'; return 0; fi
    if command -v pacman  >/dev/null 2>&1; then printf 'pacman -S --noconfirm shadow\n'; return 0; fi
    return 1
}

personal_check_requirements() {
    _pcr_os="$(detect_os)"
    case "$_pcr_os" in
        macos) : ;;
        linux|wsl)
            # ...WSL 2. WSL 1 is not Linux to anyone: it translates syscalls to
            # the NT kernel, so it has no cgroups, no user namespaces, and no
            # container runtime that can work. detect_wsl_version exists to
            # gate exactly this refusal - its own comment says so - and until
            # now nothing called it for that. Unrefused, a WSL 1 distro reached
            # the Podman branch below, `apt-get install podman` SUCCEEDED, and
            # the failure surfaced minutes later as a raw cgroups error, after
            # a sudo package install the user never needed.
            if [ "$_pcr_os" = wsl ] && [ "$(detect_wsl_version 2>/dev/null)" = "1" ]; then
                error "This is a WSL 1 distro. Exasol Personal runs the database in a container, and WSL 1 has no Linux kernel to run one with."
                info "Convert this distro to WSL 2, from PowerShell on the Windows side:"
                info "  wsl --list --verbose          (find this distro's name and see its version)"
                info "  wsl --set-version <distro> 2  (converts it; your files are kept)"
                info "Then reopen the distro and re-run the installer: $(exakit_install_command)"
                die "WSL 1 is not supported: Exasol Personal needs a real Linux kernel."
            fi
            # WSL IS LINUX TO THE LAUNCHER, AND THAT IS THE WHOLE STORY. A WSL2
            # distro is an AMD64 Linux with a real kernel, the launcher ships a
            # Linux build, and its Linux local runtime asks for exactly one
            # thing - a podman on PATH (linuxHostEnvironmentPreparer.EnsureReady
            # is a single exec.LookPath). No systemd, no cgroup check, no WSL
            # detection anywhere on that path.
            #
            # The kit used to refuse WSL outright, reasoning that "Personal's
            # Windows path is host Podman inside a Podman machine, not WSL".
            # That confused two different things: the WSL every launcher source
            # file mentions is the one podman-for-windows boots for ITSELF
            # (podman-machine-default), driven by the WINDOWS launcher. It says
            # nothing about a user's own Ubuntu distro, where the LINUX launcher
            # runs and the Linux requirements are the ones that apply.
            #
            # The launcher checked before anything is downloaded, so a machine
            # without podman is told once, at the start, and not mid-install.
            if ! command -v podman >/dev/null 2>&1; then
                # "in WSL" / "on Linux": the same sentence with the platform
                # spelled the way its user would say it, not the way detect_os
                # returns it.
                _pcr_where="on Linux"
                [ "$_pcr_os" = wsl ] && _pcr_where="in WSL"
                if personal_podman_installable; then
                    # THE KIT CAN FETCH IT, so this is not a reason to stop -
                    # and not a reason to say anything either. The database
                    # step names it, asks, and installs it, all within a few
                    # seconds of here; saying it twice made the compatibility
                    # check carry a line about something it was not doing.
                    # Falling through rather than returning: the RAM and
                    # free-disk checks below are the rest of this gate, and a
                    # machine short of both would otherwise hear about neither.
                    :
                else
                    # THE KIT CANNOT FETCH IT HERE - and that used to end the
                    # run before a single file was written, taking the
                    # launcher, exapump, the AI bridge and the exakit command
                    # with it. None of those need Podman. ONE PLACE decides
                    # what a missing Podman costs, and it is the database step:
                    # it records the failure and the closing summary names the
                    # command that finishes the job. Still said here, though,
                    # because hearing it at the start is what saves someone
                    # watching a whole install to find out.
                    warn "Podman is not installed ${_pcr_where}, and the kit cannot install it on this machine."
                    info "The database step will be skipped; everything that does not need it still installs."
                    if [ "$_pcr_os" = wsl ]; then
                        # Inside WSL the package manager is the distro's own,
                        # and uidmap is the part people miss: without it
                        # rootless podman fails later, deep inside a container
                        # start, with an error that names neither podman nor
                        # the missing package.
                        info "Install it inside this distro (Debian/Ubuntu: 'sudo apt-get install -y podman uidmap'), then re-run the installer: $(exakit_install_command)"
                        info "Podman Desktop or Docker Desktop on the WINDOWS side does not count - the launcher runs in here and looks on this PATH."
                    else
                        info "Install it with your package manager (e.g. 'sudo apt-get install -y podman' or 'sudo dnf install -y podman'), then re-run the installer: $(exakit_install_command)"
                    fi
                fi
            fi
            # ROOTLESS IS CHECKED HERE, AND FIXED HERE. Nothing used to look
            # at it on the install path at all: the preflight knew, printed a
            # red line, and the installer went on to deploy anyway - so the
            # first a user heard of a missing sub-id range was a container
            # start failing minutes later, naming neither Podman nor the range.
            # Same place as the podman check above, so it happens before
            # anything is downloaded. Only once Podman exists, though: on a
            # machine that is about to be given it there is nothing yet to
            # check, and personal_install_podman runs this itself the moment
            # the package lands.
            command -v podman >/dev/null 2>&1 && personal_heal_rootless_podman
            ;;
        *)
            error "Exasol Personal supports macOS, Linux (native or WSL) and Windows x86_64 - it does not support $_pcr_os."
            info "Nothing was installed. On Windows use install.ps1."
            die "Incompatible platform: $_pcr_os."
            ;;
    esac

    _arch="$(detect_arch)"
    if [ "$_arch" = "unsupported" ]; then
        error "This machine is not compatible: no Exasol Personal build exists for the '$(uname -m)' CPU architecture."
        info "Supported architectures: Apple Silicon (arm64) and Intel (x86_64)."
        die "Incompatible CPU architecture: $(uname -m)."
    fi

    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_ram" -eq 0 ]; then
            die "Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_ram" -lt "$EXAKIT_PERSONAL_MIN_RAM_GB" ]; then
            error "This machine is not compatible: Exasol Personal needs at least ${EXAKIT_PERSONAL_MIN_RAM_GB} GB RAM and this machine has ${_ram} GB."
            if [ "$_pcr_os" = wsl ]; then
                # /proc/meminfo in WSL reports the VM's share, not the PC's, so
                # "re-run on a bigger machine" would send someone to buy RAM
                # they already own. The knob is on the Windows side.
                info "That is what WSL was given, not what this PC has. Raise it in %USERPROFILE%\\.wslconfig on the WINDOWS side:"
                info "  [wsl2]"
                info "  memory=8GB"
                info "Then apply it from PowerShell: wsl --shutdown  (reopen this distro afterwards)"
                # The escape hatch belongs in BOTH arms. It was only in the else
                # branch, so it was invisible to exactly the users most likely to
                # be refused by a rounding edge on a machine that really does have
                # the memory.
                info "Already sized correctly? Force past this check with EXAKIT_FORCE=1."
            else
                info "Nothing was installed. Re-run on a machine with ${EXAKIT_PERSONAL_MIN_RAM_GB}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            fi
            die "Insufficient memory: ${_ram} GB."
        fi
        if [ "$_disk" -eq 0 ]; then
            die "Could not determine free disk space at $HOME. Free up space or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_disk" -lt "$EXAKIT_PERSONAL_MIN_DISK_GB" ]; then
            error "This machine is not compatible right now: the database needs at least ${EXAKIT_PERSONAL_MIN_DISK_GB} GB free disk and $HOME has ${_disk} GB."
            # WHERE THAT NUMBER CAME FROM, when it did not come from this
            # filesystem. Inside a WSL2 distro the root fs is a sparse VHDX
            # formatted to WSL's maximum, so `df` there can say 900 GB while
            # the Windows drive holding it has 6 - and a refusal quoting 6
            # reads as nonsense to someone whose own `df` says otherwise.
            _pcr_disk_note="$(detect_free_disk_note "$HOME" 2>/dev/null || true)"
            [ -n "$_pcr_disk_note" ] && info "Why: $_pcr_disk_note"
            info "Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient free disk space: ${_disk} GB."
        fi
    fi

    # A knob that does nothing must say so, not be silently ignored: the README
    # and the preflight offer EXAKIT_DB_PORT for port conflicts, but only the
    # container deployments honour it - the launcher picks the port for a
    # personal deployment and the kit reads it back with personal_db_port.
    if [ -n "${EXAKIT_DB_PORT:-}" ] && [ "${EXAKIT_DB_PORT}" != "$(personal_db_port)" ]; then
        warn "EXAKIT_DB_PORT does not choose the port of an Exasol Personal deployment: the launcher selects it and the kit uses whatever it selected (currently $(personal_db_port))."
    fi

    # Bare minimum: run, but say what to expect.
    if [ "$_ram" -lt "$EXAKIT_PERSONAL_COMFORT_RAM_GB" ]; then
        warn "Memory is at the bare minimum (${_ram} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_RAM_GB}+ GB) — the database will run, but expect slower queries and keep other heavy apps closed."
    fi
    if [ "$_disk" -lt "$EXAKIT_PERSONAL_COMFORT_DISK_GB" ]; then
        warn "Free disk is tight (${_disk} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_DISK_GB}+ GB) — fine for the bundled datasets, but watch space before loading large files."
    fi
    ok "Compatibility check passed ($_pcr_os $_arch, ${_ram} GB RAM, ${_disk} GB free)"
}

personal_asset_name() {
    # The launcher's release spelling, verbatim: macOS capitalised mid-word,
    # Linux capitalised - a lowercased guess here is a 404 at download time.
    case "$(detect_os)" in
        macos) _pan_os="macOS" ;;
        *)     _pan_os="Linux" ;;
    esac
    case "$(detect_arch)" in
        arm64)  echo "exasol-personal_${_pan_os}_arm64.tar.gz" ;;
        x86_64) echo "exasol-personal_${_pan_os}_x86_64.tar.gz" ;;
    esac
}

personal_release_url() {
    echo "https://github.com/${EXAKIT_PERSONAL_REPO}/releases/download/v${EXAKIT_PERSONAL_VERSION}"
}

# personal_deployed_version — the launcher version that created the deployment
# currently on disk; empty (non-zero) when there is no deployment, or its
# version cannot be read.
#
# Read from deployment STATE, never by executing a launcher. The decision this
# feeds has to be made BEFORE any binary is downloaded or installed, and the
# only launcher that could answer `exasol info` may be the very one about to be
# overwritten — so asking it is both too late and unreliable. Two state files
# carry the version, both written into the deployment directory by the launcher:
#   .exasolLauncher.version    the bare version ("2.1.0"), no trailing newline
#   .exasolLauncherState.json  "deploymentVersion": "2.1.0"
# The bare file is preferred (nothing to parse); the JSON is the fallback for a
# deployment that only carries it there. Neither needs python3, so this works on
# a machine where the installer has not reached its Python step yet.
personal_deployed_version() {
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 1

    _pdv_raw=""
    _pdv_file="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncher.version"
    if [ -f "$_pdv_file" ]; then
        _pdv_raw="$(tr -d '[:space:]' < "$_pdv_file" 2>/dev/null || true)"
    fi
    if [ -z "$_pdv_raw" ]; then
        _pdv_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
        if [ -f "$_pdv_state" ]; then
            # Plain BRE, no alternation and no -E: the state file is written as
            # one line, and tr keeps it one line even if that ever changes.
            _pdv_raw="$(tr -d '\012\015' < "$_pdv_state" 2>/dev/null | \
                sed -n 's/.*"deploymentVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        fi
    fi

    _pdv_raw="${_pdv_raw#v}"
    # Only answer with something that actually looks like a version. A truncated,
    # empty or garbage state file must read as "unknown" and let the install
    # proceed — never as a version that could wrongly block it.
    case "$_pdv_raw" in
        ""|*[!0-9A-Za-z.+_-]*) return 1 ;;
    esac
    case "$_pdv_raw" in
        [0-9]*) printf '%s\n' "$_pdv_raw" ;;
        *) return 1 ;;
    esac
}

# personal_launcher_version — the version of the launcher BINARY on this
# machine, asked of the binary itself ("exasol version" prints it bare).
#
# The deployment's version and the launcher's version are two different facts,
# and conflating them is what made a completed update advertise itself
# forever: `exakit update` swapped the launcher, personal_record_manifest then
# recorded the DEPLOYMENT's number (unchanged - a deployment keeps the version
# that created it until it is rebuilt), and every later `exakit version` saw
# the same gap and offered the same update again.
#
# Bounded like every other launcher probe, and empty when the launcher cannot
# answer - a caller that cannot learn this falls back to what it knew.
personal_launcher_version() {
    _plv="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" version 2>/dev/null | head -1 | tr -d '[:space:]')"
    _plv="${_plv#v}"
    case "$_plv" in
        ""|*[!0-9A-Za-z.+_-]*) return 1 ;;
        [0-9]*) printf '%s\n' "$_plv" ;;
        *) return 1 ;;
    esac
}

# personal_deployment_outranks <deployed> <advertised> — true ONLY when the
# deployed version is demonstrably higher, comparing dotted numeric components
# left to right and treating a missing component as 0 (so 2.1 > 2). Anything it
# cannot decide is false: this answer blocks an install, and a refusal must never
# be a guess.
#
# Deliberately not exakit_version_newer: without Python that helper falls back to
# "same major, different tag -> worth inspecting" and answers true in BOTH
# directions, which is the right bias for offering an update and exactly the
# wrong one here — it would refuse a legitimate 2.0.0 -> 2.1.0 upgrade on any
# machine that has no Python runtime yet. This comparison needs no Python at all.
personal_deployment_outranks() {
    # Only the numeric release matters for "can this launcher drive this
    # deployment"; drop any pre-release/build suffix.
    _pdo_a="${1#v}"
    _pdo_b="${2#v}"
    _pdo_a="${_pdo_a%%[!0-9.]*}"
    _pdo_b="${_pdo_b%%[!0-9.]*}"
    [ -n "$_pdo_a" ] && [ -n "$_pdo_b" ] || return 1
    while [ -n "$_pdo_a" ] || [ -n "$_pdo_b" ]; do
        _pdo_ha="${_pdo_a%%.*}"
        _pdo_hb="${_pdo_b%%.*}"
        [ -n "$_pdo_ha" ] || _pdo_ha=0
        [ -n "$_pdo_hb" ] || _pdo_hb=0
        case "$_pdo_ha$_pdo_hb" in *[!0-9]*) return 1 ;; esac
        [ "$_pdo_ha" -gt "$_pdo_hb" ] && return 0
        [ "$_pdo_ha" -lt "$_pdo_hb" ] && return 1
        case "$_pdo_a" in *.*) _pdo_a="${_pdo_a#*.}" ;; *) _pdo_a="" ;; esac
        case "$_pdo_b" in *.*) _pdo_b="${_pdo_b#*.}" ;; *) _pdo_b="" ;; esac
    done
    return 1
}

# personal_refuse_launcher_downgrade — never install a launcher older than the
# deployment already on disk.
#
# A launcher refuses to drive a deployment newer than itself, and says so in a
# wall of its own text ending in usage output:
#   deployment directory is incompatible with this launcher: Deployment version
#   2.1.0 is newer than launcher version 2.0.0 (command install)
# Installing the older launcher therefore does not merely fail — it leaves the
# database undriveable, and every re-run fails identically. The trigger is real:
# maintainers lower the advertised set to withdraw a faulty release, and the
# next installer re-run on a machine already carrying the newer deployment
# breaks it.
#
# `exakit update` already refuses a downgrade (and exakit_update_component
# refuses again at the choke point), but both compare the advertised version
# against the INSTALL RECORD, and neither is on this path: the installer calls
# personal_install_launcher directly and held no version opinion at all. This
# guard is not a copy of that one — it asks a different, more authoritative
# question (what is actually deployed on disk), and it answers it before the
# first byte is downloaded.
personal_refuse_launcher_downgrade() {
    [ -n "${EXAKIT_PERSONAL_VERSION:-}" ] || return 0
    _prd_deployed="$(personal_deployed_version 2>/dev/null || true)"
    [ -n "$_prd_deployed" ] || return 0
    personal_deployment_outranks "$_prd_deployed" "$EXAKIT_PERSONAL_VERSION" || return 0

    error "The Exasol Personal deployment on this machine is version ${_prd_deployed}, which is newer than the launcher version this kit advertises (${EXAKIT_PERSONAL_VERSION})."
    info "A ${EXAKIT_PERSONAL_VERSION} launcher refuses to drive a ${_prd_deployed} deployment, so installing it would leave your database unusable. Nothing was installed or changed."
    info "Deployment: $(ui_tilde "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    info "To install the launcher that matches your deployment, re-run with: EXAKIT_PERSONAL_VERSION=${_prd_deployed}"
    info "To start over on ${EXAKIT_PERSONAL_VERSION} instead, remove the newer deployment first with 'exakit uninstall' — that deletes its data."
    die "Refusing to install launcher ${EXAKIT_PERSONAL_VERSION} over a newer ${_prd_deployed} deployment."
}

# personal_install_launcher — download, verify, and install the `exasol` CLI.
# An already-installed launcher is only accepted if it supports the 'local'
# preset (older releases do not); otherwise the resolved version is installed
# alongside it and preferred.
personal_install_launcher() {
    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && command -v exasol >/dev/null 2>&1; then
        _existing="$(command -v exasol)"
        # BOUNDED, and anchored to a subcommand line. Bounded because a wedged
        # launcher answers `install --help` no faster than it answers anything
        # else and this is the first thing the installer runs; anchored because
        # `grep -w local` matched the word ANYWHERE in free-form help text --
        # a description like "Stop a running local deployment" was enough to
        # accept a launcher that has no `local` preset at all.
        if exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$_existing" install --help 2>/dev/null \
                | personal_help_names_token "local"; then
            ok "Exasol launcher already installed: $_existing"
            return 0
        fi
        warn "The installed Exasol launcher ($_existing) does not support the 'local' preset (too old)."
        info "Installing launcher v${EXAKIT_PERSONAL_VERSION} to $EXAKIT_PERSONAL_BIN — your existing launcher is left untouched"
    fi

    # Refuse before acting: from here on the advertised version WILL be written
    # over whatever launcher this kit manages, so the deployment on disk gets its
    # veto now, while nothing has been downloaded or overwritten yet. Deliberately
    # after the early return above: a launcher already on PATH that is new enough
    # for the deployment is kept as it always was, and that case installs nothing
    # to object to.
    personal_refuse_launcher_downgrade

    _asset="$(personal_asset_name)"
    _base="$(personal_release_url)"
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-personal.XXXXXX")"

    # The whole step on ONE line. begin_step already set a spinner label, and
    # fetch/run_logged animate it, so every stage here was narrated twice: once
    # live by the spinner, then permanently by an info/ok pair repeating it --
    # four lines carrying two facts, each ✓ restating the bullet above it.
    # EXAKIT_QUIET_DETAIL routes that pair to the LOGFILE and leaves the spinner
    # as the narration. Same save-and-restore bracket as exakit_marketplace_install
    # in common.sh, and for the same reason; warn/error stay ungated there, so a
    # step that says nothing while it works still speaks when it goes wrong.
    #
    # Gated on a terminal: without one ui_spin_begin draws nothing, and quieting
    # the detail as well would leave a CI log silent for the length of a
    # download. Piped or redirected, the info lines stay and nothing changes.
    _pil_prev_label="${EXAKIT_ACTIVE_LABEL:-}"
    _pil_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    _pil_t0="$(date +%s 2>/dev/null || echo 0)"

    # Re-assigned per phase rather than printed: fetch and run_logged read this
    # at their next ui_spin_begin, so the words change on the operation boundary
    # without a second animator and without restarting the one already running.
    EXAKIT_ACTIVE_LABEL="Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION}"
    info "Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION} ($_asset)"
    fetch "$_base/$_asset" "$_tmp/$_asset"
    fetch "$_base/exasol-personal_${EXAKIT_PERSONAL_VERSION}_checksums.txt" "$_tmp/checksums.txt"
    verify_sha256_from_file "$_tmp/$_asset" "$_tmp/checksums.txt"

    EXAKIT_ACTIVE_LABEL="Installing launcher to $(ui_tilde "$EXAKIT_PERSONAL_BIN")"
    info "Installing launcher to $(ui_tilde "$EXAKIT_PERSONAL_BIN")"
    mkdir -p "$EXAKIT_BIN_DIR"
    run_logged tar -xzf "$_tmp/$_asset" -C "$_tmp" || die "Could not extract $_asset"
    _binary="$(find "$_tmp" -name exasol -type f | head -1)"
    [ -n "$_binary" ] || die "The release archive did not contain an 'exasol' binary"
    install -m 755 "$_binary" "$EXAKIT_PERSONAL_BIN" \
        || die "Could not install the Exasol launcher to $EXAKIT_PERSONAL_BIN (is it writable? is the disk full?)."
    push_rollback "rm -f \"$EXAKIT_PERSONAL_BIN\""
    rm -rf "$_tmp"

    # Prove the downloaded binary can actually be executed before anything
    # treats its silence as an answer. A checksum says the bytes arrived
    # intact; it says nothing about whether this kernel will run them.
    exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$EXAKIT_PERSONAL_BIN" --version >/dev/null 2>&1
    _pil_rc=$?
    if exakit_unsigned_binary_hint "$EXAKIT_PERSONAL_BIN" "$_pil_rc"; then
        EXAKIT_QUIET_DETAIL="$_pil_prev_quiet"
        EXAKIT_ACTIVE_LABEL="$_pil_prev_label"
        die "The Exasol launcher was downloaded and verified but cannot be executed on this machine."
    fi

    EXAKIT_QUIET_DETAIL="$_pil_prev_quiet"
    EXAKIT_ACTIVE_LABEL="$_pil_prev_label"
    # After the restore, never inside it: this one can end in an `ok` reporting
    # that the kit edited the user's shell profile, which is not a line to send
    # to the logfile.
    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "Exasol launcher v${EXAKIT_PERSONAL_VERSION} installed to $(ui_tilde "$EXAKIT_PERSONAL_BIN") ($(( $(date +%s 2>/dev/null || echo 0) - _pil_t0 ))s)"
}

personal_cli() {
    # Prefer the kit-installed managed launcher; fall back to one on PATH.
    if [ -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "$EXAKIT_PERSONAL_BIN"
    elif command -v exasol >/dev/null 2>&1; then
        command -v exasol
    else
        echo "$EXAKIT_PERSONAL_BIN"
    fi
}

# Launcher probes are BOUNDED. exakit_run_bounded was written because macOS has
# no timeout(1) - and then guarded only the container-engine probes, which run
# on the platforms that have it. Every macOS launcher probe stayed unbounded,
# so `exakit status` - the command AGENTS.md tells agents to poll - could hang
# forever on exactly the wedged launcher the module ships a reaper for.
EXAKIT_PERSONAL_PROBE_TIMEOUT="${EXAKIT_PERSONAL_PROBE_TIMEOUT:-10}"

# personal_db_port — the port THIS deployment is on, which is not necessarily
# EXAKIT_PERSONAL_PORT.
#
# Exasol Personal 2.3 selects and persists a concrete database port during
# initialization, keeps it stable across restarts and lets it be changed while
# the deployment is stopped. Every probe that asked the constant instead was
# wrong on a deployment that chose another port: status read a silent 8563 and
# reported the database stopped while it was running, and the conflict arm
# could fire on an unrelated listener.
#
# The launcher's own deployment.json is the answer; the constant is the answer
# only until one exists. No Python: this is on the status path, which must work
# on a machine whose interpreter is not up yet.
personal_db_port() {
    _pdp_file="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _pdp=""
    if [ -f "$_pdp_file" ]; then
        _pdp="$(tr -d '\012\015' < "$_pdp_file" 2>/dev/null | \
            sed -n 's/.*"dbPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    fi
    case "$_pdp" in
        ''|*[!0-9]*) _pdp="$EXAKIT_PERSONAL_PORT" ;;
    esac
    printf '%s' "$_pdp"
}

personal_deployment_exists() {
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && \
        exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" info >/dev/null 2>&1
}

# personal_deployment_running — is a local Exasol deployment actually up and
# reachable right now? Some launcher versions can answer `exasol info` even
# before the SQL listener exists, so require both signals before reusing an
# existing database.
personal_deployment_running() {
    port_in_use "$(personal_db_port)" || return 1
    if personal_deployment_exists; then
        # THE LAUNCHER'S WORD OUTRANKS THE PORT. "stopped" can leave a runner
        # answering (see personal_status); "deployment_failed" is a first boot
        # the launcher gave up on - reconciled by personal_deploy_local, never
        # adopted as running, or its stop and start stay no-ops for good.
        case "$(personal_launcher_state 2>/dev/null || true)" in
            stopped|deployment_failed) return 1 ;;
        esac
        personal_db_answers
        return $?
    fi
    # NO DEPLOYMENT OF OURS. Something answers on the port, but only a SELECT
    # through the kit's own profile proves it is this kit's database. Windows
    # and WSL share one network stack, so a database deployed on either side
    # holds 8563 for both - and adopting the other side's database here handed
    # the rest of the install a password that could never work against it.
    command -v exakit_db_reachable >/dev/null 2>&1 && \
        [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] && \
        exakit_db_reachable
}

# personal_db_answers — is the thing on the SQL port actually Exasol? A real
# SELECT through the kit's exapump profile when that module is loaded (it is,
# in the CLI and the installer); without it, a completed TLS handshake
# (personal_tls_answers). Port open alone is never the answer: see
# personal_status - and under rootless Podman the open port is pasta's, there
# from the moment the container starts and a minute or more before the database
# inside it accepts a connection.
personal_db_answers() {
    # THE HANDSHAKE ALONE, for a deployment that is ours. Asking exapump for a
    # SELECT here made the database's liveness depend on a second tool: when a
    # virus scanner held the freshly installed exapump binary, every probe said
    # "not running" about a database that was up, and the installer went on to
    # "self-heal" it. Proving WHOSE database answers is a different question,
    # asked only where it arises — see personal_deployment_running.
    personal_tls_answers
}

# personal_tls_answers — does the database complete a TLS handshake on its
# port? The one probe that tells a database apart from the process publishing
# its port: pasta (rootless Podman) and the launcher's own runner accept the
# TCP connection themselves and reset it when nothing answers behind them,
# which every SQL client reports as "tls handshake eof" - the launcher's own
# 27-second first-boot budget ran out on exactly that, and a port-open wait
# returned the instant the container started. openssl where it exists (macOS,
# nearly every Linux), python3 otherwise, the bare port as the last resort.
personal_tls_answers() {
    _pta_port="$(personal_db_port)"
    if command -v openssl >/dev/null 2>&1; then
        exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" openssl s_client -connect "127.0.0.1:$_pta_port" </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE'
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" python3 -c 'import socket, ssl, sys
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5) as s:
    ctx.wrap_socket(s, server_hostname="localhost").close()' "$_pta_port" >/dev/null 2>&1
        return $?
    fi
    port_in_use "$_pta_port"
}

# personal_foreign_db_hint — one sentence for a port that answers like Exasol
# but is not this kit's deployment; empty when nothing completes a handshake.
# Windows and WSL share one network stack, so a database deployed on either
# side holds 8563 for both; naming that spares the reader a hunt for an
# application that is not there.
personal_foreign_db_hint() {
    personal_tls_answers || return 0
    # NAME WHAT IS ACTUALLY THERE. A recorded container of this machine's own
    # previous kit is the commonest holder of this port, and telling that user
    # to go and stop something in WSL sends them looking for a database that
    # does not exist. The crossing is the road out of it.
    if command -v legacy_db_recorded >/dev/null 2>&1 && legacy_db_recorded && \
       [ "$(legacy_container_state 2>/dev/null || true)" = "running" ]; then
        printf ' It is the container database of your previous starter kit (%s), which this kit no longer manages. Stop it (%s stop %s) and re-run the installer, which then offers to copy its data across.' \
            "$(legacy_container)" "$(legacy_engine_name)" "$(legacy_container)"
        return 0
    fi
    printf ' It answers like an Exasol database this kit did not deploy: stop that database first, then re-run.'
    detect_wsl_version >/dev/null 2>&1 && \
        printf ' WSL and Windows share this port, so one deployed on the Windows side holds it here too (stop it there with: exakit stop).'
    return 0
}

# personal_launcher_state — the LAUNCHER'S OWN WORD for this deployment, from
# `exasol status --json` ("stopped", "running", ...), empty when it cannot say.
#
# It exists because the port is not the owner. After `exasol stop` on 2.3 the
# deployment is stopped and its runner process can still be alive and still
# forwarding to a VM that still answers SQL - so a port probe reports a
# database the launcher has already let go of, `exakit start` says "already
# running", and the user cannot restart at all.
#
# --json since 2.3; the plain output is parsed as the fallback so a 2.2
# launcher still answers. Bounded like every other probe, and the launcher's
# own five-second ceiling keeps it honest on an unresponsive deployment.
personal_launcher_state() {
    _pls_out="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" status --json 2>/dev/null || true)"
    _pls="$(printf '%s' "$_pls_out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$_pls" ]; then
        _pls_out="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" status 2>/dev/null || true)"
        _pls="$(printf '%s' "$_pls_out" | sed -n 's/^[[:space:]]*Status:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"
    fi
    printf '%s' "$_pls" | tr '[:upper:]' '[:lower:]'
}

# personal_port_holder_hint — " (pid N, name)" for the process on the port, or
# nothing when lsof cannot say. Suffix for a conflict message.
personal_port_holder_hint() {
    _pph_pid="$(personal_db_port_pids | head -1)"
    [ -n "$_pph_pid" ] || return 0
    _pph_name="$(ps -p "$_pph_pid" -o comm= 2>/dev/null | sed 's|.*/||')"
    printf ' (pid %s%s)' "$_pph_pid" "${_pph_name:+, $_pph_name}"
}

# personal_db_port_pids — PIDs currently LISTENing on the deployment port.
personal_db_port_pids() {
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -nP -iTCP:"$(personal_db_port)" -sTCP:LISTEN -t 2>/dev/null | sort -u
}

# personal_is_orphan_daemon PID — true only if PID is an Exasol Personal local
# runner. Scopes cleanup so we never kill an unrelated application that happens
# to hold the port.
#
# TWO SHAPES, because the launcher renamed its runner: 2.2 ran
# "mac-runner ... __daemon__", and 2.3 runs
# .../exasol-local-runner/<os>/<arch>/<hash>/unpack/launcher. Matching only the
# 2.2 spelling meant that on 2.3 the kit called its OWN leftover runner a
# foreign process, refused to touch it, and left the port held by something it
# had itself started - with the deploy path's hard stop as the only outcome.
# A matching daemon younger than this is presumed to be a healthy runner still
# coming up, not an orphan. Exasol Personal's own start budget is about two
# minutes; 180s leaves margin on a slow or loaded machine. Set to 0 to reap by
# name alone, which is what this code used to do unconditionally.
EXAKIT_PERSONAL_REAP_MIN_AGE="${EXAKIT_PERSONAL_REAP_MIN_AGE:-180}"

# _personal_proc_age_seconds <pid> - how long that process has been alive.
# `ps -o etime=` is the portable spelling ([[dd-]hh:]mm:ss); etimes is GNU-only
# and absent on the macOS ps. awk does the parsing so a zero-padded field
# ("08") is read as decimal rather than tripping shell octal arithmetic.
_personal_proc_age_seconds() {
    ps -p "$1" -o etime= 2>/dev/null | awk '
        {
            gsub(/ /, "", $0)
            if ($0 == "") exit 1
            d = 0
            if (index($0, "-") > 0) {
                d = substr($0, 1, index($0, "-") - 1) + 0
                $0 = substr($0, index($0, "-") + 1)
            }
            n = split($0, p, ":")
            if (n == 3)      { s = p[1] * 3600 + p[2] * 60 + p[3] }
            else if (n == 2) { s = p[1] * 60 + p[2] }
            else             { s = p[1] + 0 }
            print d * 86400 + s
            exit 0
        }'
}

# personal_is_orphan_daemon <pid> - is this process ours AND abandoned?
#
# THE NAME ALONE WAS THE WHOLE TEST, AND A HEALTHY RUNNER MID-START HAS THAT
# NAME. That made the worst path in the kit: personal_status answers `conflict`
# for any port that is bound while the database does not yet answer SQL - which
# is precisely a deployment's startup window - and cmd_start reads `conflict` as
# "probably our own orphan" and calls the reaper, which escalates to
# `pkill -9 -P` plus `kill -9`. So a second `exakit start` during startup (two
# shells, a user who thinks nothing happened, an agent that retries) SIGKILLed
# the starting runner. What that costs is recorded 900 lines away in setup/exakit:
# a SIGKILLed runner leaves the launcher's workflow state `interrupted`, after
# which every start fails identically forever, and the only documented cure is
# `exakit repair-runtime` - which deletes the database. For someone with three
# months of unbacked-up tables that is the difference between a pause and a loss.
#
# Two more questions before the kill, both cheap:
#   age    - a process that started seconds ago is starting, not stranded.
#   state  - the launcher's own word. A genuine orphan is one the launcher has
#            let go of (stopped / deployment_failed / interrupted), or one it
#            cannot speak for at all (empty). Anything else means it believes
#            this deployment is live, and we do not get to overrule it.
# Erring toward NOT reaping is the right bias: the cost of a missed reap is a
# clear "port is held" message and a manual stop. The cost of a wrong reap is
# the user's data.
# _personal_is_runner_process <pid> - does this process LOOK like our runner?
# The name test alone, shared by the reaper (which additionally needs it to be
# old and abandoned) and by personal_starting (which needs it to be young).
# One definition, so the two can never disagree about whose process it is.
_personal_is_runner_process() {
    case "$(ps -p "$1" -o command= 2>/dev/null || true)" in
        *mac-runner*__daemon__*) return 0 ;;
        *exasol-local-runner*)   return 0 ;;
    esac
    return 1
}

# personal_starting - is the port held by OUR OWN runner, still within its
# start budget? Then the database is coming up, not in conflict with anything.
#
# personal_status had no such state: port bound + launcher not "stopped" + SQL
# not answering yet is exactly a deployment's startup window, and it was
# reported as `conflict` - which reads as "another program has your port" on a
# machine that has no such program. Two consequences. The post-update check in
# common.sh already had a `starting` arm that could never be reached, so it
# fell to the catch-all and warned about a conflict for a database that was
# simply booting. And `conflict` is what sends cmd_start into the reaper, which
# is the first step of the path that SIGKILLs a healthy starting runner.
personal_starting() {
    command -v personal_db_port_pids >/dev/null 2>&1 || return 1
    for _pst_pid in $(personal_db_port_pids 2>/dev/null || true); do
        _personal_is_runner_process "$_pst_pid" || continue
        _pst_age="$(_personal_proc_age_seconds "$_pst_pid" 2>/dev/null || true)"
        [ -n "$_pst_age" ] || continue
        [ "$_pst_age" -lt "${EXAKIT_PERSONAL_REAP_MIN_AGE:-180}" ] && return 0
    done
    return 1
}

personal_is_orphan_daemon() {
    _personal_is_runner_process "$1" || return 1
    if [ "${EXAKIT_PERSONAL_REAP_MIN_AGE:-0}" -gt 0 ]; then
        _iod_age="$(_personal_proc_age_seconds "$1" 2>/dev/null || true)"
        if [ -n "$_iod_age" ] && [ "$_iod_age" -lt "$EXAKIT_PERSONAL_REAP_MIN_AGE" ]; then
            # Guarded: this predicate is reachable with runtime-personal.sh
            # sourced on its own, where common.sh's logger does not exist, and
            # a decision this important must not depend on a log line.
            command -v _exakit_log_file >/dev/null 2>&1 &&
                _exakit_log_file "INFO  not reaping pid $1: ${_iod_age}s old, still within the start budget"
            return 1
        fi
    fi
    case "$(personal_launcher_state 2>/dev/null || true)" in
        ''|stopped|deployment_failed|interrupted) return 0 ;;
        *) command -v _exakit_log_file >/dev/null 2>&1 &&
               _exakit_log_file "INFO  not reaping pid $1: the launcher still calls this deployment live"
           return 1 ;;
    esac
}

# personal_reap_orphan_daemon — the Exasol Personal launcher can leave an
# orphaned "mac-runner ... __daemon__" process bound to the database port after
# a failed deploy, or after a destroy that could not find its PID file (it logs
# "VM is not running (no PID file found)"). The orphan then makes the next
# deploy fail with "bind: operation not permitted" on vm.sock and makes MCP
# clients see "Connection reset by peer". Reap only that specific daemon; a
# genuinely foreign process on the port is reported and left untouched.
# Returns 0 if the port ends up free (or was never held), 1 otherwise.
personal_reap_orphan_daemon() {
    _rod_port="$(personal_db_port)"
    # Judge the port by whether a process is actually LISTENing on it, not by a
    # bare TCP connect: after a teardown, client sockets linger in
    # CLOSE_WAIT/TIME_WAIT and would make a connect test wrongly report "in use".
    if ! command -v lsof >/dev/null 2>&1; then
        if port_in_use "$_rod_port"; then
            warn "Port $_rod_port is in use but 'lsof' is unavailable to identify the process; cannot auto-clean a leftover Exasol daemon."
            return 1
        fi
        return 0
    fi

    _listeners="$(personal_db_port_pids)"
    [ -n "$_listeners" ] || return 0   # nothing listening → port is free

    _reaped=""
    for _pid in $_listeners; do
        if personal_is_orphan_daemon "$_pid"; then
            info "Reaping orphaned Exasol runner daemon (pid $_pid) still holding port $_rod_port"
            pkill -P "$_pid" 2>/dev/null || true
            kill "$_pid" 2>/dev/null || true
            _reaped="$_reaped $_pid"
        else
            warn "Port $_rod_port is held by a non-Exasol process (pid $_pid: $(ps -p "$_pid" -o command= 2>/dev/null | cut -c1-80)); leaving it untouched."
        fi
    done

    # Only a foreign listener remains (nothing of ours to reap) → not our port.
    [ -n "$_reaped" ] || return 1

    # Wait for the listener to release the port (SIGTERM path, up to ~5s), then
    # force-kill any survivor and its children and give it a moment to settle.
    _waited=0
    while [ "$_waited" -lt 5 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done
    for _pid in $_reaped; do
        if kill -0 "$_pid" 2>/dev/null; then
            pkill -9 -P "$_pid" 2>/dev/null || true
            kill -9 "$_pid" 2>/dev/null || true
        fi
    done
    _waited=0
    while [ "$_waited" -lt 3 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done

    if [ -n "$(personal_db_port_pids)" ]; then
        warn "Port $_rod_port still has a listening process after reaping the Exasol daemon."
        return 1
    fi
    ok "Freed port $_rod_port (removed a leftover Exasol runner daemon)"
    return 0
}

# --- deployment progress ----------------------------------------------------
# `exasol install local` narrates itself in structured JSON and then prints a
# forty-line connection overview -- none of which the person waiting for a
# database can act on, and all of whose useful parts the kit restates in its own
# closing panel. So the stream is consumed rather than shown: each line is
# matched against the launcher's own milestone messages, and one line is redrawn
# in place with a bar, a percentage and the phase in plain English.
#
# Nothing is lost by hiding it. Every raw line still goes to the logfile exactly
# as before; a copy is kept so a FAILED deploy can print the launcher's own last
# words instead of only a log path; and the launcher's EULA notice -- the one
# part of that output the user genuinely must see -- is replayed afterwards, in
# the launcher's own words rather than a copy of them that could go stale.

# _personal_deploy_milestone <line> — "<pct>|<phase>" for a line that marks
# progress, nothing for any other line.
#
# The strings are the launcher's own log messages, matched as plain substrings
# rather than as JSON so that a switch to text logging keeps working. An
# unrecognised line simply does not move the bar, which is what makes a launcher
# release that renames a message degrade to a slower-looking bar instead of to a
# wrong one. The percentages are milestone positions, not a measured fraction of
# the work: the bar moves only when the launcher has actually reached the next
# stage, and the elapsed counter -- which ticks every second whatever the
# launcher is doing -- is what says "still alive" in between.
#
# KEEP EVERY PHASE TO 21 CHARACTERS OR FEWER. The phase gets 30% of the progress
# line: 21 columns on an 80-column terminal, 27 on a 100, and never more than 33
# however wide the window is opened. Anything longer is ellipsed -- and a phrase
# cut mid-word tells the reader less than a shorter one would have said whole.
_personal_deploy_milestone() {
    case "$1" in
        *"validating presets"*)                    printf '5|10|2|Preparing to deploy' ;;
        *"extracting preset files"*)               printf '10|20|2|Preparing to deploy' ;;
        *"successfully initialized deployment"*)   printf '20|35|5|Preparing to deploy' ;;
        # The long one, and the only label that covers two different situations:
        # the launcher emits one of these whether it DOWNLOADED the resource or
        # found it already cached. It said "Fetching the Exasol runtime" for
        # both, which was wrong on the warm path twice over -- nothing is
        # fetched, and per the note below the launcher then goes quiet for the
        # VM boot, so "fetching" sat on screen through twenty-five seconds of
        # something else entirely. The wording now holds either way.
        #
        # On a warm cache the launcher says nothing at all between here and
        # "waiting for database to start" -- about twenty-five seconds of VM
        # boot -- so the ceiling is that next milestone rather than the
        # "starting deployment" one, which a warm run never emits. If it DOES
        # emit it, the line below picks the segment up mid-flight.
        #
        # It is also short, per the budget above: the first wording here ran to
        # 33 characters and was ellipsed on every terminal but the very widest.
        *"fetching resource"*|*"found resource in cache"*)
                                                   printf '35|65|25|Getting Exasol ready' ;;
        *"starting deployment"*)                   printf '45|65|15|Starting the database' ;;
        *"waiting for database to start"*)         printf '65|90|10|Waiting for Exasol' ;;
        *"installing script language container"*)  printf '80|90|15|Installing languages' ;;
        *"no installation steps defined"*)         printf '90|100|4|Finishing up' ;;
        *"Completed deploying"*)                   printf '100|100|0|Deployed' ;;
    esac
}

# Eighths of a block. A twenty-cell bar advancing in whole cells steps 5% at a
# time, which at five frames a second reads as a bar that is stuck and then
# jumps. The partial-block glyphs give the same bar eight times the resolution,
# so it creeps. Index 0 is a space: the frontier cell is EMPTY when there is no
# fraction to draw, which is what keeps the dim remainder unbroken.
# _personal_deploy_collect <state-file> <tail-file> <notice-file> — consume the
# launcher's output: log every line, keep the tail, keep the EULA notice, and
# turn the lines that mean something into progress. It runs on the right-hand
# side of the pipe, so everything it learns has to be handed back through files.
_personal_deploy_collect() {
    _pdc_pct=0
    _pdc_phase=""
    _pdc_shown=""
    _pdc_quiet=0
    _pdc_stalled=0
    while :; do
        _pdc_line=""
        # A bounded read, not a blocking one. The launcher re-attaches stdin to
        # the terminal so a first-run licence confirmation can read the
        # keyboard - but the PROMPT arrives here without a newline, so it never
        # leaves this pipe: the question sat invisible in the buffer while the
        # bar showed 5% forever, with nothing anywhere saying why. The install
        # cannot answer a licence question for the user (and must not), so the
        # bounded read exists to NOTICE the silence and put the situation on
        # screen, where the still-connected keyboard can resolve it.
        #
        # bash 3.2 returns the SAME code for a timeout and for EOF, so the two
        # are told apart by the clock: only a wait that consumed the whole
        # window was a timeout. (A final line without a trailing newline also
        # returns non-zero, with the line in the variable - kept, then EOF on
        # the next pass.)
        _pdc_win="${EXAKIT_PERSONAL_DEPLOY_STALL:-300}"
        [ "$_pdc_win" -gt 30 ] && _pdc_win=30
        # Floor of 2: the EOF discriminator below needs at least one full second
        # of difference between "returned instantly" and "waited the window".
        [ "$_pdc_win" -lt 2 ] && _pdc_win=2
        _pdc_t0=$SECONDS
        if IFS= read -r -t "$_pdc_win" _pdc_line; then
            _pdc_quiet=0
        elif [ -z "$_pdc_line" ] && [ $((SECONDS - _pdc_t0)) -lt $((_pdc_win - 1)) ]; then
            break   # EOF
        elif [ -z "$_pdc_line" ]; then
            _pdc_quiet=$((_pdc_quiet + (SECONDS - _pdc_t0)))
            if [ "$_pdc_quiet" -ge "${EXAKIT_PERSONAL_DEPLOY_STALL:-300}" ] && [ "$_pdc_stalled" -eq 0 ]; then
                _pdc_stalled=1
                # Stop the animation and switch to plain lines: a bar that
                # keeps creeping is the opposite of what a stalled launcher
                # should look like. warn is never gated by EXAKIT_QUIET_DETAIL.
                ui_progress_end
                EXAKIT_DEPLOY_LIVE=0
                if [ "$_pdc_quiet" -ge 120 ]; then
                    warn "The launcher has said nothing for $((_pdc_quiet / 60)) minutes."
                else
                    warn "The launcher has said nothing for $_pdc_quiet seconds."
                fi
                warn "It may be waiting for a first-run confirmation it could not display. Your keyboard is still connected to it - typing an answer here reaches it."
                _personal_deploy_print_tail "$2"
                warn "Still waiting. Full output: ${EXAKIT_LOG_FILE:-the install log}. Ctrl-C is safe - re-running the installer resumes, or run '$(personal_cli) install local' yourself to see the prompt."
            fi
            continue
        fi
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_pdc_line" >> "$EXAKIT_LOG_FILE"
        printf '%s\n' "$_pdc_line" >> "$2"
        case "$_pdc_line" in
            *"End User License Agreement"*|*"terms-and-conditions"*)
                printf '%s\n' "$_pdc_line" >> "$3" ;;
        esac
        _pdc_hit="$(_personal_deploy_milestone "$_pdc_line")"
        [ -n "$_pdc_hit" ] || continue
        # Monotonic: a message arriving out of the expected order never rewinds
        # the bar, and a repeated one never redraws it.
        [ "${_pdc_hit%%|*}" -gt "$_pdc_pct" ] 2>/dev/null || continue
        _pdc_pct="${_pdc_hit%%|*}"
        _pdc_rest="${_pdc_hit#*|}"
        _pdc_ceil="${_pdc_rest%%|*}"; _pdc_rest="${_pdc_rest#*|}"
        _pdc_secs="${_pdc_rest%%|*}"
        _pdc_phase="${_pdc_rest#*|}"
        ui_progress_state "$1" "$_pdc_pct" "$_pdc_ceil" "$_pdc_secs" "$_pdc_phase"
        # Nothing is animating (piped, CI, NO_COLOR, a dumb terminal): one plain
        # logged line per phase, rather than a line that redraws nothing. After
        # a stall the quiet-detail gate is bypassed - the launcher just came
        # back to life and the reader deserves to see it move again.
        if [ "${EXAKIT_DEPLOY_LIVE:-0}" != 1 ] && [ "$_pdc_phase" != "$_pdc_shown" ]; then
            if [ "$_pdc_stalled" -eq 1 ]; then
                info_step "$_pdc_phase"
            else
                info "$_pdc_phase"
            fi
            _pdc_shown="$_pdc_phase"
        fi
    done
}

# _personal_deploy_print_tail <file> — the launcher's own last words, in the dim
# gutter foreign output has always used here. A failed deploy used to leave the
# whole stream on screen; now that the stream is consumed, the end of it is what
# has to survive, or a failure would be left with nothing but a log path.
_personal_deploy_print_tail() {
    [ -s "$1" ] || return 0
    foreign_note "last lines from the exasol launcher"
    tail -n 12 "$1" | while IFS= read -r _pdt_line; do
        printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$_pdt_line" "${UI_RESET:-}"
    done
}

# _personal_deploy_print_notice <file> — replay the launcher's EULA notice. It is
# the one part of the hidden output the user must still see, and it is replayed
# verbatim so this kit never states licence terms in words of its own.
_personal_deploy_print_notice() {
    [ -s "$1" ] || return 0
    _pdn_first=1
    while IFS= read -r _pdn_line; do
        [ -n "$_pdn_line" ] || continue
        if [ "$_pdn_first" = 1 ]; then
            info "$_pdn_line"
            _pdn_first=0
        else
            printf '      %s%s%s\n' "${UI_DIM:-}" "$_pdn_line" "${UI_RESET:-}"
            _exakit_log_file "INFO  $_pdn_line"
        fi
    done < "$1"
}

# personal_recover_slow_first_boot — the launcher gave up on a first boot that
# was merely slow; wait with the kit's budget and reconcile the launcher.
#
# When the launcher's 27-second wait runs out it records deployment_failed and,
# in that state, its own `stop` and `start` do nothing - so a database that came
# up ten seconds later was reported as a failed install, and every later
# `exakit start` waited the full 150 s for a port the launcher would never bring
# back. Observed four times in one day. The port answering is the evidence that
# matters; when it does, the launcher's own `deploy` retry (its advice on the
# failure) makes its record agree. If that retry still fails while the database
# answers, the kit says so and carries on with the database it can reach - the
# launcher's record is a bookkeeping problem, not a missing database.
# Returns 1 only when the database never answered within the budget.
personal_recover_slow_first_boot() {
    _prs_budget="${EXAKIT_PERSONAL_READY_TIMEOUT:-150}"
    info "The launcher stopped waiting after its own short budget, but the deployment exists — waiting up to ${_prs_budget}s for the database"
    _prs_t0="$(date +%s 2>/dev/null || echo 0)"
    _prs_tries=0
    until personal_tls_answers; do
        _prs_tries=$(( _prs_tries + 1 ))
        _prs_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _prs_t0 ))
        [ "$_prs_elapsed" -ge "$_prs_budget" ] && return 1
        [ "$_prs_tries" -ge $(( _prs_budget / 5 + 1 )) ] && return 1
        sleep 5
    done
    ok "The database answered after $(( $(date +%s 2>/dev/null || echo 0) - _prs_t0 ))s"
    EXAKIT_ACTIVE_LABEL="Reconciling the launcher's record"
    # THE RECONCILE IS THE OWNERSHIP PROOF. A handshake says a database answers
    # on the port, not whose: with Windows and WSL sharing one network stack it
    # may be the other side's. The launcher's deploy connects with this
    # deployment's own credentials, so its success is the one signal that the
    # database that answered is this one - and its failure is a failure, not a
    # database "the kit can reach".
    if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy); then
        ok "The launcher's record agrees with the running database"
        return 0
    fi
    warn "The launcher still records this deployment as failed although something answers on port $(personal_db_port).$(personal_foreign_db_hint)"
    return 1
}

# _personal_podman_answers - the smallest question that needs all of podman to
# work. Sets _ppr_said to the last thing it said, for the reason line.
_personal_podman_answers() {
    _ppr_said="$(exakit_run_bounded 30 podman info --format '{{.Host.Arch}}' 2>&1)" && return 0
    _ppr_said="$(printf '%s\n' "$_ppr_said" | grep -v '^[[:space:]]*$' | tail -1)"
    return 1
}

# personal_podman_running - INSTALLED IS NOT RUNNING, and the difference is a
# whole failed install. `command -v podman` answers whether the binary is on
# PATH; it says nothing about whether podman can start a container. A rootless
# podman with no sub-id range, a storage directory left behind by a different
# uid, a service the distro never enabled - each of those has podman on PATH
# and fails the instant the launcher asks it for anything, several minutes in,
# with an error that names neither podman nor the kit.
#
# Podman on Linux has no daemon to be "up", so `podman info` IS the check: it
# needs the binary, the storage, the sub-id ranges and the user namespace, and
# it is the same thing the launcher does first. Windows has a machine that can
# be stopped, which is why its twin (Test-PersonalPodmanRunning) starts one.
#
# 0 when podman answers, 1 when it does not - with the reason left behind for
# the step to record. Not installed is 0: that is a different failure, already
# named by personal_install_podman.
personal_podman_running() {
    # Linux and WSL only, like personal_install_podman above. The macOS launcher
    # brings its own container runtime, so a Podman Desktop the user installed
    # and left stopped has nothing to do with the deployment - checking it
    # skipped the database step on a Mac that could deploy.
    case "$(detect_os)" in
        linux|wsl) : ;;
        *) return 0 ;;
    esac
    command -v podman >/dev/null 2>&1 || return 0
    _personal_podman_answers && return 0
    # ONE REPAIR, THEN ASK AGAIN. Much the commonest reason a rootless podman
    # is installed and still cannot start anything is a missing sub-id range,
    # which the heal fixes with consent. Anything else is reported as it is.
    personal_heal_rootless_podman
    _personal_podman_answers && return 0
    warn "Podman is installed, but it cannot run containers on this machine."
    [ -n "${_ppr_said:-}" ] && info "What it said: $_ppr_said"
    info "Check it with 'podman info'; once that answers, re-run the installer to finish the install: $(exakit_install_command)"
    exakit_note_failure "Podman is installed but not usable ('podman info' failed): ${_ppr_said:-no output}"
    return 1
}

# personal_deploy_local — run the local deployment. This is the long step
# (usually under 2 minutes); output stays visible and is logged.
personal_deploy_local() {
    # BEFORE ANYTHING ELSE IN THIS STEP: the deployment runs through Podman, so
    # a machine without it is given it here - after the launcher, before the
    # database. No-op wherever Podman is already there, and on the platforms
    # whose launcher brings its own. A no, or a machine it cannot install on,
    # ends this STEP and not the run: the caller records it and the install
    # carries on to what does not need a database.
    personal_install_podman || return 1
    # AND THAT IT ACTUALLY RUNS. A podman that is present but cannot start a
    # container fails inside the launcher, minutes later, naming neither.
    personal_podman_running || return 1
    # A reachable Exasol is already up (this run, a previous run, or the user
    # started it by hand). `exasol info` is the launcher's own health signal.
    # Checked BEFORE the port test below so a healthy database that legitimately
    # owns port 8563 is offered for reuse rather than reported as a conflict.
    # Ask before adopting it — a piped/non-interactive install defaults to yes
    # (reuse), which is the safe, idempotent choice for automation. Set
    # EXAKIT_REUSE_DB=0 to force a fresh deployment, =1 to reuse without asking.
    if personal_deployment_running; then
        info "An Exasol database is already running on port $(personal_db_port)."
        if confirm_env EXAKIT_REUSE_DB "Use it instead of deploying a new one?" y; then
            ok "Reusing the existing Exasol deployment"
            # personal_deployment_running just answered a real SELECT.
            personal_record_manifest "healthy"
            return 0
        fi
        # NOT THE END OF THE RUN. The user declined a database, not the kit:
        # nothing has been written, nothing is half made, and every step that
        # does not need a database still has value. Same shape as a declined
        # Podman install.
        info "Stop it first ('exakit stop', or 'exasol stop'), then re-run the installer to deploy a fresh one - port $(personal_db_port) stays in use while it is running: $(exakit_install_command)"
        exakit_note_failure "Declined to reuse the database already running on port $(personal_db_port)"
        return 1
    fi

    # A deployment exists but is not running — cleanly stopped, or a crashed
    # VM. The launcher refuses `install local` over a stopped deployment
    # ("run `start` to restart or `destroy` to delete resources"), so
    # deploying here would dead-end. Adopt it the way a running one is
    # adopted: start it and reuse. A piped/non-interactive install defaults
    # to yes (reuse). Declining reuse is exactly as harmless as it is for a
    # running database — nothing is deleted without its own explicit consent,
    # so EXAKIT_REUSE_DB=0 can never destroy in this state what it safely
    # refuses in the other. Deletion has a dedicated question and a dedicated
    # variable (EXAKIT_REPLACE_DB=1), and its prompt names the consequence
    # before the answer. The one exception is a deployment that will not
    # start at all (a crashed VM): that is replaced — announced, never
    # silently — because there is nothing left to reuse.
    if personal_deployment_exists; then
        # A FIRST BOOT THE LAUNCHER GAVE UP ON is not a stopped deployment. In
        # "deployment_failed" its start and stop do nothing, so the
        # start-and-reuse path below would report success over a record that
        # stays failed - and every later exakit start would wait on nothing.
        # The launcher's own retry is its deploy; when that gives up on a
        # first boot again, the kit's budget and reconcile take over. Only a
        # database that never answers reaches the ladder below.
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "deployment_failed" ]; then
            info "The launcher records this deployment as failed - retrying its deploy."
            EXAKIT_ACTIVE_LABEL="Retrying the deployment"
            if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy) || \
               personal_recover_slow_first_boot; then
                ok "Reusing the existing Exasol deployment (deployed again)"
                personal_wait_ready_or_deploy || return 1
                personal_record_manifest "healthy"
                return 0
            fi
            warn "The failed deployment could not be brought up.$(personal_foreign_db_hint)"
        fi
        info "An Exasol deployment was found, not running."
        if confirm_env EXAKIT_REUSE_DB "Start the existing database and keep its data?" y; then
            personal_note_guest_rebuild
            if personal_launcher_supports start && \
               run_logged "$(personal_cli)" start $(personal_auto_approve_flag start); then
                ok "Reusing the existing Exasol deployment (started)"
                # NOT "started, therefore running". This is the line the
                # screenshot ended on: the launcher accepted a start for a
                # deployment it had only initialized, did nothing, and the kit
                # then waited 151 seconds for it. The repair is the launcher's
                # own deploy, and it takes twenty seconds.
                personal_wait_ready_or_deploy || return 1
                personal_record_manifest "healthy"
                return 0
            fi
            # `start` failing ONCE is not evidence the deployment is gone: the
            # commonest cause is the module's own documented orphan runner
            # daemon still holding port 8563 after a failed deploy or destroy.
            # Reap it and try once more — the reaper used to run only AFTER
            # this branch had already destroyed the data it would have saved.
            if personal_reap_orphan_daemon 2>/dev/null && \
               run_logged "$(personal_cli)" start $(personal_auto_approve_flag start); then
                ok "Reusing the existing Exasol deployment (started after clearing an orphaned runner)"
                personal_wait_ready_or_deploy || return 1
                personal_record_manifest "healthy"
                return 0
            fi
            warn "The existing deployment could not be started, even after clearing orphaned runners."
        fi
        # NO PATH DESTROYS WITHOUT THIS CONSENT — not even a failed start. A
        # deployment that will not start today may hold months of data and be
        # one diagnosis away from starting tomorrow; deleting it is the user's
        # call, made with the consequence in front of them. Interactive runs
        # are asked (default no); automation says EXAKIT_REPLACE_DB=1, and
        # exakit repair-runtime remains the sanctioned destructive repair.
        if ! confirm_env EXAKIT_REPLACE_DB "DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone." n; then
            info "Nothing was deleted. Start it yourself with 'exakit start', diagnose with 'exakit status', repair with 'exakit repair-runtime' - or re-run with EXAKIT_REPLACE_DB=1 to replace it, deleting its data."
            exakit_note_failure "A stopped deployment could not be started, and deleting it was declined"
            return 1
        fi
        info "Replacing the existing deployment — its previous data is not recoverable."
        # --auto-approve: destroy has its own [y/N] prompt, which a piped or
        # scripted install cannot answer; the consent came from the explicit
        # replace question (or EXAKIT_REPLACE_DB=1) just above.
        run_logged "$(personal_cli)" destroy --remove --auto-approve || \
            warn "Could not fully remove the old deployment; the launcher will deploy over it."
    fi

    # Port busy but the launcher sees no reachable deployment on it. This is
    # usually our own orphaned runner daemon from a failed deploy or destroy —
    # reap it and continue. Only a genuinely foreign process (another database,
    # a stale container), which the reaper leaves untouched, is a hard stop.
    # EXAKIT_DB_PORT does not apply to the personal path, so name the real port.
    if port_in_use "$(personal_db_port)"; then
        if ! personal_reap_orphan_daemon; then
            warn "Port $(personal_db_port) is in use by a process that is not a reachable Exasol Personal deployment.$(personal_foreign_db_hint)"
            info "Stop that application, then re-run the installer (EXAKIT_DB_PORT does not choose the port of a personal deployment): $(exakit_install_command)"
            exakit_note_failure "Port $(personal_db_port) is held by something that is not an Exasol Personal deployment"
            return 1
        fi
    fi

    # Two points, not three. Deploying and then checking health are one fact to
    # the reader -- the database is up and answering -- so they close on a single
    # line, and the launcher's EULA notice follows as the step's own second
    # point instead of being wedged between them.
    #
    # THE NOTICE FOLLOWS THE DEPLOYMENT, NOT THE HEALTH CHECK. It used to be
    # safe to leave it until last for a reason that has since stopped being
    # true: a database that never answered ended the run, the rollback below
    # destroyed the deployment, and no deployment survived to have accepted
    # anything. That failure is now recorded rather than fatal, and the
    # deployment stays - so the licence terms are replayed on that path too,
    # below, before this function hands its refusal back.
    #
    # Same bracket and the same terminal gate as personal_install_launcher: the
    # progress bar narrates the deploy and the spinner narrates the health
    # probe, so the info/ok pairs underneath are the second telling.
    _pdl_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1

    # BEFORE the deploy, not only after it. The launcher's own EULA notice is
    # captured out of its output and replayed once the deploy succeeds, which
    # means the terms could only ever be read after the deployment existed. The
    # replay stays where it is -- it is Exasol's wording, verbatim, and there is
    # nothing to capture until the launcher has run -- so this line goes ahead
    # of it, saying which licence covers what while the reader can still stop.
    info "Exasol Personal is free to use and ships under Exasol's own licence terms, not the kit's MIT licence. The launcher shows them below."
    info "Deploying Exasol Personal locally — about 2 minutes"
    push_rollback "$(personal_cli) destroy --remove --auto-approve || true"

    # The launcher's output is consumed, not shown -- see the progress helpers
    # above. Three files carry what the pipeline learns back out of it: the live
    # phase, the tail to print if it fails, and the EULA notice to replay if it
    # succeeds.
    _deploy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-deploy.XXXXXX")" || \
        die "Could not create a temporary directory for the database install."
    _deploy_state="$_deploy_tmp/state"
    _deploy_tail="$_deploy_tmp/tail"
    _deploy_notice="$_deploy_tmp/notice"
    _deploy_t0="$(date +%s 2>/dev/null || echo 0)"
    ui_progress_state "$_deploy_state" 0 5 3 "Preparing to deploy"
    : > "$_deploy_tail"
    : > "$_deploy_notice"

    EXAKIT_DEPLOY_LIVE=0
    ui_progress_begin "$_deploy_state" "$_deploy_t0" && EXAKIT_DEPLOY_LIVE=1
    # --auto-approve: 2.3 fails a non-interactive host preparation rather than
    # proceeding without approval, and this pipeline is the definition of one.
    # Omitted on launchers that do not take it — see personal_auto_approve_flag.
    "$(personal_cli)" install local $(personal_auto_approve_flag install) 2>&1 | \
        _personal_deploy_collect "$_deploy_state" "$_deploy_tail" "$_deploy_notice"
    _deploy_rc=${PIPESTATUS[0]}
    ui_progress_end
    EXAKIT_DEPLOY_LIVE=0

    if [ "$_deploy_rc" -ne 0 ]; then
        # Restored before anything explains the failure: the tail below prints
        # through foreign_note, and a step that says nothing while it works must
        # still say everything when it goes wrong.
        EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
        # A DEPLOYMENT THAT EXISTS IS GIVEN THE KIT'S OWN BUDGET FIRST. The
        # launcher waits 27 seconds for a first boot and calls the deployment
        # failed when the database has not answered by then - with the
        # container up and the database ready a moment later (four times in
        # one day, on WSL and on Windows, where a first boot in a fresh Podman
        # machine takes 40 to 60 seconds). See personal_recover_slow_first_boot.
        if personal_deployment_exists && personal_recover_slow_first_boot; then
            rm -rf "$_deploy_tmp"
        else
            _personal_deploy_print_tail "$_deploy_tail"
            rm -rf "$_deploy_tmp"
            # DISARMED, NOT FIRED. The destroy pushed above is the right undo
            # for a run that is ending; this run is not ending, and a partial
            # deployment is what a retry needs to look at.
            rollback_clear
            warn "Local deployment failed.$(personal_foreign_db_hint)"
            info "Retry it by re-running the installer - completed steps are skipped: $(exakit_install_command)"
            exakit_note_failure "The launcher could not deploy the database locally"
            return 1
        fi
    fi

    if ! personal_wait_ready_or_deploy; then
        EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
        # A deployment that exists has accepted the terms, whether or not its
        # database is answering yet. See the note above the deploy.
        _personal_deploy_print_notice "$_deploy_notice"
        rm -rf "$_deploy_tmp"
        rollback_clear
        info "Retry it by re-running the installer ($(exakit_install_command)), or read the state with 'exakit status'."
        return 1
    fi

    EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
    # One line for both, and the elapsed covers both -- it is the step's time,
    # not the deploy's alone. The endpoint is the literal fallback
    # personal_record_manifest uses when deployment.json cannot be read; the
    # real DSN is not parsed out of it until a few lines later, and this is the
    # same address either way on a personal deployment.
    ok "Exasol Personal deployed and answering on 127.0.0.1:$(personal_db_port) ($(( $(date +%s 2>/dev/null || echo 0) - _deploy_t0 ))s)"
    _personal_deploy_print_notice "$_deploy_notice"
    rm -rf "$_deploy_tmp"

    personal_record_manifest "healthy"
}

_personal_wait_ready_probe() {
    info "Checking deployment health"
    # A WALL-CLOCK ceiling, not a try count. Counting tries made the budget
    # thirty sleeps of five seconds PLUS thirty launcher probes of up to
    # EXAKIT_PERSONAL_PROBE_TIMEOUT each - up to 450 s of waiting behind a
    # message that promised 150. The deadline below is the number the message
    # quotes, and the try cap is derived from it as the fallback for a machine
    # whose `date` cannot answer (elapsed would stay 0 and the loop would never
    # end); it is never the tighter of the two.
    # Animate it: the step that just stopped showing the launcher's chatter
    # must not then end on a still screen.
    # A guest rebuild is not a slow start, it is a different operation with a
    # different duration — and the ordinary budget turned a successful upgrade
    # into a reported crash. An explicitly set EXAKIT_PERSONAL_READY_TIMEOUT
    # still wins: a number the user chose is never overridden by a guess.
    _pwr_budget="${EXAKIT_PERSONAL_READY_TIMEOUT:-150}"
    _pwr_what="Waiting for the database to answer"
    _pwr_raise=EXAKIT_PERSONAL_READY_TIMEOUT
    if [ -z "${EXAKIT_PERSONAL_READY_TIMEOUT:-}" ] && personal_guest_rebuild_expected; then
        personal_note_guest_rebuild
        _pwr_budget="${EXAKIT_PERSONAL_REBUILD_TIMEOUT:-900}"
        _pwr_what="Rebuilding the VM guest and waiting for the database"
        _pwr_raise=EXAKIT_PERSONAL_REBUILD_TIMEOUT
    fi
    ui_spin_begin "$_pwr_what"
    _pwr_t0="$(date +%s 2>/dev/null || echo 0)"
    _pwr_elapsed=0
    _pwr_maxtries=$(( _pwr_budget / 5 + 1 ))
    _tries=0
    # SOMETHING HAS TO BE SAID WITHOUT A TTY. The only narration here is
    # ui_spin_begin, and that returns immediately when stdout is not a
    # terminal - so an agent's run printed NOTHING for up to 150 seconds
    # normally, and up to 900 after a launcher update triggers the guest
    # rebuild. Fifteen minutes of silence is indistinguishable from a hang, and
    # the documented advice is not to loop on `exakit start`, so the agent has
    # nothing to poll and no reason to keep waiting.
    #
    # To STDERR: a caller composing a --json answer on stdout must not find
    # progress lines spliced into it.
    _pwr_last_note=0
    while [ "$_pwr_elapsed" -lt "$_pwr_budget" ] && [ "$_tries" -lt "$_pwr_maxtries" ]; do
        # A HANDSHAKE, NOT AN OPEN PORT. Under rootless Podman the port is
        # pasta's from the moment the container starts, and `exasol info`
        # answers from the deployment directory - together they declared
        # "reachable" a database that was still a minute from accepting a
        # connection, and the next step's SELECT 1 paid for it six times.
        if personal_tls_answers; then
            ui_spin_end
            ok "Deployment is reachable"
            # The database answered under this launcher, so whatever rebuild
            # that first start owed is paid. Recorded so the notice does not
            # announce it again for the same launcher.
            _pwr_lv="$(personal_launcher_version 2>/dev/null || true)"
            [ -n "$_pwr_lv" ] && manifest_set runtime.guest_rebuilt_for "$_pwr_lv" 2>/dev/null
            return 0
        fi
        sleep 5
        _tries=$((_tries + 1))
        _pwr_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _pwr_t0 ))
        [ "$_pwr_elapsed" -ge 0 ] || _pwr_elapsed=0
        if [ ! -t 1 ] && [ $(( _pwr_elapsed - _pwr_last_note )) -ge 30 ]; then
            _pwr_last_note="$_pwr_elapsed"
            printf '  ... %s (%ss elapsed, ceiling %ss; raise it with %s)\n' \
                "$_pwr_what" "$_pwr_elapsed" "$_pwr_budget" "$_pwr_raise" >&2
        fi
    done
    ui_spin_end
    # The number the user actually waited, not the number the loop intended.
    _pwr_spent="$_pwr_elapsed"
    [ "$_pwr_spent" -gt 0 ] || _pwr_spent=$(( _tries * 5 ))
    # Not "run the probe that just failed": name the two commands that actually
    # diagnose and recover a deploy that answers nothing.
    return 1
}

# personal_wait_ready - the probe, and the end of the run when it fails. Every
# caller outside the install still reaches this one; the install's callers use
# personal_wait_ready_or_deploy below, which tries the repair first and hands a
# refusal back instead of ending the run.
personal_wait_ready() {
    _personal_wait_ready_probe && return 0
    die "The deployment did not answer within ${_pwr_spent} seconds (the ceiling is ${_pwr_budget}s; raise it with ${_pwr_raise}). Read the state with 'exakit status', then 'exakit start' to retry - a deployment stuck in 'interrupted' is repaired with 'exakit repair-runtime' (destructive, it asks first)."
}

# personal_wait_ready_or_deploy - A START THAT REPORTED SUCCESS IS NOT A
# DATABASE. The launcher's `start` exits 0 and does nothing at all in more than
# one state: "deployment_failed" is the one the kit already knew about, and
# "initialized but not deployed yet" is the one that cost a whole install -
# start said OK, the kit said "Reusing the existing Exasol deployment
# (started)", and then waited its entire 150-second budget for a database
# nobody had asked to exist. The launcher prints its own advice in that WARN
# and the fix is one command: its deploy.
#
# So this stops reading the state and reads the DATABASE. Whatever the launcher
# called it, a deployment that does not answer after a start it accepted is a
# deployment that was never started, and the launcher's deploy is what brings
# it up - the same command a user runs by hand when they hit this, and it takes
# about twenty seconds. Checking behaviour rather than a state string means the
# next spelling of this state needs no new case arm.
#
# 0 when the database answers, 1 when it never did. Never dies: the caller in
# the install records it and carries on.
personal_wait_ready_or_deploy() {
    _personal_wait_ready_probe && return 0
    warn "The database did not answer after the launcher accepted the start."
    info "In some states the launcher's start does nothing and its deploy is the fix - running that now."
    EXAKIT_ACTIVE_LABEL="Deploying the existing database"
    if ! run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy); then
        EXAKIT_ACTIVE_LABEL=""
        exakit_note_failure "The database never answered, and the launcher's deploy could not bring it up"
        return 1
    fi
    EXAKIT_ACTIVE_LABEL=""
    _personal_wait_ready_probe && { ok "The database answered after the launcher's deploy"; return 0; }
    exakit_note_failure "The database never answered, even after the launcher deployed it again"
    return 1
}

# personal_record_manifest [status] — write the connection details this kit
# hands to every client, plus the runtime state.
#
# The STATUS IS AN ARGUMENT because it used to be the constant "healthy". Every
# caller got it, including `exakit update`, which reaches here after swapping
# the launcher binary with no health probe of any kind in between — so updating
# a STOPPED database recorded it as healthy, and anything reading the manifest
# rather than calling personal_status was then simply wrong. Callers that have
# just watched the database answer pass "healthy"; callers that have not pass
# nothing and the state is probed.
# personal_clear_stale_record — drop the old container's keys from runtime.*.
#
# An install that crossed from the nano kit kept runtime.engine, container,
# image and volume from that record, describing a container that is not this
# deployment's. legacy.* is where the kit keeps the old database: migrate and
# the restore read it from there (legacy_record_value). Copied across first
# when legacy.* has none, so an older record loses nothing. Called when the
# runtime is recorded and on every resumed install. Twin of
# Clear-PersonalStaleRecord (which also records podman: on Windows the
# launcher always runs the database in it).
personal_clear_stale_record() {
    for _pcs_key in container engine volume; do
        _pcs_old="$(manifest_get "runtime.$_pcs_key" 2>/dev/null || true)"
        [ -n "$_pcs_old" ] || continue
        if [ -z "$(manifest_get "legacy.$_pcs_key" 2>/dev/null || true)" ]; then
            manifest_set "legacy.$_pcs_key" "$_pcs_old"
        fi
    done
    for _pcs_key in runtime.engine runtime.container runtime.image runtime.volume; do
        manifest_del "$_pcs_key" 2>/dev/null || true
    done
}

personal_record_manifest() {
    _prm_status="${1:-}"
    manifest_set runtime.type "personal"
    personal_clear_stale_record
    # The version of the deployment ON DISK, whenever its state can say —
    # never the version this kit merely advertises. Reusing or adopting an
    # existing deployment used to record the advertised number over it, after
    # which every version answer, update check and outranks-guard reasoned
    # from a launcher version the deployment never had.
    # runtime.version is the COMPONENT the kit installs and compares against
    # versions.json, and that component is the LAUNCHER: personal_install_launcher
    # downloads it, its checksum is the one verified, and components.personal
    # names its release. So the binary is asked first. The deployment's own
    # version - a different fact, and the one that decides whether a guest
    # rebuild is still ahead - is recorded beside it rather than in its place.
    #
    # Still never the advertised number while anything on disk can answer: that
    # was the original bug here, and recording an aspiration over an adopted
    # deployment is exactly what the order below refuses to do.
    _prm_dep="$(personal_deployed_version 2>/dev/null || true)"
    _prm_ver="$(personal_launcher_version 2>/dev/null || true)"
    manifest_set runtime.version "${_prm_ver:-${_prm_dep:-$EXAKIT_PERSONAL_VERSION}}"
    if [ -n "$_prm_dep" ]; then
        manifest_set runtime.deployment_version "$_prm_dep"
    fi
    manifest_set runtime.launcher "$(personal_cli)"
    manifest_set runtime.deployment_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"

    # The deployment directory has everything a client needs:
    #   deployment.json -> host, dbPort, username, cert-validation flag
    #   secrets.json    -> dbPassword
    _dep="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _sec="$EXAKIT_PERSONAL_DEPLOY_DIR/secrets.json"
    if [ -f "$_dep" ]; then
        require_python3
        _conn="$(run_python -c '
import json, sys
doc = json.load(open(sys.argv[1]))
c = doc.get("connection", {})
print("%s:%s\t%s" % (c.get("host", "127.0.0.1"), c.get("dbPort", 8563), c.get("username", "sys")))
' "$_dep" 2>/dev/null)"
        _dsn="$(printf '%s' "$_conn" | cut -f1)"
        _user="$(printf '%s' "$_conn" | cut -f2)"
        # A corrupt/unreadable deployment.json must not record an empty DSN.
        manifest_set runtime.dsn "${_dsn:-127.0.0.1:${EXAKIT_PERSONAL_PORT}}"
        manifest_set runtime.user "${_user:-sys}"
    else
        manifest_set runtime.dsn "127.0.0.1:${EXAKIT_PERSONAL_PORT}"
        manifest_set runtime.user "sys"
    fi
    _password=""
    if [ -f "$_sec" ]; then
        _password="$(run_python -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dbPassword",""))' "$_sec" 2>/dev/null)"
    fi
    if [ -n "$_password" ]; then
        store_credential personal_sys_password "$_password"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/personal_sys_password"
    else
        warn "Could not read the database password from the Exasol Personal secrets — the exapump profile and AI client configs will ask for it or need manual completion."
    fi
    manifest_set runtime.tls "self-signed"
    # Never assert health without either having just seen it or probing for it.
    [ -n "$_prm_status" ] || _prm_status="$(personal_status 2>/dev/null || true)"
    manifest_set runtime.status "${_prm_status:-unknown}"
}

# --- lifecycle (used by exakit) ---------------------------------------------
# personal_help_names_token <token> — filter reading help text on stdin; true
# when <token> appears in a SUBCOMMAND/FLAG position, i.e. first on its own
# line apart from indentation, rather than anywhere in the prose.
#
# `grep -w` was the old test and it matched the word wherever it fell: a row
# reading "stop   Stop a running local deployment" satisfied `-w local` and
# `-w start` at once, so the capability probes this module is built around
# answered yes for commands the launcher does not have.
#
# No `grep -q` here: it exits at the first match and closes the pipe, the
# launcher takes a SIGPIPE (141) writing the rest of its help, and the
# dispatcher's `set -o pipefail` then fails the whole pipeline — making a
# supported command look unsupported. Plain grep reads the full help.
personal_help_names_token() {
    grep -E "^[[:space:]]*(-[-a-zA-Z0-9]+,[[:space:]]*)?$1([[:space:]]|,|$)" >/dev/null
}

personal_launcher_supports() {
    # Bounded: a launcher wedged on a deployment it cannot open hangs on
    # `--help` like everything else, and this is called from `exakit start`,
    # `exakit stop` and the deploy path.
    exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" --help 2>&1 \
        | personal_help_names_token "$1"
}

# personal_auto_approve_flag <subcommand> — "--auto-approve" when this launcher
# takes it on <subcommand>, nothing when it does not.
#
# WHY THIS IS NOT personal_launcher_supports: that probe reads the TOP-LEVEL
# help, where a subcommand's own flags never appear, so it would answer "no"
# for every launcher including the ones that need this most.
#
# It needs to exist because Exasol Personal 2.3 made a non-interactive run of
# local runtime host preparation FAIL rather than proceed without approval —
# and the kit's install consumes the launcher's output through a pipeline, so
# it is exactly the caller that cannot answer a prompt. The consent is real and
# already given: the user ran the installer, and the deploy path asks its own
# questions (EXAKIT_REUSE_DB, EXAKIT_REPLACE_DB) before it gets here. A launcher
# that does not know the flag is never handed it — an unknown flag is a hard
# failure, and 2.2 deployments are still supported.
#
# Deliberately uncached, like personal_launcher_supports: every call site is a
# command substitution, so a cache set here would be written in a subshell and
# thrown away. One bounded launcher probe per start or deploy is the real cost.
personal_auto_approve_flag() {
    if exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" \
            "$(personal_cli)" "$1" --help 2>&1 \
            | personal_help_names_token "--auto-approve"; then
        printf '%s' "--auto-approve"
    fi
    return 0
}

# personal_guest_rebuild_expected — true when the deployment on disk was created
# by a different launcher than the one now installed.
#
# Exasol Personal 2.3 runs the VM guest that belongs to the launcher's runner,
# so a deployment made by an earlier launcher rebuilds its guest on the next
# start. The data survives; the start does not fit the ordinary budget, and a
# successful upgrade that overran it read to the user as a crash.
personal_guest_rebuild_expected() {
    _pgr_dep="$(personal_deployed_version 2>/dev/null || true)"
    [ -n "$_pgr_dep" ] || return 1
    # The launcher that is actually installed, not the one the kit advertises:
    # before an update those differ, and announcing a rebuild for a launcher
    # this machine does not have yet is a promise about the wrong event.
    _pgr_launcher="$(personal_launcher_version 2>/dev/null || true)"
    [ -n "$_pgr_launcher" ] || _pgr_launcher="${EXAKIT_PERSONAL_VERSION:-}"
    [ -n "$_pgr_launcher" ] || return 1
    [ "$_pgr_dep" != "$_pgr_launcher" ] || return 1
    # ONCE, not forever. A deployment keeps the version that created it, so
    # "deployment older than launcher" stays true after the rebuild has already
    # happened - and the notice would then repeat on every start, promising a
    # wait that is behind the user, not ahead. The completed start records the
    # launcher it completed under; this is how the notice retires itself.
    [ "$(manifest_get runtime.guest_rebuilt_for 2>/dev/null || true)" != "$_pgr_launcher" ]
}

# personal_note_guest_rebuild — say it once, before the start that does it.
# Silence through a five-minute start is the failure mode being fixed here, so
# the notice goes ahead of the command rather than in the timeout message.
personal_note_guest_rebuild() {
    personal_guest_rebuild_expected || return 0
    [ "${_EXAKIT_PERSONAL_REBUILD_SAID:-0}" = 1 ] && return 0
    _EXAKIT_PERSONAL_REBUILD_SAID=1
    info "This deployment was created by an earlier launcher, so the first start rebuilds its VM guest — slower than usual, once. Your data is kept."
}

# personal_deployment_wedged — has the launcher marked this deployment as
# INTERRUPTED? That is a third state, and collapsing it into "stopped" is what
# made a crashed database look like a merely idle one.
#
# Reproduced: SIGKILL the runner, and the launcher records
# currentWorkflowState.interrupted and thereafter refuses to start with "local VM
# state contains invalid database port: 0" — forever, because every start attempt
# rewrites the VM state file without ever putting the database port back. `exakit
# start` cannot fix it, and neither can the launcher's own advice to run stop and
# start. Only a redeploy clears it, which personal_deploy_local already knows how
# to do; it just was never reached (see step_artifact_state).
#
# Read from the launcher's own state file rather than by running `exasol status`:
# this is called from `exakit status`, which agents poll, and a file read is free
# where a launcher subprocess is not.
personal_deployment_wedged() {
    [ -n "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    _pdw_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
    [ -f "$_pdw_state" ] || return 1
    exakit_can_run_python || return 1
    run_python - "$_pdw_state" <<'EXAKIT_WEDGE_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
state = doc.get("currentWorkflowState")
if not isinstance(state, dict) or "interrupted" not in state:
    sys.exit(1)
detail = state.get("interrupted") or {}
if isinstance(detail, dict) and detail.get("error"):
    print(detail["error"])
sys.exit(0)
EXAKIT_WEDGE_PY
}

# personal_repair_command — the one command that actually clears a wedged
# deployment. Named in every place the wedge is reported, because the state is
# unrecoverable by any gentler route and an agent that is told "stopped" will
# loop on `exakit start` instead.
personal_repair_command() {
    printf 'exakit repair-runtime\n'
}

personal_status() {
    if ! command -v exasol >/dev/null 2>&1 && [ ! -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "not installed"
    elif personal_deployment_exists; then
        # `exasol info` answers even when the cluster is stopped — the SQL
        # port tells the truth about whether the database is actually up.
        # A BUSY port is not the same truth: with the database stopped and
        # another program listening on 8563, this said "running", `exakit
        # start` said "already running" and exited 0, and `exakit status` sent
        # the reader back to `exakit start` — a loop with no exit. When the
        # port answers, ask the database itself (a real SELECT through the kit's
        # profile); a port that is busy but does not answer as Exasol is a
        # conflict, its own state with its own remedy.
        if port_in_use "$(personal_db_port)"; then
            # THE LAUNCHER OWNS THE LIFECYCLE, so its word outranks the port.
            # A stopped 2.3 deployment can leave its runner alive and still
            # answering SQL; calling that "running" made `exakit start` reply
            # "already running" and do nothing, so a stopped database could
            # never be restarted. Reported as stopped - which is what its owner
            # says - and the start path clears the leftover runner first.
            _ps_state="$(personal_launcher_state 2>/dev/null || true)"
            if [ "$_ps_state" = "stopped" ]; then
                echo "stopped"
            elif personal_db_answers; then
                echo "running"
            elif personal_starting; then
                # Our own runner, still inside its start budget: coming up.
                echo "starting"
            else
                echo "conflict"
            fi
        elif personal_deployment_wedged >/dev/null 2>&1; then
            # Not "stopped": start will fail, and saying stopped sends the
            # reader (and every agent) to a command that cannot work.
            echo "interrupted"
        else
            echo "stopped"
        fi
    else
        echo "not deployed"
    fi
}

personal_start() {
    if personal_launcher_supports start; then
        # In "deployment_failed" the launcher's start (and stop) do nothing and
        # exit 0, so this reported "Database started" over a database that was
        # never asked to start and then waited its whole budget for it. The
        # launcher's own retry for that state is its deploy.
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "deployment_failed" ]; then
            info "The launcher records this deployment as failed - retrying its deploy instead of a start it would ignore."
            if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy); then
                ok "Database started"
                return 0
            fi
            die "The deployment could not be brought up.$(personal_foreign_db_hint) Check the log above; if it fails the same way, repair with: $(personal_repair_command)"
        fi
        personal_note_guest_rebuild
        # A STOPPED DEPLOYMENT CAN STILL BE HOLDING ITS OWN PORT. The 2.3
        # launcher leaves its runner alive after `stop`, and the next `start`
        # then cannot bind - so the port is cleared BEFORE the attempt rather
        # than diagnosed after it. Scoped by personal_is_orphan_daemon: only
        # this kit's own runner is ever reaped, and a genuinely foreign
        # listener is left alone and reported by the failure path below.
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "stopped" ] && \
           port_in_use "$(personal_db_port)"; then
            info "Clearing a leftover Exasol runner still holding port $(personal_db_port)"
            personal_reap_orphan_daemon >/dev/null 2>&1 || true
        fi
        if ! run_logged "$(personal_cli)" start $(personal_auto_approve_flag start); then
            # Say what to do, not just that it failed. A start that fails on a
            # wedged deployment fails identically every time it is retried, and
            # "Failed to start the deployment" plus a log path sent readers back
            # to `exakit start` in a loop.
            if personal_deployment_wedged >/dev/null 2>&1; then
                die "The database is interrupted and cannot be started — the launcher has to rebuild it. Repair it with: $(personal_repair_command) (this rebuilds the database from empty; its data is not recoverable)."
            fi
            if [ "$(personal_status 2>/dev/null)" = "conflict" ]; then
                die "Port $(personal_db_port) is held by another process$(personal_port_holder_hint), so the database cannot start. Stop that process, then: exakit start"
            fi
            die "Failed to start the database. Check the log above, then retry with 'exakit start'; if it fails the same way, repair with: $(personal_repair_command)"
        fi
        ok "Database started"
    else
        info "This launcher version has no explicit start command."
        info "Check the database with: $(personal_cli) info"
    fi
}

personal_stop() {
    if personal_launcher_supports stop; then
        run_logged "$(personal_cli)" stop || die "Failed to stop the database."
        manifest_set runtime.status "stopped"
        # exapump.sh caches a reachable database for the run; this run just
        # ended that. Guarded: the runtime modules load without exapump.sh.
        command -v exakit_forget_db_reachable >/dev/null 2>&1 && exakit_forget_db_reachable
        ok "Database stopped"
    else
        info "This launcher version has no explicit stop command."
        info "To remove the database entirely use: exakit uninstall"
    fi
}

# personal_teardown [--data] — destroy the local deployment. An Exasol
# Personal deployment keeps runtime and data together, so removing it always
# deletes the database content; without --data we refuse instead of silently
# destroying data the documented contract says would be kept.
personal_teardown() {
    if [ "${1:-}" != "--data" ]; then
        warn "An Exasol Personal deployment keeps the database software and your data together — removing it deletes every table you loaded."
        info "Use 'exakit stop' to stop it without deleting, or 'exakit uninstall' to remove everything."
        return 1
    fi
    if personal_deployment_exists; then
        info "Destroying the local Exasol Personal deployment"
        # --auto-approve: the launcher's 'destroy' prompts for confirmation by
        # default. run_logged sends its output to the log, so that prompt is
        # invisible and the install just hangs forever waiting for input. The
        # user has already confirmed at the exakit uninstall level.
        run_logged "$(personal_cli)" destroy --remove --auto-approve || warn "The launcher reported errors while destroying the deployment. What it said: exakit logs setup"
    else
        info "No active deployment found"
    fi
    # The launcher's destroy can leave an orphaned runner daemon bound to the
    # port when it cannot locate the daemon PID. Reap it unconditionally (even
    # when no deployment was found above, the orphan can outlive the deployment
    # dir) so a future deploy and MCP clients get a clean port.
    personal_reap_orphan_daemon || \
        warn "Could not fully free port $(personal_db_port); if a later deploy fails to bind it, stop the leftover process holding that port and retry."
    manifest_set runtime.status "removed"
}

personal_upgrade_plan() {
    _current="$1"
    _latest="$2"
    warn "Exasol Personal major upgrade detected: ${_current:-unknown} -> $_latest."
    warn "Personal keeps runtime and database content together in the local deployment."
    info "No destructive action was taken."
    info "Deployment: $EXAKIT_PERSONAL_DEPLOY_DIR"
    info "Follow the Exasol Personal $_latest migration/redeployment guidance for your data."
}

personal_upgrade_backup() {
    _current="$1"
    _latest="$2"
    require_cmd tar "tar"
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || \
        die "No Exasol Personal deployment directory found at $EXAKIT_PERSONAL_DEPLOY_DIR; nothing was backed up."
    if [ "$(personal_status 2>/dev/null || true)" = "running" ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Stop Exasol Personal before backing up for a major upgrade: exakit stop"
    fi

    _backup_dir="$EXAKIT_HOME/backups"
    mkdir -p "$_backup_dir"
    chmod 700 "$_backup_dir" 2>/dev/null || true
    _stamp="$(date +%Y%m%d-%H%M%S)"
    _safe_current="$(printf '%s' "${_current:-unknown}" | tr '/ :' '---')"
    _safe_latest="$(printf '%s' "${_latest:-unknown}" | tr '/ :' '---')"
    _backup="$_backup_dir/personal-upgrade-${_safe_current}-to-${_safe_latest}-${_stamp}.tar.gz"
    _parent="$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    _base="$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")"

    info "Creating Exasol Personal deployment backup"
    if ! tar -czf "$_backup" -C "$_parent" "$_base" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_backup"
        die "Could not create the Personal backup; no update was applied."
    fi
    chmod 600 "$_backup" 2>/dev/null || true
    if exakit_can_run_python; then
        manifest_set backups.personal_upgrade.latest "$_backup"
        manifest_set backups.personal_upgrade.created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        manifest_set backups.personal_upgrade.from "${_current:-unknown}"
        manifest_set backups.personal_upgrade.to "$_latest"
    else
        warn "Backup was created, but the manifest could not be updated because no Python runtime is available."
    fi
    ok "Personal deployment backup created: $_backup"
}

personal_update() {
    _mode="default"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --plan) _mode="plan" ;;
            --backup) _mode="backup" ;;
            --apply) _mode="apply" ;;
            *) die "Unknown option '$1' for 'exakit update'." ;;
        esac
        shift
    done

    _latest="$(exakit_component_available personal)"
    [ -n "$_latest" ] || die "Could not resolve the advertised Exasol Personal version."
    _current="$(manifest_get runtime.version 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "Exasol Personal launcher is already current ($_current)"
        return 0
    fi

    _current_major="$(exakit_major_version "$_current")"
    _latest_major="$(exakit_major_version "$_latest")"
    if [ -n "$_current_major" ] && [ -n "$_latest_major" ] && [ "$_current_major" != "$_latest_major" ]; then
        case "$_mode" in
            plan|default)
                personal_upgrade_plan "$_current" "$_latest"
                [ "$_mode" = "plan" ] && return 0
                return 1
                ;;
            backup)
                personal_upgrade_plan "$_current" "$_latest"
                personal_upgrade_backup "$_current" "$_latest"
                return 0
                ;;
            apply)
                _last_backup="$(manifest_get backups.personal_upgrade.latest 2>/dev/null || true)"
                _backup_from="$(manifest_get backups.personal_upgrade.from 2>/dev/null || true)"
                _backup_to="$(manifest_get backups.personal_upgrade.to 2>/dev/null || true)"
                if [ -z "$_last_backup" ] || [ ! -f "$_last_backup" ]; then
                    die "Create a backup first."
                fi
                if [ "$_backup_from" != "${_current:-unknown}" ] || [ "$_backup_to" != "$_latest" ]; then
                    die "The latest recorded Personal backup does not match this upgrade (${_current:-unknown} -> $_latest)."
                fi
                info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
                EXAKIT_PERSONAL_VERSION="$_latest"
                EXAKIT_FORCE_COMPONENT_INSTALL=1
                export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
                rm -f "$EXAKIT_PERSONAL_BIN"
                personal_install_launcher
                manifest_set runtime.launcher "$(personal_cli)"
                manifest_set runtime.launcher_version "$EXAKIT_PERSONAL_VERSION"
                manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
                # THE UPGRADE HAS TO CONVERGE. Leaving runtime.version on the
                # old number meant the next `exakit update` saw the same major
                # gap, matched the same backup record, and swapped the launcher
                # again - forever, with no command anywhere that finishes the
                # upgrade. The launcher on this machine IS $_latest now, so
                # that is what the record says; the part that is genuinely
                # still outstanding is the data migration, and it gets its own
                # key instead of being encoded as a stale version.
                manifest_set runtime.version "$_latest"
                manifest_set runtime.migration_pending "$_latest"
                warn "Launcher updated. Existing database content was not deleted or migrated."
                info "Recorded runtime.version $_latest with runtime.migration_pending $_latest — clear that key once the Exasol Personal $_latest data migration is done."
                ok "Exasol Personal launcher update applied with backup available at $_last_backup"
                return 0
                ;;
        esac
    fi

    # --plan AND --backup STOP HERE. Their handling used to live only inside
    # the major-upgrade branch above, so on every other gap they fell through
    # to the installer below: `exakit update runtime --plan` - a command whose
    # whole promise is that it only describes - deleted the launcher binary and
    # installed another one, with none of the confirmation the ordinary path
    # asks for. A flag that reads as "tell me" must never write.
    case "$_mode" in
        plan)
            info "Exasol Personal launcher ${_current:-unknown} -> $_latest."
            info "The launcher binary is replaced; the deployment and its data are not touched."
            info "The first start after it rebuilds the deployment's VM guest - several minutes, once."
            info "Apply it with: exakit update runtime"
            return 0
            ;;
        backup)
            # The backup flow exists for a data MIGRATION, which a launcher swap
            # is not. Saying "done" here would hand back a backup that was never
            # taken, so it says what this update actually is instead.
            info "Exasol Personal ${_current:-unknown} -> $_latest replaces the launcher binary only - it neither deletes nor migrates database content, so there is nothing to back up first."
            info "Apply it with: exakit update runtime"
            return 0
            ;;
    esac

    info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
    EXAKIT_PERSONAL_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    rm -f "$EXAKIT_PERSONAL_BIN"
    personal_install_launcher
    personal_record_manifest
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    ok "Exasol Personal launcher updated; deployment data was not changed"
}
