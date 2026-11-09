#!/bin/sh
# Runs plugin tests with LuaJIT and LuaSocket.
# First-time setup:
#   brew install luajit luarocks
#   luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" install --tree .rocks luasocket
#   luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" install --tree .rocks luajson
set -u
cd "$(dirname "$0")/.."
ROCKS="${KDASH_ROCKS:-.rocks}"
export LUA_PATH="$ROCKS/share/lua/5.1/?.lua;$ROCKS/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$ROCKS/lib/lua/5.1/?.so;;"
KDASH_TEST_DIR="$(mktemp -d)"
export KDASH_TEST_DIR
trap 'rm -rf "$KDASH_TEST_DIR"' EXIT
status=0
for spec in plugin/__tests__/*_spec.lua; do
    luajit "$spec" || status=1
done
exit "$status"
