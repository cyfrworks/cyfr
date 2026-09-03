# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.MemoryToolTest do
  # Notes are not the transcript. These pin the difference, and the one
  # question keeping something asks: whose notes.
  use ExUnit.Case, async: false

  alias Emissary.MCP.MemoryTool, as: Tool

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "memory_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    n = System.unique_integer([:positive])
    user = "local|idp|note-#{n}"

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me#{n}",
        owner_user_id: user,
        created_by: user
      })

    {:ok, _} = Sanctum.Tenancy.Users.upsert_from_provider(%{id: user, provider: "local"})
    {:ok, u} = Sanctum.Tenancy.Users.get(user)
    {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)
    # The owner's seat in their own athanor — production mints it in
    # `ensure_personal_athanor/1`, and `Context.focus/2` (the "mine" swap)
    # reads it.
    {:ok, _} = Sanctum.Tenancy.Members.create(%{user_id: user, athanor_id: mine.id})
    {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Trip #{n}")

    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}
    {:ok, ctx: ctx, mine: mine, estate: estate}
  end

  defp call(ctx, args), do: Tool.handle("memory", ctx, args)

  test "a note goes where the person said, and nowhere else", %{
    ctx: ctx,
    mine: mine,
    estate: estate
  } do
    {:ok, kept} =
      call(ctx, %{
        "action" => "note",
        "scope" => "mine",
        "name" => "flight",
        "content" => "BA117"
      })

    # "mine" is the person's own athanor even though the focus is the trip.
    assert kept.athanor_id == mine.id

    {:ok, %{notes: theirs}} = call(ctx, %{"action" => "list", "scope" => "estate"})
    assert theirs == []

    {:ok, %{notes: [%{name: "flight"}]}} = call(ctx, %{"action" => "list", "scope" => "mine"})

    {:ok, %{content: "BA117"}} =
      call(ctx, %{"action" => "read", "scope" => "mine", "name" => "flight"})

    refute estate.id == mine.id
  end

  test "keeping something requires saying whose notes", %{ctx: ctx} do
    # Reads default to where you are; a write must be explicit. Putting a
    # note in the wrong estate is the mistake worth making impossible to
    # make quietly.
    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "note", "name" => "x", "content" => "y"})

    assert msg =~ "scope"
  end

  test "a group's notes are readable by its members", %{ctx: ctx} do
    {:ok, _} =
      call(ctx, %{
        "action" => "note",
        "scope" => "estate",
        "name" => "decided",
        "content" => "Lisbon"
      })

    other = %{ctx | user_id: "local|idp|somebody-else"}

    {:ok, _} =
      Sanctum.Tenancy.Members.create(%{user_id: other.user_id, athanor_id: ctx.athanor_id})

    # No private memory in a shared estate — the invariant is a fact here,
    # not a sentence in a docstring.
    assert {:ok, %{notes: [%{name: "decided"}]}} = call(other, %{"action" => "list"})
    assert {:ok, %{content: "Lisbon"}} = call(other, %{"action" => "read", "name" => "decided"})
  end

  test "forgetting removes it", %{ctx: ctx} do
    {:ok, _} =
      call(ctx, %{"action" => "note", "scope" => "estate", "name" => "temp", "content" => "x"})

    {:ok, %{forgot: "temp"}} =
      call(ctx, %{"action" => "forget", "scope" => "estate", "name" => "temp"})

    assert {:ok, %{notes: []}} = call(ctx, %{"action" => "list"})

    assert {:error, {:not_found, "note", "temp"}} =
             call(ctx, %{"action" => "read", "name" => "temp"})
  end

  test "an agent cannot write memory — the root is host-only" do
    # `Arca.Storage`'s layout gives `memory/` no guest name, so it does not
    # exist at the guest boundary at all. Keeping something is a person's
    # act, and so is choosing whose notes it goes into.
    refute Map.has_key?(Arca.Storage.guest_scopes(), "memory")
    assert "memory" in Arca.Storage.tenant_roots()

    for {name, spec} <- Tool.definition().annotations.actions do
      assert spec.planes == [:external], "#{name} is reachable in-chain"
      assert spec.consent == :interactive, "#{name} is reachable by a standing credential"
    end
  end

  test "a standing credential cannot keep, read or forget notes", %{ctx: ctx} do
    # The host-only root stops the guest; this stops the credential. A key
    # scoped to an estate must not reach the creator's personal tree
    # through "mine" — or the estate's notes through anything.
    star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

    assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
             Emissary.MCP.ToolRegistry.call_external("memory", star, %{
               "action" => "note",
               "scope" => "mine",
               "name" => "sneak",
               "content" => "x"
             })

    assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
             Emissary.MCP.ToolRegistry.call_external("memory", star, %{"action" => "list"})

    # Discovery agrees with dispatch: the key is not shown the tool.
    shown =
      Emissary.MCP.ToolVisibility.filter_for_context(
        Emissary.MCP.ToolRegistry.list_tools(),
        star
      )

    refute Enum.any?(shown, &(&1["name"] == "memory"))
  end

  test "an archived personal athanor cannot take notes", %{ctx: ctx, mine: mine} do
    # The "mine" swap goes through `Context.focus/2`, so it inherits the
    # archive refusal a raw struct update would have skipped.
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(mine, force: true)

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{
               "action" => "note",
               "scope" => "mine",
               "name" => "late",
               "content" => "x"
             })

    assert msg =~ "archived"
  end

  test "a note name is held to a grammar", %{ctx: ctx} do
    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{
               "action" => "note",
               "scope" => "estate",
               "name" => "../escape",
               "content" => "x"
             })
  end
end
