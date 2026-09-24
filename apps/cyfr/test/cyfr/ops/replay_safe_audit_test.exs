# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ReplaySafeAuditTest do
  @moduledoc """
  `recovery: :replay_safe` is a reviewed property of a read: the boot
  audit refuses it on any other kind, any other value; the reader answers it for a read alone; the set
  a recovered turn may re-dispatch is derived from the declarations, and
  that derived set is the review record.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Ops.{Annotations, Catalog}

  defmodule Carrier do
    @behaviour Cyfr.Ops.Provider

    def service, do: "carrier"

    def tools do
      alias Cyfr.Ops.Operation

      valid =
        for {action, kind} <- [{"peek", :read}, {"poke", :write}, {"odd", :read}] do
          Operation.new("carrier", action, "Replay probe", [], kind: kind, planes: [:in_chain])
        end

      definition = Operation.tool(valid)

      operations =
        Enum.map(valid, fn op ->
          %{op | recovery: if(op.action == "odd", do: :reconcile, else: :replay_safe)}
        end)

      [
        %{
          definition
          | operations: operations,
            annotations: %{actions: Map.new(operations, &{&1.action, Operation.annotations(&1)})}
        }
      ]
    end

    def handle(_tool, _ctx, _args), do: {:ok, %{}}
  end

  test "the audit refuses replay safety on a write and any value but replay_safe" do
    assert {:error, missing} = Catalog.audit_action_kinds([Carrier])

    assert Enum.map(missing, &{&1.action, &1.reason}) |> Enum.sort() ==
             [
               {"odd", :invalid_operation},
               {"poke", :invalid_operation}
             ]
  end

  test "the reader answers replay_safe for a read and nothing else" do
    [tool] = Carrier.tools()
    assert Annotations.recovery(tool, "peek") == :replay_safe
    assert Annotations.recovery(tool, "poke") == nil
    assert Annotations.recovery(tool, "odd") == nil
    assert Annotations.recovery(tool, "nope") == nil
  end

  test "the derived set is the review record" do
    assert Catalog.replay_safe_actions() == [
             "aqua.skill_get",
             "aqua.skill_list",
             "component.inspect",
             "component.list",
             # The four declared resource reads: a resource read is always
             # replay-safe (`Cyfr.Ops.Operation.validate!/1`).
             "component.read_resource",
             "execution.read_resource",
             "notes.list",
             "notes.read",
             "notes.search",
             "resource.read",
             "session.read_resource",
             # A component's own source, read: re-reading it after an unknown
             # outcome tells the model what is there now, and changes nothing.
             "source.grep",
             "source.read",
             "source.tree"
           ]

    assert Catalog.replay_safe_actions([Carrier]) == ["carrier.peek"]
    assert Aqua.Ops.replay_safe?("notes", "read")
    refute Aqua.Ops.replay_safe?("notes", "keep")
    refute Aqua.Ops.replay_safe?("http", "get")
  end
end
