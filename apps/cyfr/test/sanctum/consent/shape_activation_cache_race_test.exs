# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeActivationCacheRaceTest do
  @moduledoc """
  A shape read that starts after publication cannot derive the old closure
  from an activation cache refilled by a resolver that started before it.

  The activation's existing synchronous telemetry event runs after its
  uncached walk and before its cache write. Parking one marked resolver
  there changes neither production code nor cache contents directly.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.{ShapeDerivation, ShapeDigest}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base =
      Path.join(System.tmp_dir!(), "activation_shape_#{System.unique_integer([:positive])}")

    previous = Application.fetch_env(:arca, :base_path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arca, :base_path, value)
        :error -> Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, base)
    Cyfr.Test.SeedBundle.isolate!()
    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  test "a new shape read after publication refuses an old activation refilled after the sweep",
       %{ctx: ctx} do
    n = System.unique_integer([:positive])
    leaf = "activation-leaf-#{n}"
    root = "activation-root-#{n}"
    source = "formula:local.#{root}"
    publish!(ctx, "reagent", leaf, "1.0.0", %{})

    root_row =
      publish!(ctx, "formula", root, "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.#{leaf}"}]}
      })

    {:ok, old_input} = ShapeDerivation.shape_input(ctx, source, "1.0.0")
    {:ok, old_digest} = ShapeDigest.compute(old_input)
    Compendium.Registry.invalidate_executor_caches(ctx)

    handler = {__MODULE__, n}
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :compendium, :activation, :resolve],
        &__MODULE__.park_resolver/4,
        %{source: source, parent: self()}
      )

    resolver =
      Task.async(fn ->
        Process.put(:park_activation_cache, true)
        Compendium.Activation.resolve(ctx, root_row)
      end)

    on_exit(fn ->
      if Process.alive?(resolver.pid), do: Process.exit(resolver.pid, :kill)
    end)

    assert_receive {:old_activation_walked, parked}, 5_000

    # Publication and all its cache invalidation complete while the old
    # activation waits to write the graph it already read.
    publish!(ctx, "reagent", leaf, "1.0.1", %{
      "needs" => %{
        "key" => %{
          "type" => "api_key:example.com",
          "hosts" => ["api.example.com"],
          "reason" => "new need",
          "fields" => ["TOKEN"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    })

    # Read the new world before the old resolver resumes. shape_input does
    # not fill the shape cache; it also proves the publication is visible.
    {:ok, fresh_input} = ShapeDerivation.shape_input(ctx, source, "1.0.0")
    {:ok, fresh_digest} = ShapeDigest.compute(fresh_input)
    refute fresh_digest == old_digest

    send(parked, :finish_activation_cache)
    assert {:ok, old_activation} = Task.await(resolver, 5_000)

    activation_key =
      Arca.Cache.Keys.activation(
        Sanctum.Context.actor(ctx),
        source,
        root_row.release_digest
      )

    assert {:ok, {_epoch, ^old_activation}} = Arca.Cache.get(activation_key)

    # This ordinary read starts after publication and after the older
    # resolver finished. Its new epoch must not legitimize that old graph.
    assert ShapeDerivation.version_digest(ctx, source, "1.0.0") == {:ok, fresh_digest}
  end

  def park_resolver(
        _event,
        _measurements,
        %{node_key: source, cached: false},
        %{source: source, parent: parent}
      ) do
    if Process.delete(:park_activation_cache) do
      send(parent, {:old_activation_walked, self()})

      receive do
        :finish_activation_cache -> :ok
      after
        10_000 -> raise "old activation resolver not released"
      end
    end
  end

  def park_resolver(_event, _measurements, _metadata, _config), do: :ok

  defp publish!(ctx, type, name, version, extra) do
    manifest =
      Map.merge(extra, %{
        "name" => name,
        "type" => type,
        "version" => version,
        "publisher" => "local"
      })

    {:ok, row} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, type, "local", name, version,
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm(type)
      )

    row
  end
end
