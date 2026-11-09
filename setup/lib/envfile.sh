# envfile.sh — the settings file: ~/.exasol-starter-kit/exakit.env (setup/exakit.env is
# its commented template). POSIX sh, so install.sh carries the same function; twin:
# Import-ExakitEnvFile in envfile.ps1. tests/env-file.sh keeps the copies the same.

# exakit_load_env_file — export each NAME=value of the settings file
# (${EXAKIT_ENV_FILE:-<EXAKIT_HOME>/exakit.env}) that the environment does not
# already have: a command line still wins over the file. Nothing in it is run.
# Only EXAKIT_* names and EXASOL_TELEMETRY_DISABLE are taken; a secret's name
# (PASSWORD, API_KEY, TOKEN, SECRET) and EXAKIT_HOME / EXAKIT_ENV_FILE (they say
# where the file is) are refused, and named in EXAKIT_ENV_FILE_REFUSED. A value
# may be quoted; unquoted, " #" starts a comment.
exakit_load_env_file() {
    _elf_file="${EXAKIT_ENV_FILE:-${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/exakit.env}"
    EXAKIT_ENV_FILE_REFUSED=""
    [ -f "$_elf_file" ] && [ -r "$_elf_file" ] || return 0
    _elf_cr="$(printf '\r')"                       # a file saved on Windows ends its lines in CRLF
    while IFS= read -r _elf_line || [ -n "$_elf_line" ]; do
        _elf_line="${_elf_line%"$_elf_cr"}"
        _elf_line="${_elf_line#"${_elf_line%%[! 	]*}"}"
        case "$_elf_line" in ''|'#'*) continue ;; esac
        case "$_elf_line" in 'export '*) _elf_line="${_elf_line#export }" ;; esac
        case "$_elf_line" in *=*) ;; *) continue ;; esac
        _elf_name="${_elf_line%%=*}"
        _elf_name="${_elf_name%"${_elf_name##*[! 	]}"}"
        _elf_value="${_elf_line#*=}"
        _elf_value="${_elf_value#"${_elf_value%%[! 	]*}"}"
        case "$_elf_name" in ''|*[!A-Z0-9_]*) continue ;; esac
        case "$_elf_name" in EXAKIT_*|EXASOL_TELEMETRY_DISABLE) ;; *) continue ;; esac
        case "$_elf_name" in
            EXAKIT_HOME|EXAKIT_ENV_FILE|*PASSWORD*|*API_KEY*|*TOKEN*|*SECRET*)
                EXAKIT_ENV_FILE_REFUSED="${EXAKIT_ENV_FILE_REFUSED:+$EXAKIT_ENV_FILE_REFUSED }$_elf_name"
                continue ;;
        esac
        case "$_elf_value" in
            \"*\"*) _elf_value="${_elf_value#\"}"; _elf_value="${_elf_value%%\"*}" ;;
            \'*\'*) _elf_value="${_elf_value#\'}"; _elf_value="${_elf_value%%\'*}" ;;
            *)
                case "$_elf_value" in *' #'*|*'	#'*) _elf_value="${_elf_value%%[ 	]#*}" ;; esac
                _elf_value="${_elf_value%"${_elf_value##*[! 	]}"}" ;;
        esac
        # The name is checked above (A-Z, 0-9, _), so eval only ever sees a plain name;
        # the value is never in the evaluated text.
        eval "_elf_set=\${$_elf_name+set}"
        [ "$_elf_set" = set ] && continue
        eval "$_elf_name=\$_elf_value; export $_elf_name"
    done < "$_elf_file"
    return 0
}

# exakit_env_file_install <kit_root> — the template (setup/exakit.env) becomes the
# settings file on the first install: every setting there, commented, with its
# default. An existing file is never touched - it is the user's.
exakit_env_file_install() {
    _efi_target="${EXAKIT_ENV_FILE:-${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/exakit.env}"
    [ -f "$_efi_target" ] && return 0
    [ -f "$1/setup/exakit.env" ] || return 0
    mkdir -p "$(dirname "$_efi_target")" 2>/dev/null || return 0
    cp "$1/setup/exakit.env" "$_efi_target" 2>/dev/null && chmod 600 "$_efi_target" 2>/dev/null
    return 0
}

# exakit_env_file_note — one line naming the settings the file may not hold.
exakit_env_file_note() {
    [ -n "${EXAKIT_ENV_FILE_REFUSED:-}" ] || return 0
    printf '      %s!%s %s ignores %s: a secret, or where the file itself lives, stays in the environment\n' \
        "${UI_WARN:-}" "${UI_RESET:-}" "${EXAKIT_ENV_FILE:-~/.exasol-starter-kit/exakit.env}" "$EXAKIT_ENV_FILE_REFUSED" >&2
}
