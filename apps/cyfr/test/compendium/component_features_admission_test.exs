# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentFeaturesAdmissionTest do
  @moduledoc """
  A component that uses a feature the runtime refuses
  (`Prima.ComponentFeatures`) is never stored as runnable: a publish and a
  registration from the stored tree both refuse it, leaving no row and,
  for a publish, no bytes, in a sentence naming its digest; the twin that
  uses none is admitted. Every component committed to this tree passes
  the same check, except the hostile guests that use a refused feature on
  purpose. That the runtime refuses one again before compiling it is
  `Locus.Runtime.ComponentFeaturesTest`'s.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Compendium.Registry

  @root Path.expand("../../../..", __DIR__)
  @hostile Path.join(@root, "apps/locus/test/support/runtime/test_wasm/hostile")
  @refused ~w(async_lift gc_alloc exception_throw externref_table)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    dir = Path.join(System.tmp_dir!(), "cyfr_features_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, dir)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, base)
      File.rm_rf!(dir)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp guest(name), do: File.read!(Path.join(@hostile, "#{name}.wasm"))

  defp sentence(digest),
    do:
      "The component #{digest} uses a WebAssembly feature this runtime does not admit: " <>
        "component-model async, GC or exception handling."

  test "a publish refuses a component using a refused feature, and stores nothing of it",
       %{ctx: ctx} do
    for name <- @refused do
      bytes = guest(name)
      digest = Prima.Digest.sha256(bytes)
      metadata = %{name: String.replace(name, "_", "-"), version: "1.0.0", type: "reagent"}

      capture_log(fn ->
        assert Registry.publish_bytes(ctx, bytes, metadata) ==
                 {:error, {:component_feature_refused, digest}}
      end)

      assert {:error, _} = Registry.get(ctx, metadata.name, "1.0.0")
      assert {:error, _} = Registry.get_blob(ctx, digest)

      assert {:error, _} =
               Arca.get(Sanctum.Context.actor(ctx), [
                 "components",
                 "reagents",
                 "local",
                 metadata.name,
                 "1.0.0",
                 "reagent.wasm"
               ])

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               Prima.Refusal.classify({:component_feature_refused, digest})

      assert message == sentence(digest)
    end

    assert {:ok, %{digest: digest}} =
             Registry.publish_bytes(ctx, guest("sync_lift"), %{
               name: "sync-lift",
               version: "1.0.0",
               type: "reagent"
             })

    assert digest == Prima.Digest.sha256(guest("sync_lift"))
  end

  test "a registration from the stored tree refuses it and leaves no row", %{ctx: ctx} do
    bytes = guest("async_lift")
    segments = ["components", "reagents", "local", "async-lift", "0.1.0"]
    dir = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), segments)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "0.1.0"})
    )

    File.write!(Path.join(dir, "reagent.wasm"), bytes)

    capture_log(fn ->
      assert Registry.register_from_arca(ctx, segments) ==
               {:error, {:component_feature_refused, Prima.Digest.sha256(bytes)}}
    end)

    assert {:error, _} = Registry.get(ctx, "async-lift", "0.1.0")
  end

  test "every committed component passes, except the guests that use a refused feature" do
    # The list is every `.wasm` git tracks here, read from the tree, and
    # the two agree, so a component added anywhere is checked.
    found =
      @root
      |> Path.join("**/*.wasm")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, ["/deps/", "/_build/", "/node_modules/", "/_tools/"]))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    {tracked, 0} = System.cmd("git", ["-C", @root, "ls-files", "*.wasm"])
    assert found == tracked |> String.split("\n", trim: true) |> Enum.sort()

    refused =
      for path <- found, Path.basename(path, ".wasm") in @refused, do: path

    assert length(refused) == length(@refused)

    for path <- found, path not in refused do
      assert Prima.ComponentFeatures.check(File.read!(Path.join(@root, path))) == :ok, path
    end

    capture_log(fn ->
      for path <- refused do
        assert {:error, {:component_feature_refused, _digest}} =
                 Prima.ComponentFeatures.check(File.read!(Path.join(@root, path))),
               path
      end
    end)
  end
end
