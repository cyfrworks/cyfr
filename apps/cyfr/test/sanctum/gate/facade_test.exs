# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.FacadeTest do
  @moduledoc """
  The gate's door for callers outside it is exactly its admission
  entries, an exact roster: a function added to the gate without a roster
  change fails here, and so does an entry the host's admission roster
  names for the gate that the gate no longer defines. Everything else a
  caller outside Sanctum reads of the gate it calls on the module that
  owns it, under one name; the annotation reads those callers share answer
  in either spelling, and the tool classification is the one rule every
  classifier reads.
  """

  use ExUnit.Case, async: true

  @roster [
    call_external: 3,
    call_external: 4,
    call_in_chain: 4,
    call_in_chain: 5,
    open_stream: 2,
    open_stream: 3
  ]

  # One action map, in the provider's atom-keyed spelling and the wire's
  # string-keyed one.
  @actions %{
    "read" => %{kind: :read, recovery: :replay_safe, standing: :thread},
    "write" => %{kind: :write, recovery: :replay_safe, standing: false}
  }

  test "the root answers exactly its roster" do
    assert exported() == @roster
  end

  test "the root defines exactly the entries the admission roster names for it" do
    sites =
      for %{module: Sanctum.Gate, site: site} <- Cyfr.Boundaries.admission_entries(),
          do: site

    assert exported() |> Keyword.keys() |> Enum.uniq() |> Enum.sort() == Enum.sort(sites)
  end

  test "annotations read on Sanctum.Annotations in either spelling" do
    for source <- [%{annotations: %{actions: @actions}}, %{"annotations" => %{actions: @actions}}] do
      assert Sanctum.Annotations.actions_of(source) == @actions
      assert Sanctum.Annotations.kind(source, "read") == :read
      assert Sanctum.Annotations.kind(source, "nope") == nil
      assert Sanctum.Annotations.standing(source, "read") == :thread
      assert Sanctum.Annotations.standing(source, "write") == false
      assert Sanctum.Annotations.recovery(source, "read") == :replay_safe
      # A write annotated replay-safe is not.
      assert Sanctum.Annotations.recovery(source, "write") == nil
    end

    assert Sanctum.Annotations.actions_of(%{}) == %{}
  end

  describe "the tool classification" do
    test "a virtual hand answers from Sanctum.VirtualTools" do
      assert Sanctum.Catalog.tool_kind("files", "read") ==
               Sanctum.VirtualTools.kind_for("files", "read")

      assert Sanctum.Catalog.tool_kind("files", "read") == :read
      assert Sanctum.Catalog.tool_kind("files", "delete") == :destructive
      assert Sanctum.Catalog.tool_actions("files") == Sanctum.VirtualTools.actions_of("files")
      assert Sanctum.Catalog.tool_actions("files") != []
    end

    test "an upstream server:tool is external whatever the action, with no verbs" do
      assert Sanctum.Catalog.tool_kind("server:tool", "anything") == :external
      assert Sanctum.Catalog.tool_kind("server:tool", "") == :external
      assert Sanctum.Catalog.tool_actions("server:tool") == []
    end

    test "a catalogued tool answers from its annotation and its action enum" do
      {:ok, tool_def} = Sanctum.Catalog.get_tool("system")

      assert Sanctum.Catalog.tool_kind("system", "status") == :read
      assert Sanctum.Catalog.tool_kind("system", "notify") == :write

      assert Sanctum.Catalog.tool_kind("system", "status") ==
               Sanctum.Annotations.kind(tool_def, "status")

      # An action the tool does not declare has no kind, and no default.
      assert Sanctum.Catalog.tool_kind("system", "reboot") == nil

      assert Sanctum.Catalog.tool_actions("system") ==
               get_in(tool_def, ["inputSchema", "properties", "action", "enum"])

      assert "status" in Sanctum.Catalog.tool_actions("system")
    end

    test "an unknown tool has no kind and no verbs" do
      assert Sanctum.Catalog.tool_kind("no_such_tool", "read") == nil
      assert Sanctum.Catalog.tool_actions("no_such_tool") == []
      assert Sanctum.Catalog.tool_kind(nil, "read") == nil
      assert Sanctum.Catalog.tool_actions(nil) == []
    end
  end

  defp exported do
    Sanctum.Gate.__info__(:functions)
    |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
    |> Enum.sort()
  end
end
