# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.AquaToolConsentTest do
  # The `aqua` tool's write door: every write is a person's own act, so a
  # standing credential is refused at the registry's dispatch gate and is
  # not shown the writes in `tools/list`; the reads stay open to every
  # surface, because a turn resolves its soul through them.
  use ExUnit.Case, async: false

  alias Compendium.MCP.AquaTool, as: Tool
  alias Grimoire.Catalog
  alias Grimoire.Visibility

  @writes ~w(create update delete reset skill_create skill_update skill_delete skill_reset)
  @reads ~w(list get status skill_list skill_get)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the annotations say who may write and what a person may pre-answer" do
    actions = Tool.definition().annotations.actions

    for action <- @writes do
      assert actions[action].consent == :interactive, "aqua.#{action} is not interactive"
    end

    for action <- @reads do
      refute Map.has_key?(actions[action], :consent), "aqua.#{action} declares a consent class"
    end

    # The two scroll writes a chain may propose are read into every turn's
    # prompt index — each one a click, no standing allow at any scope.
    assert actions["skill_create"].standing == false
    assert actions["skill_update"].standing == false

    for action <- (@writes -- ~w(skill_create skill_update)) ++ @reads do
      refute Map.has_key?(actions[action], :standing), "aqua.#{action} declares a standing rule"
    end
  end

  test "a standing credential cannot write the soul, a role or a scroll", %{ctx: ctx} do
    # A `*` admin key holds every permission and is still refused: the
    # consent class admits a surface, never a permission atom.
    star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

    calls = [
      {"skill_create", %{"name" => "sneak", "description" => "d", "content" => "c"}},
      {"skill_update", %{"name" => "capability-acquisition", "content" => "c"}},
      {"reset", %{"all" => true}},
      {"update", %{"name" => "aqua", "content" => "x"}},
      {"create", %{"name" => "sneak", "content" => "x"}},
      {"delete", %{"name" => "aqua"}},
      {"reset", %{"name" => "aqua"}},
      {"skill_delete", %{"name" => "capability-acquisition"}},
      {"skill_reset", %{"name" => "capability-acquisition"}}
    ]

    for {action, args} <- calls do
      assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
               Catalog.call_external("aqua", star, Map.put(args, "action", action)),
             "aqua.#{action} answered a standing credential"
    end

    # The reads stay open to the key — a turn resolves its soul and its
    # scrolls through them.
    assert {:ok, %{skills: _}} =
             Catalog.call_external("aqua", star, %{"action" => "skill_list"})

    # Discovery agrees with dispatch: the key is shown the reads alone.
    [aqua] =
      Catalog.list_tools()
      |> Visibility.filter_for_context(star)
      |> Enum.filter(&(&1["name"] == "aqua"))

    shown = get_in(aqua, ["inputSchema", "properties", "action", "enum"])
    assert Enum.sort(shown) == Enum.sort(@reads)
  end
end
