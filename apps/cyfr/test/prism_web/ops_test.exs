# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.OpsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Catalog
  alias Sanctum.Gate.Probe
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

  test "fetch_list unwraps the list under its key", %{socket: socket} do
    Catalog.with_providers([Probe.List], fn ->
      assert {:ok, [%{id: 1}]} = Ops.fetch_list(socket, "helper_list_probe/wrapped", :items)
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

    test "a context the guard refuses is one refused decision under the person it presented " <>
           "and no tenant, and nothing runs",
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

        # The context's athanor is active, and still the record names none.
        assert Sanctum.Tenancy.Athanors.active?(stale.athanor_id)
        assert {:ok, [refused]} = global_decisions(request_id)

        refusal = Sanctum.Refusals.classify(reason)

        assert {refused.admission, refused.plane, refused.tool, refused.action} ==
                 {:refused, :external, "ingress_probe", "echo"}

        assert {refused.user_id, refused.athanor_id} == {stale.user_id, nil}
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

  # A refusal the guard makes is filed under no tenant, whatever state the
  # athanor its context names is in: no row of either log names it.
  describe "the athanor a refused console call is recorded under" do
    setup do
      Process.register(self(), :ingress_probe_observer)
      person = PrismWeb.ConnCase.test_user()

      home = Sanctum.Test.People.athanor!(person.user_id)

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
      {:ok, person: person, home: home, established: established}
    end

    test "an archived athanor: one decision with no athanor, and no row names it",
         %{person: person, home: home, established: established} do
      Sanctum.TestContext.archive!(home.id)

      assert_no_tenant(established, home, person)
    end

    test "an active athanor not the person's: focus refuses it, and a context naming it is " <>
           "one decision with no athanor, the person kept",
         %{person: person, established: established} do
      other = other_athanor!()
      assert {:error, :not_found} = Sanctum.Context.focus(established, other.id)
      assert Sanctum.Tenancy.Athanors.active?(other.id)

      assert_no_tenant(%{established | athanor_id: other.id}, other, person)
    end

    # An active athanor another person owns.
    defp other_athanor! do
      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create(%{
          name: "Elsewhere",
          slug: "elsewhere-#{System.unique_integer([:positive])}",
          owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          created_by: "system"
        })

      athanor
    end

    # A call from `focused`, once the guard refuses it, leaves one refused
    # decision that keeps the person and names no athanor, in no row of
    # either log, the reason's text included.
    defp assert_no_tenant(focused, athanor, person) do
      request_id = Prima.UUID7.request_id()
      stale = %{focused | request_id: request_id, validated_at: nil}

      assert {:error, _refused} = refused_call(stale)
      assert {:ok, [refused]} = global_decisions(request_id)

      assert {refused.admission, refused.athanor_id, refused.user_id} ==
               {:refused, nil, person.user_id}

      refute refused.reason =~ athanor.id
      assert rows_naming(athanor.id) == {0, 0}
    end

    # A call the guard refuses: nothing it named runs.
    defp refused_call(stale) do
      Catalog.with_providers([Probe.Ingress], fn ->
        result = Ops.call_tool(stale, "ingress_probe/echo", %{"id" => "x"})
        refute_received {:reached_handler, _}
        result
      end)
    end

    # The host's own decisions under `request_id`, the rows naming no
    # athanor, which is what each refusal here must be: a refusal that kept
    # its tenant is not among them, so the match on one row fails.
    defp global_decisions(request_id),
      do:
        Arca.DecisionLog.list_global(%Prima.Actor{platform_admin: true},
          request_id: request_id
        )

    # How many rows of `decision_logs` and of `mcp_logs` name `athanor_id`.
    defp rows_naming(athanor_id) do
      count = fn table ->
        Arca.Repo.one(from(r in table, where: r.athanor_id == ^athanor_id, select: count()))
      end

      {count.("decision_logs"), count.("mcp_logs")}
    end
  end
end
