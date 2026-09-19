# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StoreLimitsTest do
  @moduledoc """
  The node's consented `max_memory_bytes` bounds a run's linear memory in
  total, and its tables are bounded, by the engine, before anything else
  is reached: a guest declaring a second memory, or a table past the
  bound, is refused at instantiation as a `resource_limit`; a guest that
  grows its memory or its table is let grow to the bound exactly and
  answered -1 past it. The guests are `test_wasm/hostile/`, each held to
  the digest its README records.

  That a runner running one of them stays clean for its athanor's next run
  is `Opus.MemoryBoundTest`'s, in CYFR's suite, through a real runner.
  """

  use ExUnit.Case, async: true

  @dir Path.expand("../support/test_wasm/hostile", __DIR__)
  @mib 1024 * 1024

  defp guest(name), do: File.read!(Path.join(@dir, "#{name}.wasm"))

  defp run(name, max_memory_bytes) do
    Opus.Runtime.execute_component(guest(name), %{"hostile" => true},
      authority: Cyfr.Authority.zero(),
      max_memory_bytes: max_memory_bytes
    )
  end

  test "each guest and its source are the ones the README records" do
    readme = File.read!(Path.join(@dir, "README.md"))

    for name <- ["extra_memory", "wide_table", "grower", "vault_probe"], ext <- ["wat", "wasm"] do
      file = "#{name}.#{ext}"

      assert [_, recorded] =
               Regex.run(~r/^#{Regex.escape(file)}\s+(sha256:[0-9a-f]{64})$/m, readme),
             file

      assert Cyfr.Digest.sha256(File.read!(Path.join(@dir, file))) == recorded, file
    end
  end

  test "a run's store holds one memory of the consented size, and bounded tables" do
    assert %Wasmex.StoreLimits{
             memory_size: 67_108_864,
             memories: 1,
             tables: 10,
             table_elements: 20_000,
             instances: 10
           } = Opus.Runtime.store_limits(64 * @mib)

    assert %Wasmex.StoreLimits{memory_size: 268_435_456, memories: 1} =
             Opus.Runtime.store_limits(256 * @mib)
  end

  test "a guest declaring a second linear memory is refused at instantiation as a resource_limit" do
    assert {:error, message} = run("extra_memory", 64 * @mib)

    assert message ==
             "resource_limit: the engine refused the component's memory or tables " <>
               "(memory count too high at 2)"
  end

  test "a guest declaring a table past the bound is refused at instantiation as a resource_limit" do
    assert {:error, message} = run("wide_table", 64 * @mib)

    assert message ==
             "resource_limit: the engine refused the component's memory or tables " <>
               "(table minimum size of 20001 elements exceeds table limits)"
  end

  test "a guest growing its memory and its table reaches the bound exactly and is refused past it" do
    # The consented total, in 64 KiB pages, whatever the consent says.
    for max <- [8 * @mib, 64 * @mib, 128 * @mib] do
      assert {:ok, %{"pages" => pages, "table" => 20_000}, _metadata} = run("grower", max)
      assert pages * 65_536 == max
    end
  end

  test "an instantiation failure that is no limit's is reported as it was" do
    # A core module, not a component: it fails to compile, not to instantiate.
    math = File.read!(Path.expand("../support/test_wasm/math.wasm", __DIR__))

    assert {:error, message} =
             Opus.Runtime.execute_component(math, %{}, authority: Cyfr.Authority.zero())

    refute message =~ "resource_limit"
  end
end
