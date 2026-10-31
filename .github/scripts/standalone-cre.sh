#!/bin/sh
# Makes koreader-base build libkoreader-cre.so as a library of its own, with
# crengine, the libraries it uses and the C++ runtime linked in and hidden:
# only luaopen_cre is exported, and it needs only the system libraries and
# libluajit.so. For targets where KOReader links everything into one
# libkoreader-monolibtic.so (Android), which leaves no separate libraries to
# link against.
#
# Run in a koreader-base checkout, before building the koreader-cre target.
# Running it again changes nothing.
set -eu

f=thirdparty/cmake_modules/koreader_targets.cmake
marker="Knuth-Plass plugin: standalone koreader-cre"
grep -qF "$marker" "$f" && exit 0

changed() {
    echo "standalone-cre.sh: $f has changed ($1)" >&2
    exit 1
}
grep -q '^include(koreader_thirdparty_libs)$' "$f" || changed "includes"
grep -q '^    koreader-cre TYPE monolibtic$' "$f" || changed "koreader-cre type"

# Run as the target is set up (with the compiler known): the link options,
# and the compiler's runtime library (emulated TLS, …) linked ahead of
# libluajit.so, which exports some of it too (the engine shouldn't depend
# on that).
block=$(mktemp)
cat > "$block" <<'EOF'

# Knuth-Plass plugin: standalone koreader-cre (see the plugin's
# .github/scripts/standalone-cre.sh).
function(setup_koreader_cre)
    # (Asked for up front, so it's taken from the runtime library.)
    target_link_options(koreader-cre PRIVATE -Wl,--exclude-libs,ALL -static-libstdc++
        -Wl,--undefined=__emutls_get_address)
    execute_process(
        COMMAND ${CMAKE_C_COMPILER} -print-libgcc-file-name
        OUTPUT_VARIABLE RT OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
    )
    get_target_property(LIBS koreader-cre LINK_LIBRARIES)
    list(FIND LIBS luajit::luajit AT)
    if(AT LESS 0)
        message(FATAL_ERROR "koreader-cre doesn't link luajit::luajit")
    endif()
    list(INSERT LIBS ${AT} ${RT})
    set_property(TARGET koreader-cre PROPERTY LINK_LIBRARIES ${LIBS})
endfunction()
EOF

# A library rather than part of the monolibtic one.
sed -i \
    -e "/^include(koreader_thirdparty_libs)\$/r $block" \
    -e 's/^    koreader-cre TYPE monolibtic$/    koreader-cre TYPE library/' \
    "$f"
rm -f "$block"
