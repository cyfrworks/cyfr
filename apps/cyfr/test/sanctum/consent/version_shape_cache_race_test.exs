# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.VersionShapeCacheRaceTest do
  @moduledoc """
  A version's shape derived from a closure the registry changed before
  the derivation stored it is not kept: the next read derives the closure
  as it stands.
  """

  use ExUnit.Case, async: false
  alias Sanctum.Consent.{Components, ShapeDerivation, ShapeDigest}

  defmodule ParkedFacts do
    @behaviour Sanctum.Consent.Components
    for {name, arity} <- Sanctum.Consent.Components.behaviour_info(:callbacks),
        name != :resolve do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(Compendium.ConsentFacts, unquote(name), [unquote_splicing(args)])
    end

    def resolve(ctx, row) do
      answer = Compendium.ConsentFacts.resolve(ctx, row)

      if parent = Process.delete(:park_shape_reply) do
        send(parent, {:old_closure_read, self()})

        receive do
          :release_shape -> :ok
        after
          10_000 -> raise "shape reader not released"
        end
      end

      answer
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base =
      Path.join(System.tmp_dir!(), "version_shape_race_#{System.unique_integer([:positive])}")

    previous = Application.fetch_env(:arca, :base_path)
    implementation = Components.impl!()

    on_exit(fn ->
      Components.install!(implementation)

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

  test "a shape read finishing after dependency publication cannot repopulate an invalidated shape",
       %{ctx: ctx} do
    n = System.unique_integer([:positive])
    leaf = "shape-leaf-#{n}"
    root = "shape-root-#{n}"
    source = "formula:local.#{root}"
    publish!(ctx, "reagent", leaf, "1.0.0", %{})

    publish!(ctx, "formula", root, "1.0.0", %{
      "dependencies" => %{"static" => [%{"ref" => "reagent:local.#{leaf}"}]}
    })

    {:ok, before_input} = ShapeDerivation.shape_input(ctx, source, "1.0.0")
    {:ok, before_digest} = ShapeDigest.compute(before_input)
    Compendium.Registry.invalidate_executor_caches(ctx)
    Components.install!(ParkedFacts)
    parent = self()

    reader =
      Task.async(fn ->
        Process.put(:park_shape_reply, parent)
        ShapeDerivation.version_digest(ctx, source, "1.0.0")
      end)

    assert_receive {:old_closure_read, parked}, 5_000
    # A real publish runs the registry's invalidation before answering.
    publish!(ctx, "reagent", leaf, "1.0.1", %{
      "needs" => %{
        "key" => %{"type" => "api_key:example.com", "reason" => "new need", "fields" => ["TOKEN"]}
      }
    })

    send(parked, :release_shape)
    assert {:ok, ^before_digest} = Task.await(reader, 5_000)
    {:ok, fresh_input} = ShapeDerivation.shape_input(ctx, source, "1.0.0")
    {:ok, fresh_digest} = ShapeDigest.compute(fresh_input)
    refute fresh_digest == before_digest
    assert {:ok, fresh_digest} == ShapeDerivation.version_digest(ctx, source, "1.0.0")
  end

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
        wasm: File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
      )

    row
  end
end
