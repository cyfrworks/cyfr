# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OneFenceTest do
  @moduledoc """
  A holder-only write has one fence, `Arca.Repo.owned/2` and `owned/3`, and
  a transaction's `{:ok, value}` or rollback one reading,
  `Arca.Repo.committed/1`: no Arca module defines its own copy of either.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  # A private slot fence: the member's slot read, then checked first in a
  # locking transaction; and a private reading of `{:ok, value}` as the
  # value and `{:error, reason}` as the rollback.
  @copies [
    ~r/member_slot\(\)(?: do)?\n\s*(?:Arca\.Repo\.)?locking_transaction\(fn ->\n\s*case (?:Arca\.)?ControlPlane\.verify_held\(slot\) do/,
    ~r/^\s*defp \w+\(\{:ok, \w+\}\), do: \w+\n\s*defp \w+\(\{:error, \w+\}\), do: Arca\.Repo\.rollback\(\w+\)/m
  ]

  test "no Arca module defines its own fence or its own committed/1" do
    sources = for path <- Path.wildcard(Path.join(@lib, "**/*.ex")), do: {path, File.read!(path)}

    # The scan reads the tree, and its patterns match what they look for.
    assert length(sources) > 50
    {_, repo} = Enum.find(sources, fn {path, _} -> String.ends_with?(path, "/arca/repo.ex") end)

    assert repo =~
             ~r/^\s*def committed\(\{:ok, value\}\), do: value\n\s*def committed\(\{:error, reason\}\), do: rollback\(reason\)/m

    assert """
               with {:ok, slot} <- Arca.ControlPlane.member_slot() do
                 Arca.Repo.locking_transaction(fn ->
                   case Arca.ControlPlane.verify_held(slot) do
           """ =~ Enum.at(@copies, 0)

    assert "  defp committed({:ok, value}), do: value\n  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)\n" =~
             Enum.at(@copies, 1)

    copies =
      for {path, source} <- sources,
          relative = Path.relative_to(path, @lib),
          pattern <- @copies,
          source =~ pattern,
          uniq: true,
          do: relative

    assert copies == [], "these modules define their own fence or committed/1: #{inspect(copies)}"
  end
end
