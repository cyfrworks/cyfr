# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostSurfaceTest do
  @moduledoc """
  Opus names nothing of the control plane. Every module its code names is
  its own (`Opus.*`), a shared contract (`Cyfr.*` defined under
  `apps/cyfr_contracts/lib`), or Elixir, OTP, Req, Plug, Bandit or Wasmex.
  CYFR is reached over the wire alone: its host API through
  `Opus.HostClient`, and it reaches the worker service through
  `Opus.WorkerListener`. A reach into anything else fails here, and the
  answer is a host call or a client, never a dependency.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # The namespaces Opus may name, beside its own and the contracts.
  @allowed_roots ~w(
    Elixir Kernel Access Agent Application Base Bitwise Calendar Code Date DateTime DynamicSupervisor
    Enum Exception File Float Function GenServer IO Integer Inspect Jason Keyword List Logger Macro
    Map MapSet Module NaiveDateTime Path Port Process Range Regex Registry String StringIO
    Supervisor System Task Time Tuple URI Version
    Req Plug Bandit ThousandIsland Wasmex
    ArgumentError RuntimeError MatchError KeyError File.Error Jason.DecodeError
  )

  @namespace ~r/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\b/

  # Every `defmodule` in the contracts, a nested one named under the module
  # enclosing it (`Outer.Inner`): each level indents two spaces.
  defp contracts do
    for path <- Path.wildcard(Path.join(@root, "apps/cyfr_contracts/lib/**/*.ex")),
        module <- defined_modules(File.read!(path)),
        into: MapSet.new(),
        do: module
  end

  defp defined_modules(source) do
    source
    |> code_lines()
    |> Enum.flat_map(&Regex.scan(~r/^((?:  )*)defmodule ([A-Z][\w.]*) do/, &1))
    |> Enum.map_reduce([], fn [_, indent, name], enclosing ->
      path = Enum.take(enclosing, div(byte_size(indent), 2)) ++ [name]
      {Enum.join(path, "."), path}
    end)
    |> elem(0)
  end

  # Code lines: heredocs, comments and one-line doc attributes dropped.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {kept, in_heredoc?} ->
      toggles = length(Regex.scan(~r/"""/, line))
      now_inside? = if rem(toggles, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      keep? =
        not in_heredoc? and not now_inside? and
          not String.match?(line, ~r/^\s*#/) and
          not String.match?(line, ~r/^\s*@(module|type)?doc\s+"/)

      {if(keep?, do: [line | kept], else: kept), now_inside?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp opus_code do
    paths = Path.wildcard(Path.join(@root, "apps/opus/lib/**/*.ex"))
    assert paths != [], "no Opus source found under #{@root}"

    for path <- paths,
        line <- path |> File.read!() |> code_lines(),
        do: {Path.relative_to(path, @root), line}
  end

  defp allowed?(module, contracts) do
    root = module |> String.split(".") |> hd()

    String.starts_with?(module, "Opus.") or module == "Opus" or
      MapSet.member?(contracts, module) or root in @allowed_roots or
      (String.starts_with?(module, "Cyfr.") and contract_type?(module, contracts))
  end

  # `Cyfr.Authority.Blob.Edge` is named for its struct and type: a module
  # of the contracts, or a type spelled under one (`Cyfr.HostAPI.renewal`).
  defp contract_type?(module, contracts) do
    module
    |> String.split(".")
    |> Enum.drop(-1)
    |> Enum.join(".")
    |> then(&MapSet.member?(contracts, &1))
  end

  test "opus names only its own modules, the contracts, Elixir, OTP, Req, Plug, Bandit and Wasmex" do
    contracts = contracts()

    # A bare name is an alias, whose `alias` line names the module in full
    # and is checked itself.
    reaches =
      for {path, line} <- opus_code(),
          [_, module] <- Regex.scan(@namespace, line),
          String.contains?(module, "."),
          not allowed?(module, contracts),
          uniq: true,
          do: "#{path}: #{module}"

    assert reaches == [],
           """
           opus names modules outside its surface:

           #{Enum.join(reaches, "\n")}

           A run's authority, its children, its catalog tools, its rows and
           its keys are CYFR's: opus asks for them over the wire.
           """
  end

  test "the control-plane namespaces are not named at all" do
    named =
      for {path, line} <- opus_code(),
          line =~ ~r/\b(Arca|Sanctum|Aqua|Compendium|Emissary|Prism|Locus|Cyfr\.Execution|Cyfr\.Ops\.Error|Cyfr\.Network)\b/,
          do: "#{path}: #{String.trim(line)}"

    assert named == []
  end

  test "opus depends on the contracts alone" do
    mix = File.read!(Path.join(@root, "apps/opus/mix.exs"))
    assert mix =~ "{:cyfr_contracts, in_umbrella: true}"
    refute mix =~ "{:cyfr, in_umbrella: true"
    refute mix =~ "Arca.Repo"
  end
end
