# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ReplaySafeAuditTest do
  @moduledoc """
  `recovery: :replay_safe` is a reviewed property of a read: the boot
  audit refuses it on any other kind and any other value, the set a
  recovered turn may re-dispatch is derived from the declarations, and
  that derived set is the review record.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Ops.{Annotations, Catalog}

  defmodule Carrier do
    @behaviour Cyfr.Ops.Provider

    def service, do: "carrier"

    def tools do
      [
        %{
          name: "carrier",
          description: "reads and a write",
          annotations: %{
            actions: %{
              "peek" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
              "poke" => %{kind: :write, planes: [:in_chain], recovery: :replay_safe},
              "odd" => %{kind: :read, planes: [:in_chain], recovery: :reconcile}
            }
          },
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "action" => %{"type" => "string", "enum" => ["peek", "poke", "odd"]}
            }
          }
        }
      ]
    end

    def handle(_ctx, _args), do: {:ok, %{}}
  end

  test "the audit refuses replay safety on a write and any value but replay_safe" do
    assert {:error, missing} = Catalog.audit_action_kinds([Carrier])

    assert Enum.map(missing, &{&1.action, &1.reason}) |> Enum.sort() ==
             [{"odd", :invalid_recovery}, {"poke", :invalid_recovery}]
  end

  test "the reader answers replay_safe for a read and nothing else" do
    [tool] = Carrier.tools()
    assert Annotations.recovery(tool, "peek") == :replay_safe
    assert Annotations.recovery(tool, "odd") == nil
    assert Annotations.recovery(tool, "nope") == nil
  end

  test "the derived set is the review record" do
    assert Catalog.replay_safe_actions() == [
             "aqua.skill_get",
             "aqua.skill_list",
             "component.inspect",
             "component.list",
             "notes.list",
             "notes.read",
             "notes.search"
           ]

    assert Catalog.replay_safe_actions([Carrier]) == ["carrier.peek", "carrier.poke"]
    assert Aqua.Ops.replay_safe?("notes", "read")
    refute Aqua.Ops.replay_safe?("notes", "keep")
    refute Aqua.Ops.replay_safe?("http", "get")
  end
end
