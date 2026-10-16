# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionLedgerTest do
  @moduledoc """
  A run's source ledger on `executions.sources`: seeded in the admission
  transaction (a root's as its admission names it, a child's from its
  parent's as it stands, any sources its admission adds joined into its
  ancestors first), joined up the admission chain root first and below a
  turn root no further, read with provenance that cannot be read as
  outside, and recorded in the started event for audit.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.Execution
  alias Arca.Schemas.Execution, as: Row
  alias Prima.Source

  @athanor Arca.Test.Actor.athanor_id()

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp actor, do: Prima.Actor.in_athanor(@athanor)

  defp admit!(attrs) do
    {:ok, %{execution: row}} =
      Execution.admit(
        Map.merge(
          %{
            id: "exec_ledger_#{System.unique_integer([:positive])}",
            reference: "catalyst:local.ledger:1.0.0",
            user_id: "user_test",
            athanor_id: @athanor,
            component_type: "catalyst",
            origin: :programmatic
          },
          attrs
        ),
        Arca.Test.Actor.standing(@athanor)
      )

    row
  end

  defp sources!(id) do
    {:ok, sources} = Execution.sources(actor(), id)
    sources
  end

  defp started_sources(id) do
    Ecto.Query.from(e in Arca.Schemas.ExecutionEvent,
      where: e.execution_id == ^id and e.type == "execution.started",
      select: e.data
    )
    |> Arca.Repo.one()
    |> Jason.decode!()
    |> Map.fetch!("sources")
  end

  test "a root is seeded as its admission names it, and the started event records the seed" do
    root = admit!(%{sources: [Source.outside("webhook")]})

    assert sources!(root.id) == [Source.outside("webhook")]
    assert started_sources(root.id) == [%{"class" => "outside", "name" => "webhook"}]

    bare = admit!(%{})
    assert sources!(bare.id) == []
  end

  test "a child starts from its parent's ledger as it stands, and what its admission adds reaches its ancestors first" do
    root = admit!(%{sources: [Source.new(:pinned)]})
    child = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    assert sources!(child.id) == [Source.new(:pinned)]

    proxy =
      admit!(%{
        parent_execution_id: child.id,
        root_execution_id: root.id,
        kind: "tool_call",
        component_type: "tool_server",
        sources: [Source.outside("search")]
      })

    assert sources!(proxy.id) == [Source.new(:pinned), Source.outside("search")]
    assert sources!(child.id) == [Source.new(:pinned), Source.outside("search")]
    assert sources!(root.id) == [Source.new(:pinned), Source.outside("search")]
  end

  test "a child's admission ignores no parent growth: a later child sees what its parent read since" do
    root = admit!(%{})
    first = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    assert sources!(first.id) == []

    assert :ok = Execution.join_sources(actor(), root.id, [Source.new(:filed)])
    second = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})

    assert sources!(second.id) == [Source.new(:filed)]
    assert sources!(first.id) == []
  end

  test "a join reaches the run and every ancestor, never a sibling, and only grows" do
    root = admit!(%{})
    parent = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    child = admit!(%{parent_execution_id: parent.id, root_execution_id: root.id})
    sibling = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})

    assert :ok = Execution.join_sources(actor(), child.id, [Source.new(:vault_disclosed)])
    assert :ok = Execution.join_sources(actor(), child.id, [Source.outside("a.test")])
    assert :ok = Execution.join_sources(actor(), parent.id, [])

    expected = [Source.new(:vault_disclosed), Source.outside("a.test")]

    for id <- [child.id, parent.id, root.id], do: assert(sources!(id) == expected)
    assert sources!(sibling.id) == []

    assert Execution.join_sources(actor(), "exec_none", [Source.new(:filed)]) ==
             {:error, :not_found}
  end

  test "a join stops below a turn root, whose ledger is its turns'" do
    turn_root = admit!(%{kind: "turn", component_type: "agent"})
    hand = admit!(%{parent_execution_id: turn_root.id, root_execution_id: turn_root.id})

    assert :ok = Execution.join_sources(actor(), hand.id, [Source.new(:vault_disclosed)])

    assert sources!(hand.id) == [Source.new(:vault_disclosed)]
    assert Arca.Repo.get!(Row, turn_root.id).sources == "[]"
    # No turn runs on it yet: its turns' sources are none.
    assert sources!(turn_root.id) == []
  end

  test "a stored ledger that does not read is one unnamed outside source, never none" do
    root = admit!(%{})

    {1, _} =
      Arca.Repo.update_all(Ecto.Query.from(e in Row, where: e.id == ^root.id),
        set: [sources: "not json"]
      )

    assert sources!(root.id) == [Source.outside(nil)]

    child = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    assert sources!(child.id) == [Source.outside(nil)]
  end

  test "flow_state carries the classes the tree's launch let flow, from its root's policy" do
    root =
      admit!(%{
        host_policy: Jason.encode!(%{Execution.launch_key() => ["filed", "bogus", "outside"]})
      })

    child = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})

    assert {:ok, %{sources: [], launch_classes: [:filed, :outside]}} =
             Execution.flow_state(actor(), child.id)

    plain = admit!(%{})
    assert {:ok, %{launch_classes: []}} = Execution.flow_state(actor(), plain.id)
    assert Execution.flow_state(actor(), "exec_none") == {:error, :not_found}
  end

  test "sources admitted that are not Prima.Source values refuse the admission, writing nothing" do
    id = "exec_ledger_bad_#{System.unique_integer([:positive])}"

    assert {:error, :invalid_sources} =
             Execution.admit(
               %{
                 id: id,
                 reference: "catalyst:local.ledger:1.0.0",
                 user_id: "user_test",
                 athanor_id: @athanor,
                 component_type: "catalyst",
                 origin: :programmatic,
                 sources: [%{"class" => "filed"}]
               },
               Arca.Test.Actor.standing(@athanor)
             )

    assert is_nil(Arca.Repo.get(Row, id))
  end
end
