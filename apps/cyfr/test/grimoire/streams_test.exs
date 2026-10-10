# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.StreamsTest do
  @moduledoc """
  The gate's stream entry: a declared stream is admitted once, recorded
  once, and answered with a grant bounded by the stream's declaration and
  the caller's credential; an undeclared stream, a subject its grammar
  does not admit, a credential that has ended and every caller the gate
  refuses an operation are refused, each as one decision. A filtering
  stream opens for a frame alone, and a stream that declares a shape opens
  for a frame only when the frame's version reads as a canvas: one
  registry read through the component-facts port, made after every check
  of the caller, and any other answer refuses. The table the providers
  declare is the only source, and the gate names no bus.
  """

  # Plants providers into the operation table, flips the member's slot
  # and installs component facts of its own.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Grimoire.Catalog
  alias Sanctum.Consent.Components
  alias Sanctum.Context

  # The component domain's facts, each registry row read reported to the
  # process that made it.
  defmodule CountedFacts do
    @moduledoc false
    @behaviour Sanctum.Consent.Components

    @impl true
    def get_component(ctx, name, version, publisher, type) do
      send(self(), {:component_read, {name, version, publisher, type}})
      Compendium.ConsentFacts.get_component(ctx, name, version, publisher, type)
    end

    @impl true
    defdelegate resolve(ctx, row), to: Compendium.ConsentFacts

    @impl true
    defdelegate resolve_verified(ctx, row), to: Compendium.ConsentFacts

    @impl true
    defdelegate agent_rows(ctx), to: Compendium.ConsentFacts

    @impl true
    defdelegate shipped_nodes(ctx, rows), to: Compendium.ConsentFacts

    @impl true
    defdelegate newer_shipped(ctx, row), to: Compendium.ConsentFacts

    @impl true
    defdelegate tincture_placement(ctx, row), to: Compendium.ConsentFacts
  end

  # The component domain's facts, but for the optional placement, which
  # this implementation does not answer.
  defmodule FactsWithoutPlacement do
    @moduledoc false
    @behaviour Sanctum.Consent.Components

    @impl true
    defdelegate resolve(ctx, row), to: Compendium.ConsentFacts

    @impl true
    defdelegate resolve_verified(ctx, row), to: Compendium.ConsentFacts

    @impl true
    defdelegate get_component(ctx, name, version, publisher, type), to: Compendium.ConsentFacts

    @impl true
    defdelegate agent_rows(ctx), to: Compendium.ConsentFacts

    @impl true
    defdelegate shipped_nodes(ctx, rows), to: Compendium.ConsentFacts

    @impl true
    defdelegate newer_shipped(ctx, row), to: Compendium.ConsentFacts
  end

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

  defmodule Held do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "held"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams do
      [
        %Prima.Provider.Stream{
          name: "held.confirmations",
          topic: :confirmations,
          projection: ["ref"],
          subject: ~S"\A[A-Za-z0-9|_-]{1,64}\z",
          bind: :holder,
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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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

  # A frame's context, as the frame-credential path establishes one, for
  # the version `name` 1.0.0 of the local publisher.
  defp framed(ctx, name) do
    %{
      ctx
      | auth_method: :tincture,
        origin: :interactive,
        frame: %{
          id: "frc_streams",
          frame_id: "frm_streams",
          reference: %{publisher: "local", name: name, version: "1.0.0"},
          version_digest: "sha256:" <> String.duplicate("a", 64),
          grant_revision: 0,
          mode: :live
        }
    }
  end

  # A tincture version written as the registry holds one, past the publish
  # check, as a version installed before a rules change stands.
  defp tincture_row!(ctx, name, tincture) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => tincture
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    name
  end

  # A canvas reading both canvas-readable streams, one feed by its name.
  defp canvas_row!(ctx, name) do
    tincture_row!(ctx, name, %{
      "frame" => %{"placement" => "canvas"},
      "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
      "streams" => [%{"name" => "runs.changes"}, %{"name" => "feed.results", "subject" => "btc"}]
    })
  end

  # Runs `fun` with `facts` as the component-facts port, restoring the
  # installed one however `fun` ends.
  defp with_facts(facts, fun) do
    real = Components.impl!()
    Components.install!(facts)

    try do
      fun.()
    after
      Components.install!(real)
    end
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

  describe "a stream bound to its holder" do
    test "takes the holder's own user id when the open names no subject", %{ctx: ctx} do
      Catalog.with_providers([Held], fn ->
        assert {:ok, grant} = Grimoire.open_stream(ctx, "held.confirmations")
        assert grant.subject == ctx.user_id
        assert grant.topic == :confirmations

        # Naming one's own id is the same grant's subject.
        assert {:ok, %{subject: subject}} =
                 Grimoire.open_stream(ctx, "held.confirmations", ctx.user_id)

        assert subject == ctx.user_id
      end)
    end

    test "refuses another person's id as the subject, as a subject it does not take",
         %{ctx: ctx} do
      Catalog.with_providers([Held], fn ->
        assert {:error, %Prima.Refusal{class: :invalid_argument, message: message}} =
                 Grimoire.open_stream(ctx, "held.confirmations", "usr_someone_else")

        assert message == "The stream held.confirmations does not take that subject"
      end)

      assert_one_refusal(ctx, :invalid_argument)
    end

    test "refuses a holder that names no person", %{ctx: ctx} do
      nobody = %{ctx | user_id: nil}

      Catalog.with_providers([Held], fn ->
        assert {:error, %Prima.Refusal{class: :invalid_argument, message: message}} =
                 Grimoire.open_stream(nobody, "held.confirmations")

        assert message =~ "names no person"
      end)
    end

    test "the confirmation stream is declared bound to its holder" do
      assert {:ok, {Sanctum.Provider, stream}} = Catalog.lookup_stream("confirmation.changes")
      assert Prima.Provider.Stream.holder_bound?(stream)
      assert stream.topic == :confirmations
      assert stream.projection == ["ref", "kind", "operation", "expires_at"]
    end
  end

  describe "a filtering stream" do
    test "opens for a canvas's frame, its subject on the grant and the feeds topic its key", %{
      ctx: ctx
    } do
      canvas = canvas_row!(ctx, "home-canvas")

      assert {:ok, %Prima.StreamGrant{} = grant} =
               Grimoire.open_stream(framed(ctx, canvas), "feed.results", "btc")

      assert grant.topic == :feeds
      assert grant.subject == "btc"

      assert grant.projection ==
               ~w(binding feed revision at result label actions)

      assert [%{admission: "admitted"}] = decisions(ctx)
    end

    test "is refused for a session, an MCP key and a paired device, before anything else", %{
      ctx: ctx
    } do
      callers = [
        session: %{ctx | auth_method: :session, origin: :interactive},
        mcp_key: %{
          ctx
          | auth_method: :api_key,
            api_key_id: "key_streams",
            api_key_type: :application,
            origin: :programmatic
        },
        device: %{ctx | auth_method: :device, client_id: "cli_streams", origin: :interactive}
      ]

      for {who, caller} <- callers do
        assert {:error,
                %Prima.Refusal{
                  class: :forbidden,
                  reason: :canvas_stream,
                  stage: :admission,
                  message: message
                }} = Grimoire.open_stream(caller, "feed.results", "btc"),
               "#{who} opened feed.results"

        assert message =~ "feed.results"
        assert message =~ "(canvas_stream)"
      end

      # Each refusal is one decision, and a stream that declares a shape
      # but does not filter still opens for each of them, with no registry
      # read: a context without a frame is no frame's to judge.
      assert length(decisions(ctx)) == 3
      assert Enum.all?(decisions(ctx), &(&1.refusal_class == "forbidden"))

      with_facts(CountedFacts, fn ->
        for {who, caller} <- callers do
          assert {:ok, %{topic: :executions}} = Grimoire.open_stream(caller, "runs.changes"),
                 "#{who} was refused runs.changes"
        end
      end)

      refute_received {:component_read, _}
    end
  end

  describe "a stream that declares a shape" do
    test "opens for a canvas's frame, both streams, with one registry read each", %{ctx: ctx} do
      canvas = canvas_row!(ctx, "home-canvas")

      with_facts(CountedFacts, fn ->
        assert {:ok, %{topic: :feeds, subject: "btc"}} =
                 Grimoire.open_stream(framed(ctx, canvas), "feed.results", "btc")

        assert_received {:component_read, {"home-canvas", "1.0.0", "local", "tincture"}}
        refute_received {:component_read, _}

        assert {:ok, %{topic: :executions}} =
                 Grimoire.open_stream(framed(ctx, canvas), "runs.changes")

        assert_received {:component_read, {"home-canvas", "1.0.0", "local", "tincture"}}
        refute_received {:component_read, _}
      end)

      assert [%{admission: "admitted"}, %{admission: "admitted"}] = decisions(ctx)
    end

    test "is refused for a frame whose version is a floating tincture, one decision each", %{
      ctx: ctx
    } do
      # Installed straight in the registry, so the rules never ran on it.
      floating =
        tincture_row!(ctx, "float-feeds", %{
          "frame" => %{"placement" => "float"},
          "entry" => "index.html",
          "streams" => [
            %{"name" => "feed.results", "subject" => "btc"},
            %{"name" => "runs.changes"}
          ]
        })

      # Its placement reads, and is not a canvas.
      {:ok, row} = Components.get_component(ctx, floating, "1.0.0", "local", "tincture")
      assert Components.tincture_placement(ctx, row) == {:ok, "float"}

      for {name, subject} <- [{"feed.results", "btc"}, {"runs.changes", nil}] do
        assert {:error,
                %Prima.Refusal{
                  class: :forbidden,
                  reason: :canvas_stream,
                  stage: :admission,
                  message: message
                }} = Grimoire.open_stream(framed(ctx, floating), name, subject),
               "a floating tincture's frame opened #{name}"

        assert message ==
                 "The stream #{name} declares a shape, and a frame opens it only when " <>
                   "the frame's version reads as a canvas (canvas_stream)"
      end

      assert [refused, refused_too] = decisions(ctx)

      for decision <- [refused, refused_too] do
        assert decision.admission == "refused"
        assert decision.refusal_class == "forbidden"
        assert decision.reason =~ "(canvas_stream)"
      end

      assert Enum.sort([refused.tool, refused_too.tool]) ==
               ["stream:feed.results", "stream:runs.changes"]
    end

    test "is refused for a frame whose reference names no row, or a declaration the rules refuse",
         %{ctx: ctx} do
      # Written past the publish check: a placement the rules no longer
      # name is no canvas, whatever it once was.
      refused =
        tincture_row!(ctx, "desk-dash", %{
          "frame" => %{"placement" => "desktop"},
          "entry" => "index.html",
          "streams" => [%{"name" => "runs.changes"}]
        })

      {:ok, row} = Components.get_component(ctx, refused, "1.0.0", "local", "tincture")
      assert Components.tincture_placement(ctx, row) == {:error, :refused}

      assert {:error, :not_found} =
               Components.get_component(ctx, "nobody-installed", "1.0.0", "local", "tincture")

      for name <- ["nobody-installed", refused],
          {stream, subject} <- [{"feed.results", "btc"}, {"runs.changes", nil}] do
        assert {:error, %Prima.Refusal{class: :forbidden, reason: :canvas_stream}} =
                 Grimoire.open_stream(framed(ctx, name), stream, subject),
               "#{name}'s frame opened #{stream}"
      end

      assert length(decisions(ctx)) == 4
      assert Enum.all?(decisions(ctx), &(&1.admission == "refused"))
    end

    test "is refused while the frame's placement cannot be read", %{ctx: ctx} do
      canvas = canvas_row!(ctx, "home-canvas")

      with_facts(FactsWithoutPlacement, fn ->
        assert {:error, %Prima.Refusal{class: :forbidden, reason: :canvas_stream}} =
                 Grimoire.open_stream(framed(ctx, canvas), "runs.changes")
      end)

      # With the placement answered again, the same frame opens it.
      assert {:ok, %{topic: :executions}} =
               Grimoire.open_stream(framed(ctx, canvas), "runs.changes")
    end

    test "reads no row for a caller refused by an earlier check", %{ctx: ctx} do
      canvas = canvas_row!(ctx, "home-canvas")
      frame = framed(ctx, canvas)

      refused = [
        guest: {Context.enter_guest(frame), :forbidden},
        signed_out: {%{frame | authenticated: false}, :unauthenticated},
        no_athanor: {%{frame | athanor_id: nil}, :unauthenticated},
        ended:
          {%{frame | credential_deadline: DateTime.add(DateTime.utc_now(), -1)}, :unauthenticated}
      ]

      with_facts(CountedFacts, fn ->
        for {who, {caller, class}} <- refused do
          assert {:error, %Prima.Refusal{class: ^class}} =
                   Grimoire.open_stream(caller, "runs.changes"),
                 "#{who} was not refused"
        end

        # A subject the stream does not take is refused before the read too.
        assert {:error, %Prima.Refusal{class: :invalid_argument}} =
                 Grimoire.open_stream(frame, "feed.results", "BTC:usd")

        Arca.ControlPlane.record(:lost)

        assert {:error, %Prima.Refusal{class: :not_owner}} =
                 Grimoire.open_stream(frame, "runs.changes")

        Arca.ControlPlane.record(:unclaimed)
      end)

      refute_received {:component_read, _}
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
