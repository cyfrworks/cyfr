# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.FacadeTest do
  @moduledoc """
  The component domain's door for callers outside it: exactly its seven
  functions, and the component facts the assistant reads — the estate's
  model catalysts, its agent sources and its own formulas — each refused
  for a caller that may not read them and answered `:unavailable`, never
  empty, when the index or the store cannot answer.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "compendium_facade_#{System.unique_integer([:positive])}")

    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    # A filled estate of its own, so a listing starts no fill behind the test.
    n = System.unique_integer([:positive])
    user = "local|idp|facade-#{n}"
    {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Facade #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(estate)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}

    {:ok, ctx: ctx}
  end

  defp put_component!(ctx, type, name, version, manifest) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Context.actor(ctx), %{
        id: "facade_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: version,
        component_type: type,
        description: name,
        tags: "[]",
        digest: "sha256:#{name}-#{version}",
        size: 1,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    :ok
  end

  test "the root answers exactly its seven functions" do
    exported =
      Compendium.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == [
             agent_source_refs: 1,
             local_formula_refs: 1,
             model_catalysts: 1,
             tincture_asset_rules: 0,
             tincture_entry: 1,
             tincture_media: 2,
             valid_tincture_connect_domain?: 1
           ]
  end

  describe "model_catalysts/1" do
    test "every installed catalyst release, with the contracts its manifest declares", %{
      ctx: ctx
    } do
      chat = %{"contracts" => ["model/chat@1"]}
      :ok = put_component!(ctx, "catalyst", "claude", "1.2.0", chat)
      :ok = put_component!(ctx, "catalyst", "claude", "1.10.0", chat)
      :ok = put_component!(ctx, "catalyst", "files", "0.3.0", %{})
      :ok = put_component!(ctx, "formula", "not-a-catalyst", "1.0.0", chat)

      assert {:ok, rows} = Compendium.model_catalysts(ctx)

      assert rows |> Enum.map(&{&1.ref, &1.contracts}) |> Enum.sort() == [
               {"catalyst:local.claude:1.10.0", ["model/chat@1"]},
               {"catalyst:local.claude:1.2.0", ["model/chat@1"]},
               {"catalyst:local.files:0.3.0", []}
             ]

      for row <- rows do
        assert Map.keys(row) |> Enum.sort() ==
                 [:contracts, :name, :node_key, :publisher, :ref, :version]

        assert row.node_key == "catalyst:local.#{row.name}"
      end
    end

    test "refuses a caller that is not an authenticated reader focused on an estate", %{
      ctx: ctx
    } do
      assert {:error, :forbidden} = Compendium.model_catalysts(%{ctx | authenticated: false})

      assert {:error, :forbidden} =
               Compendium.model_catalysts(%{ctx | athanor_id: nil, scope: :platform})

      assert {:error, :forbidden} = Compendium.model_catalysts(%{ctx | scope: :platform})

      assert {:error, :forbidden} =
               Compendium.model_catalysts(%{ctx | permissions: MapSet.new([:execute])})

      assert {:error, :forbidden} = Compendium.model_catalysts(Context.enter_guest(ctx))
    end

    test "an index behind its tree is unavailable, not an empty estate", %{ctx: ctx} do
      :ok = put_component!(ctx, "catalyst", "claude", "1.0.0", %{"contracts" => ["model/chat@1"]})
      assert {:ok, [_]} = Compendium.model_catalysts(ctx)

      {:ok, _pending} =
        Arca.StorageProjectionChanges.begin_edit(
          Context.actor(ctx),
          "components",
          "catalysts/local/claude/1.0.0"
        )

      assert {:error, :unavailable} = Compendium.model_catalysts(ctx)
    end
  end

  describe "agent_source_refs/1" do
    test "an estate that names no athanor is forbidden", %{ctx: ctx} do
      assert {:error, :forbidden} = Compendium.agent_source_refs(%{ctx | athanor_id: nil})
    end

    test "an agent index behind its tree is unavailable, not an empty roster", %{ctx: ctx} do
      assert {:ok, rows} = Compendium.agent_source_refs(ctx)
      assert is_list(rows)

      {:ok, _pending} =
        Arca.StorageProjectionChanges.begin_edit(Context.actor(ctx), "aqua", "roles/scout.md")

      assert {:error, :unavailable} = Compendium.agent_source_refs(ctx)
    end
  end

  describe "local_formula_refs/1" do
    test "the estate's own formulas as name-level refs, once each", %{ctx: ctx} do
      :ok = put_component!(ctx, "formula", "report", "1.0.0", %{})
      :ok = put_component!(ctx, "formula", "report", "1.1.0", %{})
      :ok = put_component!(ctx, "catalyst", "claude", "1.0.0", %{})

      assert {:ok, ["formula:local.report"]} = Compendium.local_formula_refs(ctx)
    end

    test "an estate that names no athanor is forbidden", %{ctx: ctx} do
      assert {:error, :forbidden} = Compendium.local_formula_refs(%{ctx | athanor_id: nil})
    end
  end
end
