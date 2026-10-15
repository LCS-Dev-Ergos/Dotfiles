{ pkgs, ... }:
let
  lua = pkgs.lua5_5;
in
{
  # Lua and LuaRocks, on both hosts, on one release so rocks build against
  # the interpreter that runs them. Neovim embeds its own LuaJIT and does not
  # use this one.
  home.packages = [
    lua
    lua.pkgs.luarocks
  ];
}
