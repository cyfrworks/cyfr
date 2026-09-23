# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.ToolGrantsTest do
  # Standing tool grants are consent state: the tenant and the deciding
  # person come from the context, an outage is never "no grants", and a
  # row built for another transaction is the same row a write stores.
  use ExUnit.Case, async: false

  alias Sanctum.ToolGrants

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other}
  end

  defp decision(overrides \\ %{}) do
    Map.merge(
      %{
        scope: "thread",
        effect: "allow",
        thread_id: "thread_1",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      },
      overrides
    )
  end

  defp no_tenant(ctx), do: %{ctx | athanor_id: nil}

  test "the vocabulary is the stored one" do
    assert ToolGrants.scopes() == ["thread", "agent"]
    assert ToolGrants.effects() == ["allow", "deny"]
  end

  describe "put/2 and for_thread/2" do
    test "a decision lands in the caller's tenant, by the caller", %{ctx: ctx} do
      assert {:ok, grant} = ToolGrants.put(ctx, decision())
      assert grant.athanor_id == ctx.athanor_id
      assert grant.granted_by == ctx.user_id

      assert {:ok, [%{tool: "component", action: "pull", effect: "allow"}]} =
               ToolGrants.for_thread(ctx, "thread_1")
    end

    test "a caller cannot name the tenant, the person or the row", %{ctx: ctx, other: other} do
      smuggled =
        decision(%{athanor_id: other.athanor_id, granted_by: "someone-else", id: "grant_forged"})

      assert {:ok, grant} = ToolGrants.put(ctx, smuggled)
      assert grant.athanor_id == ctx.athanor_id
      assert grant.granted_by == ctx.user_id
      refute grant.id == "grant_forged"

      assert {:ok, []} = ToolGrants.for_thread(other, "thread_1")
    end

    test "an agent-scope decision names no thread and reaches every thread", %{ctx: ctx} do
      assert {:ok, grant} = ToolGrants.put(ctx, decision(%{scope: "agent"}))
      assert is_nil(grant.thread_id)

      assert {:ok, [%{scope: "agent"}]} = ToolGrants.for_thread(ctx, "thread_2")
    end

    test "attributes that do not make a grant are refused with their fields", %{ctx: ctx} do
      assert {:error, {:invalid, errors}} =
               ToolGrants.put(ctx, decision(%{scope: "forever", effect: "maybe", tool: ""}))

      assert Map.keys(errors) |> Enum.sort() == [:effect, :scope, :tool]

      assert {:error, {:invalid, %{thread_id: _}}} =
               ToolGrants.put(ctx, Map.delete(decision(), :thread_id))
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable, never an empty list", %{ctx: ctx} do
      {:ok, _} = ToolGrants.put(ctx, decision())
      Arca.Repo.query!("ALTER TABLE tool_grants RENAME TO tool_grants_unavailable")

      assert {:error, :unavailable} = ToolGrants.for_thread(ctx, "thread_1")
      assert {:error, :unavailable} = ToolGrants.put(ctx, decision(%{action: "list"}))
      assert {:error, :unavailable} = ToolGrants.revoke(ctx, decision())
    end

    test "a context with no tenant is refused before any read or write", %{ctx: ctx} do
      assert {:error, :no_athanor} = ToolGrants.for_thread(no_tenant(ctx), "thread_1")
      assert {:error, :no_athanor} = ToolGrants.put(no_tenant(ctx), decision())
      assert {:error, :no_athanor} = ToolGrants.revoke(no_tenant(ctx), decision())
    end
  end

  describe "revoke/2" do
    test "withdraws by key, in the caller's tenant only, idempotently",
         %{ctx: ctx, other: other} do
      # A thread id is global, so the same agent-scope key is what two
      # tenants can both hold.
      agent_key = decision(%{scope: "agent"})
      {:ok, _} = ToolGrants.put(ctx, agent_key)
      {:ok, _} = ToolGrants.put(other, agent_key)

      assert :ok = ToolGrants.revoke(ctx, Map.delete(agent_key, :effect))
      assert {:ok, []} = ToolGrants.for_thread(ctx, "thread_1")
      assert {:ok, [_theirs]} = ToolGrants.for_thread(other, "thread_1")

      assert :ok = ToolGrants.revoke(ctx, agent_key)
    end
  end

  describe "grant_row/2" do
    test "builds the row a write would store, without storing it", %{ctx: ctx} do
      assert {:ok, row} = ToolGrants.grant_row(ctx, decision(%{athanor_id: "ath_forged"}))

      assert row == %{
               athanor_id: ctx.athanor_id,
               granted_by: ctx.user_id,
               scope: "thread",
               effect: "allow",
               thread_id: "thread_1",
               agent_name: "aqua",
               tool: "component",
               action: "pull"
             }

      assert {:ok, []} = ToolGrants.for_thread(ctx, "thread_1")

      # The turn store writes exactly this row inside its own transaction.
      assert {:ok, _} = Arca.ToolGrantStorage.put(row)
      assert {:ok, [_stored]} = ToolGrants.for_thread(ctx, "thread_1")
    end

    test "refuses a context with no tenant and attributes that make no grant", %{ctx: ctx} do
      assert {:error, :forbidden} = ToolGrants.grant_row(no_tenant(ctx), decision())
      assert {:error, :invalid_argument} = ToolGrants.grant_row(ctx, decision(%{effect: nil}))
      assert {:error, :invalid_argument} = ToolGrants.grant_row(ctx, decision(%{scope: "all"}))
    end
  end
end
