# utf8-locale.sh — a UTF-8 locale for the suites that measure drawn width.
#
#   . "$ROOT/tests/lib/utf8-locale.sh"
#
# WHY THIS EXISTS. `_ui_visible_len` measures a rendered line with `${#var}`,
# which counts CHARACTERS under a UTF-8 locale and BYTES otherwise. Every box
# glyph the kit draws with is three bytes, so in a shell with no locale set —
# an ssh session, cron, a minimal container, and the default on this
# developer's machine — a bordered row measured about three times its real
# width. "every row is one width" then failed, and the suite reported failures
# that said nothing whatever about the code.
#
# THE PRODUCT IS NOT AFFECTED, and that is the point worth keeping straight:
# `ui_detect` sets UI_FANCY=0 when the locale is not UTF-8, so a real user in
# that shell gets the ASCII fallback and never reaches the wide glyphs. It is
# the SUITES that step around the guard — they set UI_FANCY=1 and the glyph
# variables by hand, to test the fancy renderer on a machine that would not
# otherwise use it — so they are the ones that owe themselves a locale in which
# those glyphs can be measured.
#
# FORCED, NOT DEFAULTED. `${LANG:-...}` would leave an inherited LC_ALL=C in
# place and put the failure straight back; LC_ALL outranks LANG, so both are
# set.
#
# The locale is CHOSEN from what the machine actually has rather than
# hardcoded: C.UTF-8 is the portable one on glibc and is missing from some
# macOS builds, en_US.UTF-8 is the other way round. When the machine has
# neither, EXAKIT_TEST_UTF8_LOCALE is left empty and the caller is expected to
# SKIP its width checks — a machine that cannot render the glyphs cannot answer
# the question, and reporting that as a failure would be a lie.
EXAKIT_TEST_UTF8_LOCALE=""
for _eutf_loc in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qxF "$_eutf_loc"; then
        EXAKIT_TEST_UTF8_LOCALE="$_eutf_loc"
        break
    fi
done
if [ -n "$EXAKIT_TEST_UTF8_LOCALE" ]; then
    LANG="$EXAKIT_TEST_UTF8_LOCALE"
    LC_ALL="$EXAKIT_TEST_UTF8_LOCALE"
    export LANG LC_ALL
fi
unset _eutf_loc
