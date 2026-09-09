# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TurnComposeTest do
  # Compose a turn with one roster read and one catalyst listing.
  use ExUnit.Case, async: false

  alias Aqua.Orchestrator
  alias Aqua.Turn

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "turn_compose_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Every tool call the registry dispatches for this estate mints a row,
  # synchronously, before the call runs — so the rows ARE the round trips.
  # The soul's run-time detail as a turn reads it: an in-process read of
  # the tree, never a tool call.
  defp soul(ctx) do
    {:ok, detail} = Aqua.AgentConfig.agent(ctx, "aqua")

    %{
      "name" => "aqua",
      "title" => detail["title"] || "aqua",
      "catalyst_ref" => detail["catalyst_ref"],
      "model" => detail["model"],
      "tool_policy" => detail["tool_policy"] || %{}
    }
  end

  defp calls(ctx) do
    {:ok, rows} = Arca.McpLog.list(athanor_id: ctx.athanor_id, limit: 1_000)
    Map.new(rows, &{&1.id, &1.tool})
  end

  defp calls_since(ctx, mark) do
    ctx
    |> calls()
    |> Map.drop(Map.keys(mark))
    |> Map.values()
    |> Enum.sort()
  end

  test "compose reads the tree in-process — no tool call per role, one catalyst listing", %{
    ctx: ctx
  } do
    # Four roles on top of the shipped closet, written through the door
    # (writes stay tool calls).
    for n <- 1..4 do
      {:ok, _} =
        Aqua.AgentConfig.call_aqua(ctx, %{
          "action" => "create",
          "name" => "role_#{n}",
          "title" => "Role #{n}",
          "description" => "does #{n}",
          "content" => "# Role #{n}"
        })
    end

    # The positive control: a tool call is counted here, so a zero below
    # means "not called", not "not logged".
    mark = calls(ctx)
    {:ok, _} = Aqua.AgentConfig.call_aqua(ctx, %{"action" => "list"})
    assert calls_since(ctx, mark) == ["aqua"]

    mark = calls(ctx)
    soul = soul(ctx)
    assert %{"name" => "aqua", "tool_policy" => policy} = soul
    assert is_map(policy)
    # Resolving the pick is an in-process read too.
    assert calls_since(ctx, mark) == []

    # The shipped soul pins a catalyst this test estate does not hold;
    # unpinned, the ref rides through to the engine's default.
    assert {:ok, %{input: input}} =
             Turn.build_input(ctx, Map.put(soul, "catalyst_ref", nil), "hi")

    names = Enum.map(input["sub_agents"], & &1["name"])
    assert Enum.all?(1..4, &("role_#{&1}" in names))
    assert "aqua_builder" in names
    refute "aqua" in names

    # The authored prompt came off the roster, the scrolls off the tree:
    # both are in the composition with no `aqua` round trip.
    assert input["system"] =~ "## Scrolls"
    assert input["system"] =~ "capability-acquisition"

    # One listing for every catalyst resolve, and nothing else.
    assert calls_since(ctx, mark) == ["component"]
  end

  test "the roster is the tool's projection: the soul first, then the roles, string-keyed", %{
    ctx: ctx
  } do
    assert {:ok, roster} = Aqua.AgentConfig.roster(ctx)
    assert [%{"name" => "aqua", "type" => "soul"} | roles] = roster
    assert roles != []
    assert Enum.all?(roles, &(&1["type"] == Compendium.AquaAgent.role_type()))
    assert Enum.all?(roster, &is_binary(&1["content"]))

    # One agent reads in the same projection, and a name outside the
    # grammar never becomes a path.
    assert {:ok, %{"name" => "aqua", "type" => "soul"}} = Aqua.AgentConfig.agent(ctx, "aqua")
    assert {:error, :not_found} = Aqua.AgentConfig.agent(ctx, "../escape")
    assert {:error, :not_found} = Aqua.AgentConfig.agent(ctx, "nobody")
  end

  test "begin/5 walks the road from a pick to a running execution — resolve, pin, compose, start",
       %{ctx: ctx} do
    # A role that pins no catalyst (the engine-default path): the shipped
    # soul names one this estate does not hold, and that refusal is the
    # last assertion here.
    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "create",
        "name" => "scout",
        "title" => "Scout",
        "description" => "scouts",
        "content" => "# Scout"
      })

    Aqua.FakeTurn.listen()
    pick = Orchestrator.by_name("scout")
    refute Orchestrator.resolved?(pick)

    assert {:ok, started} = Turn.begin(ctx, "conv_begin", pick, "hi", engine: Aqua.FakeTurn)

    # Pinned before it composed; started under that pin, not a re-selection.
    assert_receive {:fake_pin_profile, _ctx}
    assert_receive {:fake_start, eid, _ctx, input, profile}
    assert started.execution_id == eid
    assert profile == Aqua.FakeTurn.fake_profile_id()
    assert started.profile_id == profile
    assert input["task"] == "hi"

    # The pick came back resolved from the estate's own tree, its owner
    # the focus, its policy composed — and that composition is the policy
    # the turn's intents are checked against.
    assert %Orchestrator{name: "scout", agent: %{"title" => "Scout"}} = started.orchestrator
    assert Orchestrator.resolved?(started.orchestrator)
    assert started.tool_policy == Orchestrator.tool_policy(started.orchestrator)
    assert started.grants == MapSet.new()

    # A name the tree does not hold fails on this road, never at the send.
    nobody = Orchestrator.by_name("nobody")

    assert {:error, :no_orchestrator} =
             Turn.begin(ctx, "conv_begin", nobody, "hi", engine: Aqua.FakeTurn)

    # Compose's own refusal passes through unchanged.
    soul = Orchestrator.by_name("aqua")

    assert {:error, {:catalyst_not_in_estate, _ref}} =
             Turn.begin(ctx, "conv_begin", soul, "hi", engine: Aqua.FakeTurn)

    refute_received {:fake_start, _, _, _, _}
  end

  defmodule UnreadableRolesAdapter do
    use Arca.Storage.TestDouble

    def list_typed(_ctx, ["aqua", "roles"]), do: {:error, :eacces}
    def list_typed(ctx, path), do: Arca.Adapters.Local.list_typed(ctx, path)
  end

  test "a tree that cannot be read refuses the turn with a sentence — never an empty crew", %{
    ctx: ctx
  } do
    soul = soul(ctx) |> Map.put("catalyst_ref", nil)

    prev = Application.get_env(:cyfr, :storage_adapter)
    Application.put_env(:cyfr, :storage_adapter, UnreadableRolesAdapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :storage_adapter, prev),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:unavailable, what}} = Turn.build_input(ctx, soul, "hi")
        assert Cyfr.Ops.Error.render({:unavailable, what}) =~ "retry shortly"

        # The addressing roster keeps its fail-open contract for the chat,
        # but says so rather than answering "nobody here" silently.
        assert Turn.roster(ctx) == []
      end)

    assert log =~ "the aqua tree could not be listed"
  end
end
