# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A store that cannot give the AQUA roles listing; every other read is the
# local adapter's.
defmodule Compendium.Providers.AquaListTest.UnreadableRoles do
  @moduledoc false
  use Arca.Storage.TestDouble

  @roles Compendium.AquaPath.roles_root()

  def list_typed(_actor, @roles), do: {:error, :eacces}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

# A store that refuses the AQUA roles listing with a typed refusal.
defmodule Compendium.Providers.AquaListTest.TypedRefusalRoles do
  @moduledoc false
  use Arca.Storage.TestDouble

  @roles Compendium.AquaPath.roles_root()

  def list_typed(_actor, @roles), do: {:error, :database_error}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

# A store that holds the soul's file but cannot give it.
defmodule Compendium.Providers.AquaListTest.UnreadableSoul do
  @moduledoc false
  use Arca.Storage.TestDouble

  # The soul's one object, read under its revision's prefix as the unit's
  # own name.
  @soul List.last(Compendium.AquaPath.soul_file())

  def get(actor, path) do
    if List.last(path) == @soul,
      do: {:error, :eacces},
      else: Arca.Adapters.Local.get(actor, path)
  end
end

# A store that cannot give one role's file.
defmodule Compendium.Providers.AquaListTest.UnreadableRole do
  @moduledoc false
  use Arca.Storage.TestDouble

  @planner List.last(Compendium.AquaPath.agent_file("planner"))

  def get(actor, path) do
    if List.last(path) == @planner,
      do: {:error, :eacces},
      else: Arca.Adapters.Local.get(actor, path)
  end
end

# A store that answers, and holds no soul and no role.
defmodule Compendium.Providers.AquaListTest do
  @moduledoc """
  The `aqua` tool's list answers the agents it read or refuses: a roles
  listing the store refuses, or a soul it holds but cannot give, is refused
  (a raw storage answer as `{:unavailable, "Storage"}`, as the tool's other
  reads refuse it), never the guides alone, which would read as an athanor
  with no assistant. A role that cannot be read stays out of the
  closet, and an athanor that holds no agents answers its guides.
  """

  use ExUnit.Case, async: false

  alias Compendium.Providers.AquaListTest.{
    TypedRefusalRoles,
    UnreadableRole,
    UnreadableRoles,
    UnreadableSoul
  }

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "aqua_list_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    n = System.unique_integer([:positive])
    user = "local|idp|aqua-list-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Aqua list #{n}")
    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
    :ok = Sanctum.TestContext.shipped!(athanor.id)
    {:ok, ctx: %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}}
  end

  # The storage adapter for the rest of the test.
  defp storage!(adapter) do
    original = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, adapter)

    on_exit(fn ->
      if original,
        do: Application.put_env(:arca, :storage_adapter, original),
        else: Application.delete_env(:arca, :storage_adapter)
    end)
  end

  defp list(ctx), do: Aqua.Ops.call_tool("aqua", ctx, %{"action" => "list", "detail" => true})

  defp names(%{guides: guides}), do: Enum.map(guides, & &1.name)

  @guides ["component-guide", "tincture-guide", "integration-guide"]

  test "the list answers the soul, the roles and the guides", %{ctx: ctx} do
    assert {:ok, listed} = list(ctx)
    assert ["aqua" | _] = names(listed)
    assert "planner" in names(listed)
    assert Enum.take(names(listed), -3) == @guides
  end

  @tag :capture_log
  test "a roles listing the store refuses is refused as storage unavailable, never the guides alone",
       %{ctx: ctx} do
    storage!(UnreadableRoles)
    assert {:error, {:unavailable, "Storage"}} = list(ctx)
  end

  test "a typed refusal from the store passes as it came", %{ctx: ctx} do
    storage!(TypedRefusalRoles)
    assert {:error, :database_error} = list(ctx)
  end

  @tag :capture_log
  test "a soul the store holds but cannot give is refused as storage unavailable", %{ctx: ctx} do
    storage!(UnreadableSoul)
    assert {:error, {:unavailable, "Storage"}} = list(ctx)
  end

  @tag :capture_log
  test "a role that cannot be read stays out, and the list answers the rest", %{ctx: ctx} do
    storage!(UnreadableRole)
    assert {:ok, listed} = list(ctx)
    assert ["aqua" | _] = names(listed)
    refute "planner" in names(listed)
  end

  test "an athanor that holds no agents answers its guides", %{ctx: ctx} do
    # Every agent the fill shipped goes, unit by unit, as a reset of the
    # whole root would take them.
    assert :ok =
             Arca.Overlay.with_internal_writes(fn ->
               Arca.delete_tree(Sanctum.Context.actor(ctx), ["aqua"])
             end)

    assert {:ok, listed} = list(ctx)
    assert names(listed) == @guides
  end
end
