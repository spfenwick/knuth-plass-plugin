#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua_bin=${LUA:-}
if [ -z "$lua_bin" ]; then
    lua_bin=$(command -v luajit || command -v lua || true)
fi
if [ -z "$lua_bin" ]; then
    echo "Lua 5.1 or LuaJIT is required (or set LUA=/path/to/interpreter)." >&2
    exit 1
fi

cd "$repo_dir"
"$lua_bin" tests/check_lua_syntax.lua \
    knuthplass.koplugin/_meta.lua \
    knuthplass.koplugin/main.lua
"$lua_bin" tests/test_plugin.lua
