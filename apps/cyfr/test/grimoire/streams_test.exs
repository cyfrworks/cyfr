# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.StreamsTest do
  @moduledoc """
  The gate's stream entry: a declared stream is admitted once, recorded
  once, and answered with a grant bounded by the stream's declaration and
  the caller's credential; an undeclared stream, a subject its grammar
  does not admit, a credential that has ended and every caller the gate
  refuses an operation are refused, each as one decision. The table the
  providers declare is the only source, and the gate names no bus.
  """

  # Plants providers into the operation table and flips the member's slot.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Grimoire.Catalog
  alias Sanctum.Context

  defmodule Probe do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "probe"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams do
      [
        %Prima.Provider.Stream{
          name: "probe.deltas",
          topic: :execution_events,
          projection: ["seq", "delta"],
          subject: ~S"\Aexec_[a-z0-9]{1,16}\z",
          deadline_bound: 60
        }
      ]
    end
  end

  defmodule Twin do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "twin"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams, do: Grimoire.StreamsTest.Probe.streams()
  end

  defmodule Malformed do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "malformed"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams,
      do: [
        %Prima.Provider.Stream{
          name: "undotted",
          topic: :mcp_servers,
          projection: ["kind"],
          deadline_bound: 1
        }
      ]
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    {:ok, ctx: %{Sanctum.TestContext.local() | request_id: Prima.UUID7.request_id()}}
  end

  defp decisions(%Context{request_id: request_id}),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id))

  defp rows(%Context{request_id: request_id}),
    do: Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.request_id == ^request_id))

  defp assert_one_refusal(ctx, class) do
    assert [decision] = decisions(ctx)
    assert decision.admission == "refused"
    assert decision.refusal_class == Atom.to_string(class)
    assert decision.plane == "external"
    decision
  end

  describe "the table" do
    test "holds every provider's declared streams, the servers stream among them" do
      assert %Prima.Provider.Stream{topic: :mcp_servers, projection: ["kind"], subject: nil} =
               Enum.find(Grimoire.streams(), &(&1.name == "mcp_servers.changes"))

      assert {:ok, {Emissary.External.Provider, %Prima.Provider.Stream{}}} =
               Catalog.lookup_stream("mcp_servers.changes")

      assert Grimoire.streams() == Enum.sort_by(Grimoire.streams(), & &1.name)
      assert Catalog.lookup_stream("nobody.declares") == :miss
    end

    test "a planted provider's streams join it, and leave with it" do
      Catalog.with_providers([Probe], fn ->
        assert {:ok, {Probe, %{topic: :execution_events}}} = Catalog.lookup_stream("probe.deltas")
      end)

      assert Catalog.lookup_stream("probe.deltas") == :miss
    end

    test "one name declared by two providers refuses the table, naming the stream" do
      assert_raise RuntimeError, ~r/stream declarations failed.*probe\.deltas/s, fn ->
        Catalog.with_providers([Probe, Twin], fn -> :ok end)
      end

      assert Catalog.lookup_stream("probe.deltas") == :miss
      assert {:ok, _entry} = Catalog.lookup_stream("mcp_servers.changes")
    end

    test "a malformed declaration refuses the table" do
      assert_raise RuntimeError, ~r/stream declarations failed.*Malformed/s, fn ->
        Catalog.with_providers([Malformed], fn -> :ok end)
      end
    end

    test "the gate's stream entry names no bus" do
      code =
        "../../lib/grimoire/streams.ex"
        |> Path.expand(__DIR__)
        |> Prima.Test.SourceTree.code_lines()
        |> Enum.map_join("\n", &elem(&1, 0))

      assert code =~ "defmodule Grimoire.Streams"
      refute String.contains?(code, "Cyfr.Bus")
      refute String.contains?(code, "PubSub")
    end
  end

  describe "an admitted open" do
    test "answers a grant on the declared key and records one decision, closed as succeeded",
         %{ctx: ctx} do
      before = DateTime.utc_now()

      assert {:ok, %Prima.StreamGrant{} = grant} =
               Grimoire.open_stream(ctx, "mcp_servers.changes")

      assert grant.topic == :mcp_servers
      assert grant.projection == ["kind"]
      assert grant.subject == nil
      assert "sgr_" <> _ = grant.grant_id

      # The declared bound, from the open: a day.
      assert DateTime.diff(grant.deadline, before, :second) in 86_399..86_401

      assert [decision] = decisions(ctx)
      assert decision.tool == "stream:mcp_servers.changes"
      assert decision.admission == "admitted"
      assert decision.completion == "succeeded"
      assert decision.athanor_id == ctx.athanor_id

      assert [row] = rows(ctx)
      assert row.id == decision.call_id
      assert row.method == "streams/open"
      assert row.status == "success"
    end

    test "every open is a decision of its own", %{ctx: ctx} do
      assert {:ok, first} = Grimoire.open_stream(ctx, "mcp_servers.changes", nil)
      assert {:ok, second} = Grimoire.open_stream(ctx, "mcp_servers.changes", nil)
      refute first.grant_id == second.grant_id

      assert [a, b] = decisions(ctx)
      refute a.call_id == b.call_id
    end

    test "a subject the grammar admits is carried on the grant", %{ctx: ctx} do
      Catalog.with_providers([Probe], fn ->
        assert {:ok, grant} = Grimoire.open_stream(ctx, "probe.deltas", "exec_abc1")
        assert grant.subject == "exec_abc1"
        assert grant.topic == :execution_events
        assert grant.projection == ["seq", "delta"]
      end)
    end
  end

  describe "the grant's deadline" do
    test "is the credential's when the credential ends first", %{ctx: ctx} do
      credential = DateTime.add(DateTime.utc_now(), 30, :second)
      ctx = %{ctx | credential_deadline: credential}

      assert {:ok, grant} = Grimoire.open_stream(ctx, "mcp_servers.changes")
      assert grant.deadline == credential
    end

    test "is the stream's bound when the credential outlives it", %{ctx: ctx} do
      ctx = %{ctx | credential_deadline: DateTime.add(DateTime.utc_now(), 3_600, :second)}

      Catalog.with_providers([Probe], fn ->
        before = DateTime.utc_now()
        assert {:ok, grant} = Grimoire.open_stream(ctx, "probe.deltas", "exec_1")
        assert DateTime.diff(grant.deadline, before, :second) in 59..61
      end)
    end

    test "a credential already past its deadline opens nothing", %{ctx: ctx} do
      ctx = %{ctx | credential_deadline: DateTime.add(DateTime.utc_now(), -1, :second)}

      assert {:error, %Prima.Refusal{stage: :admission, class: :unauthenticated}} =
               Grimoire.open_stream(ctx, "mcp_servers.changes")

      assert_one_refusal(ctx, :unauthenticated)
    end

    test "a grant ends at its deadline" do
      now = DateTime.utc_now()

      grant = %Prima.StreamGrant{
        topic: :mcp_servers,
        projection: ["kind"],
        subject: nil,
        deadline: DateTime.add(now, 1, :second),
        grant_id: "sgr_x"
      }

      refute Prima.StreamGrant.expired?(grant, now)
      assert Prima.StreamGrant.expired?(grant, DateTime.add(now, 1, :second))
    end
  end

  describe "a refused open is one decision" do
    test "an undeclared stream, as an undeclared operation is refused", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{stage: :admission, class: :not_found} = refusal} =
               Grimoire.open_stream(ctx, "nobody.declares")

      assert refusal.message =~ "nobody.declares"
      decision = assert_one_refusal(ctx, :not_found)
      assert decision.tool == "stream:nobody.declares"
      assert [%{method: "streams/open", status: "error"}] = rows(ctx)
    end

    test "a subject the grammar does not admit, or none where one is required", %{ctx: ctx} do
      Catalog.with_providers([Probe], fn ->
        for subject <- ["exec_ABC", "exec_1\nx", "other", nil] do
          assert {:error, %Prima.Refusal{class: :invalid_argument}} =
                   Grimoire.open_stream(ctx, "probe.deltas", subject)
        end
      end)

      assert {:error, %Prima.Refusal{class: :invalid_argument}} =
               Grimoire.open_stream(ctx, "mcp_servers.changes", "a subject")

      assert length(decisions(ctx)) == 5
      assert Enum.all?(decisions(ctx), &(&1.refusal_class == "invalid_argument"))
    end

    test "a guest-planed context", %{ctx: ctx} do
      guest = Context.enter_guest(ctx)

      assert {:error, %Prima.Refusal{stage: :admission, class: :forbidden}} =
               Grimoire.open_stream(guest, "mcp_servers.changes")

      assert_one_refusal(ctx, :forbidden)
    end

    test "a member that lost its slot", %{ctx: ctx} do
      Arca.ControlPlane.record(:lost)

      assert {:error, %Prima.Refusal{class: :not_owner, reason: :control_plane_lost}} =
               Grimoire.open_stream(ctx, "mcp_servers.changes")

      Arca.ControlPlane.record(:unclaimed)
      assert_one_refusal(ctx, :not_owner)
    end

    test "a caller that is not signed in", %{ctx: ctx} do
      ctx = %{ctx | authenticated: false}

      assert {:error, %Prima.Refusal{class: :unauthenticated}} =
               Grimoire.open_stream(ctx, "mcp_servers.changes")

      assert_one_refusal(ctx, :unauthenticated)
    end

    test "a caller in no athanor, which has no topic to be granted", %{ctx: ctx} do
      ctx = %{ctx | athanor_id: nil}

      assert {:error, %Prima.Refusal{class: :unauthenticated, reason: :no_athanor}} =
               Grimoire.open_stream(ctx, "mcp_servers.changes")

      # No tenant to file a row under: the decision alone.
      assert_one_refusal(ctx, :unauthenticated)
      assert rows(ctx) == []
    end
  end
end
