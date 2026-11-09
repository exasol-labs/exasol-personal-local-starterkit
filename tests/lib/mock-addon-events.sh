# Fake worker events for terminal-rendering tests; no packages or services run.
_exakit_marketplace_run_python() {
    if [ "$1" = query ]; then shift; python3 "$@"; return $?; fi
    local id install summary failed=0 detail
    for id in $(printf '%s' "$3" | tr ',' ' '); do
        printf '@@EXAKIT|%s|installing||0\n' "$id"
        install="$(_exakit_addon_fn "$id" install)"
        if "$install"; then
            summary="$(_exakit_addon_fn "$id" summary)"
            detail=""
            if command -v "$summary" >/dev/null 2>&1; then detail="$("$summary")"; fi
            printf '@@EXAKIT|%s|done|%s|1\n' "$id" "$detail"
        else
            printf '@@EXAKIT|%s|failed|fixture install failure|1\n' "$id"
            failed=1
        fi
    done
    return "$failed"
}
