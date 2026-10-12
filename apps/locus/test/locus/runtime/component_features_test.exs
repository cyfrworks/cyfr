# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ComponentFeaturesTest do
  @moduledoc """
  A component that uses a feature the runtime refuses
  (`Prima.ComponentFeatures`) is refused before it is compiled, on the
  cached path and the uncached one alike, in the sentence admission
  answers, and nothing compiled of it is cached; one that uses none runs.
  Each refused guest is valid WebAssembly with every feature on and uses
  one feature, so its refusal is that feature's, which the log line names;
  `sync_lift` is `async_lift` without its async lift and is admitted. The
  guests are `test_wasm/hostile/`, each held to the digest its README
  records by `Locus.Runtime.StoreLimitsTest`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Locus.Runtime.Engine

  @dir Path.expand("../../support/runtime/test_wasm/hostile", __DIR__)

  # Each refused guest and the family its log line names.
  @refused [
    {"async_lift", "async"},
    {"gc_alloc", "gc"},
    {"exception_throw", "exceptions"},
    {"externref_table", "gc"}
  ]

  defp guest(name), do: File.read!(Path.join(@dir, "#{name}.wasm"))

  defp sentence(digest),
    do:
      "The component #{digest} uses a WebAssembly feature this runtime does not admit: " <>
        "component-model async, GC or exception handling."

  test "each refused guest is refused for its own feature, and its twin is admitted" do
    for {name, family} <- @refused do
      bytes = guest(name)
      digest = Prima.Digest.sha256(bytes)

      log =
        capture_log(fn ->
          assert Prima.ComponentFeatures.check(bytes) ==
                   {:error, {:component_feature_refused, digest}}
        end)

      assert log =~ "#{digest} refused: it uses the #{family} feature", name
    end

    assert Prima.ComponentFeatures.check(guest("sync_lift")) == :ok
    assert Prima.ComponentFeatures.check(guest("trapper")) == :ok
  end

  test "a component the validator refuses with every feature on is invalid, not a feature's" do
    # `sync_lift` with its `i32.const 0` made an `i64.const`: its exports
    # still parse, and its core function no longer type-checks.
    bytes = :binary.replace(guest("sync_lift"), <<0x41, 0x00, 0x0B>>, <<0x42, 0x00, 0x0B>>)
    refute bytes == guest("sync_lift")
    digest = Prima.Digest.sha256(bytes)

    capture_log(fn ->
      assert Prima.ComponentFeatures.check(bytes) == {:error, {:component_invalid, digest}}
    end)

    assert Prima.Refusal.message({:component_invalid, digest}) ==
             "The component #{digest} is not valid WebAssembly."
  end

  test "the run path refuses a refused guest before compiling it, cached or not" do
    for {name, _family} <- @refused do
      bytes = guest(name)
      digest = Prima.Digest.sha256(bytes)

      capture_log(fn ->
        assert Engine.execute_component(bytes, %{}, authority: Prima.Authority.zero()) ==
                 {:error, sentence(digest)}

        assert Engine.execute_component(bytes, %{},
                 authority: Prima.Authority.zero(),
                 digest: digest
               ) == {:error, sentence(digest)}
      end)

      refute match?({:ok, _}, Locus.Runtime.Cache.get({:compiled_component, digest}))
    end
  end

  test "the admitted twin compiles and runs on both paths" do
    bytes = guest("sync_lift")
    digest = Prima.Digest.sha256(bytes)

    # It answers an empty string, which is no JSON: the run reached the
    # guest, past every check before compiling it.
    for opts <- [[], [digest: digest]] do
      capture_log(fn ->
        assert {:error, "Component returned invalid JSON output: " <> _} =
                 Engine.execute_component(bytes, %{}, [authority: Prima.Authority.zero()] ++ opts)
      end)
    end

    assert {:ok, _compiled} = Locus.Runtime.Cache.get({:compiled_component, digest})
  end
end
