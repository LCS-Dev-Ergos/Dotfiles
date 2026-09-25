{ pkgs, ... }:
let
  # One OTP release for every BEAM language, so Elixir, Gleam and rebar3 all
  # run on the same VM and nothing pulls in a second Erlang.
  beam = pkgs.beam29Packages;
in
{
  # Erlang, Elixir and Gleam, on both hosts. Gleam compiles to Erlang and
  # calls `erl`/`escript` from PATH, which this same OTP provides; its
  # language server is built in (`gleam lsp`).
  home.packages = [
    beam.erlang
    beam.elixir_1_20
    beam.rebar3
    pkgs.gleam
  ];
}
