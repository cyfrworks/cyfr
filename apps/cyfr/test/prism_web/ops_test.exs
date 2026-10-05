# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.OpsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Grimoire.Catalog
  alias Grimoire.Probe
  alias PrismWeb.Ops

  setup do
    Cyfr.Test.Sandbox.setup!()
    {:ok, socket: %{assigns: %{context: Sanctum.TestContext.local()}}}
  end

  test "call_tool splits tool/action and requires a context", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:ok, %{items: [%{id: 1}]}} =
               Ops.call_tool(socket, "helper_list_probe/wrapped")

      assert {:error, :no_context} = Ops.call_tool(%{assigns: %{}}, "key/list")
    end)
  end

  test "fetch_list unwraps both list shapes to one", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:ok, [%{id: 1}]} = Ops.fetch_list(socket, "helper_list_probe/wrapped", :items)
      assert {:ok, [%{id: 2}]} = Ops.fetch_list(socket, "helper_list_probe/bare", :items)
    end)
  end

  test "anything else becomes one failure vocabulary", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:error, "The outcome could not be confirmed."} =
               Ops.fetch_list(socket, "helper_list_probe/shapeless", :items)

      assert {:error, "Not allowed."} =
               Ops.fetch_list(socket, "helper_list_probe/refused", :items)

      assert {:error, "Not signed in."} =
               Ops.fetch_list(%{assigns: %{}}, "helper_list_probe/wrapped", :items)
    end)
  end

  test "error_message passes refusal sentences and hides raw terms" do
    assert Ops.error_message("Unauthorized: nope") == "Unauthorized: nope"
    assert Ops.error_message({:weird, :term}) == "The outcome could not be confirmed."
  end

  # A console call is recorded as one admission decision: by the gate when
  # the context stands, and here, before the gate, when it does not.
  describe "the decision a console call leaves" do
    setup do
      Process.register(self(), :ingress_probe_observer)
      {:ok, request_id: Prima.UUID7.request_id()}
    end

    test "a context the guard refuses is one refused decision under the identity it " <>
           "presented, and nothing runs",
         %{request_id: request_id} do
      # A console session no longer stored: the guard revalidates and refuses.
      stale = %{
        Sanctum.TestContext.local()
        | request_id: request_id,
          validated_at: nil,
          session_token_hash: :crypto.hash(:sha256, "a session no longer stored")
      }

      Catalog.with_providers([Probe.Ingress], fn ->
        assert {:error, reason} = Ops.call_tool(stale, "ingress_probe/echo", %{"id" => "x"})
        refute_received {:reached_handler, _}

        assert {:ok, [refused]} =
                 Arca.DecisionLog.correlate(Sanctum.Context.actor(stale), request_id)

        refusal = Grimoire.classify(reason)

        assert {refused.admission, refused.plane, refused.tool, refused.action} ==
                 {:refused, :external, "ingress_probe", "echo"}

        assert {refused.user_id, refused.athanor_id} == {stale.user_id, stale.athanor_id}
        assert {refused.refusal_class, refused.reason} == {refusal.class, refusal.message}
        assert refused.completion == nil
      end)
    end

    test "a context that stands is one admission, the gate's", %{request_id: request_id} do
      ctx = %{Sanctum.TestContext.local() | request_id: request_id}

      Catalog.with_providers([Probe.Ingress], fn ->
        assert {:ok, %{ok: true}} = Ops.call_tool(ctx, "ingress_probe/echo", %{"id" => "x"})
        assert_received {:reached_handler, %{"id" => "x"}}

        assert {:ok, [admitted]} =
                 Arca.DecisionLog.correlate(Sanctum.Context.actor(ctx), request_id)

        assert {admitted.admission, admitted.tool, admitted.action} ==
                 {:admitted, "ingress_probe", "echo"}

        assert admitted.completion == :succeeded
      end)
    end
  end

  # A refusal is filed under the athanor its context names only while that
  # athanor is active: an archived one, and a destroyed one (whose row
  # stays as an archived tombstone), take no row they could outlive.
  describe "the athanor a refused console call is recorded under" do
    setup do
      Process.register(self(), :ingress_probe_observer)
      person = PrismWeb.ConnCase.test_user()

      {:ok, home} =
        Sanctum.Tenancy.Athanors.create_group(person.user_id, "Home #{person.namespace}")

      ctx =
        Sanctum.Context.build(
          user_id: person.user_id,
          email: person.email,
          provider: "github",
          athanor_id: home.id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(ctx)
      {:ok, established} = Sanctum.Caller.establish(session.token)
      {:ok, person: person, established: established}
    end

    test "a destroyed athanor: one decision with no athanor, and no row names it",
         %{person: person, established: established} do
      {:ok, gone} = group!(person, "Gone")
      {:ok, on_gone} = Sanctum.Context.focus(established, gone.id)
      {:ok, archived} = Sanctum.Tenancy.Athanors.archive(gone)
      {:ok, _counts} = Sanctum.Tenancy.Athanors.destroy(archived)

      assert_no_tenant(on_gone, gone, person)
    end

    test "an archived athanor: one decision with no athanor, and no row names it",
         %{person: person, established: established} do
      {:ok, kept} = group!(person, "Kept")
      {:ok, on_kept} = Sanctum.Context.focus(established, kept.id)
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(kept)

      assert_no_tenant(on_kept, kept, person)
    end

    test "a seat removed in an active athanor is recorded under that athanor",
         %{person: person, established: established} do
      {:ok, left} = group!(person, "Left")
      other = PrismWeb.ConnCase.test_user()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.user_id, scope: "athanor", athanor_id: left.id)

      {:ok, on_left} = Sanctum.Context.focus(established, left.id)
      :ok = Sanctum.Tenancy.Members.remove_member(left, user_id: person.user_id)
      assert Sanctum.Tenancy.Athanors.active?(left.id)

      request_id = Prima.UUID7.request_id()
      stale = %{on_left | request_id: request_id, validated_at: nil}

      assert {:error, _refused} = refused_call(stale)

      assert {:ok, [refused]} =
               Arca.DecisionLog.correlate(Prima.Actor.in_athanor(left.id), request_id)

      assert {refused.admission, refused.athanor_id, refused.user_id} ==
               {:refused, left.id, person.user_id}
    end

    # A call from `focused`, once the guard refuses it, leaves one refused
    # decision that keeps the person and names no athanor, in no row of
    # either log, the reason's text included.
    defp assert_no_tenant(focused, athanor, person) do
      request_id = Prima.UUID7.request_id()
      stale = %{focused | request_id: request_id, validated_at: nil}

      assert {:error, _refused} = refused_call(stale)

      assert {:ok, [refused]} =
               Arca.DecisionLog.list_global(%Prima.Actor{platform_admin: true},
                 request_id: request_id
               )

      assert {refused.admission, refused.athanor_id, refused.user_id} ==
               {:refused, nil, person.user_id}

      refute refused.reason =~ athanor.id
      assert rows_naming(athanor.id) == {0, 0}
    end

    defp group!(person, label),
      do: Sanctum.Tenancy.Athanors.create_group(person.user_id, "#{label} #{person.namespace}")

    # A call the guard refuses: nothing it named runs.
    defp refused_call(stale) do
      Catalog.with_providers([Probe.Ingress], fn ->
        result = Ops.call_tool(stale, "ingress_probe/echo", %{"id" => "x"})
        refute_received {:reached_handler, _}
        result
      end)
    end

    # How many rows of `decision_logs` and of `mcp_logs` name `athanor_id`.
    defp rows_naming(athanor_id) do
      count = fn table ->
        Arca.Repo.one(from(r in table, where: r.athanor_id == ^athanor_id, select: count()))
      end

      {count.("decision_logs"), count.("mcp_logs")}
    end
  end
end
