# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeCachePublicationWindowTest do
  @moduledoc """
  A completed registry sweep must keep an older derivation from publishing
  its shape to a later reader, including the interval before the deriver
  checks its epoch again.

  The case instruments the loaded ShapeDerivation with one process-local
  pause immediately after its cache insertion. It changes no decision,
  key, value, epoch or cache operation, and restores the original BEAM.
  Only this synchronous module's marked reader pauses; the second reader
  follows the ordinary version_digest cache-hit path.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Components, ShapeDerivation, ShapeDigest}

  defmodule ParkedFacts do
    @behaviour Sanctum.Consent.Components

    for {name, arity} <- Components.behaviour_info(:callbacks), name != :resolve do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(Compendium.ConsentFacts, unquote(name), [unquote_splicing(args)])
    end

    def resolve(ctx, row) do
      answer = Compendium.ConsentFacts.resolve(ctx, row)

      if parent = Process.delete(:park_old_closure) do
        send(parent, {:old_closure_read, self()})

        receive do
          :release_old_closure -> :ok
        after
          10_000 -> raise "old closure reader not released"
        end
      end

      answer
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "shape_window_#{System.unique_integer([:positive])}")
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

  test "after publication finishes, a reader cannot see an old shape before its deriver checks the epoch",
       %{ctx: ctx} do
    instrument_post_put!()
    n = System.unique_integer([:positive])
    leaf = "window-leaf-#{n}"
    root = "window-root-#{n}"
    source = "formula:local.#{root}"

    publish!(ctx, "reagent", leaf, "1.0.0", %{})

    publish!(ctx, "formula", root, "1.0.0", %{
      "dependencies" => %{"static" => [%{"ref" => "reagent:local.#{leaf}"}]}
    })

    {:ok, old_input} = ShapeDerivation.shape_input(ctx, source, "1.0.0")
    {:ok, old_digest} = ShapeDigest.compute(old_input)
    Compendium.Registry.invalidate_executor_caches(ctx)
    Components.install!(ParkedFacts)
    parent = self()

    reader =
      Task.async(fn ->
        Process.put(:park_old_closure, parent)
        Process.put(:shape_cache_after_put, parent)
        ShapeDerivation.version_digest(ctx, source, "1.0.0")
      end)

    on_exit(fn ->
      if Process.alive?(reader.pid), do: Process.exit(reader.pid, :kill)
    end)

    assert_receive {:old_closure_read, parked}, 5_000

    # Real publication, including its epoch advance and cache sweep, has
    # finished before the old reader is allowed to store anything.
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

    {:ok, fresh_input} = ShapeDerivation.shape_input(ctx, source, "1.0.0")
    {:ok, fresh_digest} = ShapeDigest.compute(fresh_input)
    refute fresh_digest == old_digest

    send(parked, :release_old_closure)
    assert_receive {:shape_cache_stored, ^parked, key, ^old_digest}, 5_000

    try do
      # The pause is after the real cache insertion, not before it.
      assert {:ok, {_epoch, ^old_digest}} = Arca.Cache.get(key)

      # This read starts after publication completed. A later check by
      # the older reader cannot retract a stale grant this read consumed.
      assert ShapeDerivation.version_digest(ctx, source, "1.0.0") == {:ok, fresh_digest}
    after
      send(parked, :finish_shape_cache_store)
      assert Task.await(reader, 5_000) == {:ok, old_digest}
    end
  end

  defp instrument_post_put! do
    module = ShapeDerivation
    {^module, original_beam, beam_file} = :code.get_object_code(module)
    original_options = Code.compiler_options()

    # Register restoration before either compiler options or loaded code
    # are changed; the reader's later cleanup runs before this callback.
    on_exit(fn ->
      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, beam_file, original_beam)
      Code.compiler_options(Map.to_list(original_options))
    end)

    source_file = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
    source = File.read!(source_file)
    insertion = "    Arca.Cache.Epoch.put(key, epoch, digest, @live_cache_ttl_ms)"
    assert length(String.split(source, insertion)) == 2, "post-put instrumentation site moved"

    pause = """
          if parent = Process.delete(:shape_cache_after_put) do
            send(parent, {:shape_cache_stored, self(), key, digest})

            receive do
              :finish_shape_cache_store -> :ok
            after
              10_000 -> raise "post-put shape reader not released"
            end
          end
    """

    instrumented = String.replace(source, insertion, insertion <> "\n" <> pause)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [{^module, _instrumented_beam}] = Code.compile_string(instrumented, source_file)
    after
      Code.compiler_options(Map.to_list(original_options))
    end
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
        wasm: Cyfr.Test.Guests.wasm(type)
      )

    row
  end
end
