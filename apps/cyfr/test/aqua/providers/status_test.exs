# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.StatusTest do
  @moduledoc """
  The stream `system.changes`: its declaration, and its refresh read as a
  canvas reads it (projected by the grant, passed through JSON and held to
  the declared shape), each field from its one source: the reserve's
  latch and the gate's own `system.status` for the health, the athanor's
  bytes and cap, the soul's and the crew's brains on an athanor filled
  from the shipped seed, the build's version and the release channel.
  """

  # The storage reserve's latch is the node's, a platform setting is
  # cached per node, and the status watch is the named one.
  use ExUnit.Case, async: false

  alias Aqua.Providers.Status, as: Provider
  alias Cyfr.Bus
  alias Prima.Canvas.Shape
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @stream "system.changes"
  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul_brain "catalyst:local.claude"

  setup tags do
    on_exit(fn -> Arca.StorageReserve.put(:ok) end)
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id, origin: :interactive}
    segments = Arca.Storage.physical_segments(Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    on_exit(fn -> File.rm_rf!(tree) end)

    # The shipped catalysts and crew are read from the repository's seed
    # tree; the suite's own carries none.
    Prima.Test.Env.put_app_env(:arca, :seed_path, @seed_root)
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

    # The refresh hands the athanor to the watch; the suite's boot starts none.
    start_supervised!(Aqua.Status)
    {:ok, ctx: ctx}
  end

  describe "the declaration" do
    test "is one canvas-readable stream on the system topic, refreshed, with no subject" do
      assert [stream] = Provider.streams()
      assert Prima.Provider.Stream.valid?(stream)
      assert stream.name == @stream
      assert stream.topic == :system

      assert stream.projection ==
               ~w(kind health storage_used storage_cap model_connected crew_ready crew_total version update_available revision at)

      # One item, the status, and its picture read again every five minutes.
      assert {stream.key, stream.removal, stream.reread, stream.stale_after} ==
               {nil, nil, [], 300}

      assert {stream.subject, stream.bind, stream.filter} == {nil, nil, nil}
      assert stream.deadline_bound == 86_400
      assert Bus.grantable?(stream.topic, false)

      assert {:ok, stream.shape} == Shape.validate(stream.shape)
      assert Enum.sort(Map.keys(stream.shape["fields"])) == Enum.sort(stream.projection)
      assert Enum.sort(stream.shape["required"]) == Enum.sort(stream.projection)
      assert :ok = Shape.check(stream.shape, Shape.fixture(stream.shape))

      # The payload's own fields, in the projection's order, then the
      # delivery fields.
      assert stream.projection ==
               ["kind" | Enum.map(Bus.SystemStatus.fields(), &Atom.to_string/1)] ++
                 Prima.Provider.Stream.delivery_fields()

      fields = stream.shape["fields"]
      assert fields["kind"]["values"] == ["changed"]
      assert fields["health"]["values"] == ["ok", "degraded", "low_storage"]
      assert fields["version"]["nullable"] == false

      for field <- Enum.reject(stream.projection, &(&1 in ["kind", "version", "revision", "at"])),
          do: assert(fields[field]["nullable"] == true, field)

      assert {Provider, :status} = stream.refresh
      assert function_exported?(Provider, :status, 2)
      assert {:ok, {Provider, ^stream}} = Sanctum.Catalog.lookup_stream(@stream)
      assert Provider.tools() == []
      assert Provider.service() == "aqua"
      assert Provider in Sanctum.Catalog.configured_providers()
    end

    test "the gate opens it on the athanor's own system topic", %{ctx: ctx} do
      assert {:ok, grant} = Sanctum.Gate.open_stream(ctx, @stream)
      assert grant.topic == :system
      assert Bus.granted_topic(Context.actor(ctx), grant) == Bus.system(Context.actor(ctx))
    end
  end

  describe "the refresh" do
    test "is one whole status, each field from its source", %{ctx: ctx} do
      assert [status] = refreshed(ctx)

      {:ok, bytes} = Arca.Usage.athanor_bytes(Context.actor(ctx))
      {:ok, %{status: gate}} = Aqua.Ops.call_tool("system", ctx, %{"action" => "status"})

      assert status == %{
               "kind" => "changed",
               "health" => if(gate == "ok", do: "ok", else: "degraded"),
               "storage_used" => bytes,
               "storage_cap" => nil,
               # The shipped soul's brain has no key bound, nor has any
               # shipped crew member's.
               "model_connected" => false,
               "crew_ready" => 0,
               "crew_total" => 3,
               "version" => Prima.Version.current(),
               # The suite's release channel never reads.
               "update_available" => nil
             }
    end

    test "names the athanor storage cap once one is set", %{ctx: ctx} do
      Cyfr.Test.Settings.put("athanor_storage_bytes", 1_000_000)
      assert [%{"storage_cap" => 1_000_000}] = refreshed(ctx)
    end

    test "reads low_storage while the reserve is spent", %{ctx: ctx} do
      Arca.StorageReserve.put(:depleted)
      assert [%{"health" => "low_storage"}] = refreshed(ctx)

      Arca.StorageReserve.put(:ok)
      assert [%{"health" => health}] = refreshed(ctx)
      assert health in ["ok", "degraded"]
    end

    test "reads the soul connected once its brain's key is bound, and a member ready once its is",
         %{ctx: ctx} do
      ConsentFixtures.bind_key!(ctx, @soul_brain, %{"ANTHROPIC_API_KEY" => "sk-test"},
        origins: [:interactive, :programmatic]
      )

      assert [%{"model_connected" => true, "crew_ready" => 0, "crew_total" => 3}] =
               refreshed(ctx)

      # The explorer's brain.
      ConsentFixtures.bind_key!(ctx, "catalyst:local.gemini", %{"GEMINI_API_KEY" => "g-test"},
        origins: [:interactive, :programmatic]
      )

      assert [%{"model_connected" => true, "crew_ready" => 1, "crew_total" => 3}] =
               refreshed(ctx)

      # The same counts the crew index names.
      {:ok, roster} = Aqua.AgentConfig.roster(ctx)
      assert {:ok, [%{"name" => "explorer"}]} = Aqua.Crew.index(ctx, roster)
    end

    test "leaves the brains unread when they cannot be read, and answers the rest", %{ctx: ctx} do
      guest = Context.enter_guest(ctx)
      assert {:error, {:unavailable, _}} = Aqua.Crew.brains(guest)

      assert [
               %{
                 "model_connected" => nil,
                 "crew_ready" => nil,
                 "crew_total" => nil,
                 "version" => version
               }
             ] = refreshed(guest)

      assert version == Prima.Version.current()
    end

    test "answers a context with no athanor no status", %{ctx: ctx} do
      assert {:error, :no_athanor} = Provider.status(%{ctx | athanor_id: nil}, nil)
    end
  end

  # The refresh as a canvas reads it.
  defp refreshed(ctx) do
    {:ok, items} = Provider.status(ctx, nil)
    Enum.map(items, &read_as/1)
  end

  # A status as a canvas reads it, held to the shape, its delivery fields
  # (its revision, its time in microseconds) checked and set aside.
  defp read_as(payload) do
    {:ok, {Provider, stream}} = Sanctum.Catalog.lookup_stream(@stream)

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: nil,
      deadline: DateTime.utc_now(),
      grant_id: "sgr_system"
    }

    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    {:ok, at, 0} = DateTime.from_iso8601(data["at"])
    assert data["revision"] == DateTime.to_unix(at, :microsecond)
    Map.drop(data, ~w(revision at))
  end
end
