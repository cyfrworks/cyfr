# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ComponentSizeTest do
  @moduledoc """
  The largest component registration admits is one its runner can fetch.
  A reagent padded to `Prima.HostAPI.max_artifact_bytes/0` registers, and
  its run fetches its bytes from CYFR across the suite's wire, as one
  `fetch_artifact` answer, and completes; padded one byte more, it is
  refused at registration with its size and the largest size that runs.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.TwoServices
  alias Prima.Test.PaddedComponent

  @moduletag timeout: 120_000

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    test_path =
      Path.join(System.tmp_dir!(), "component_size_#{System.unique_integer([:positive])}")

    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  defp publish(ctx, wasm, name) do
    Compendium.Registry.publish_bytes(ctx, wasm, %{name: name, version: "0.1.0", type: "reagent"})
  end

  test "the largest component registration admits is fetched and runs", %{ctx: ctx} do
    max = Prima.HostAPI.max_artifact_bytes()
    wasm = PaddedComponent.pad(Cyfr.Test.Guests.wasm(:reagent), max)

    assert {:ok, _component} = publish(ctx, wasm, "largest-fetched")
    execution_id = Prima.UUID7.execution_id()

    assert {:ok, %{status: :completed, output: %{"ran" => true}}} =
             Opus.Dispatch.run(ctx, "reagent:local.largest-fetched:0.1.0", %{},
               type: "reagent",
               execution_id: execution_id,
               authority: Prima.Authority.zero()
             )

    assert [_fetched] = TwoServices.calls(:fetch_artifact, execution_id)
  end

  test "a component one byte larger is refused at registration, with both sizes", %{ctx: ctx} do
    max = Prima.HostAPI.max_artifact_bytes()
    wasm = PaddedComponent.pad(Cyfr.Test.Guests.wasm(:reagent), max + 1)

    assert {:error, reason} = publish(ctx, wasm, "one-byte-over")

    assert Sanctum.Refusals.render(reason) ==
             "The component is #{max + 1} bytes, and a component runs only up to #{max} " <>
               "bytes; make it smaller to register it."

    assert {:error, :not_found} = Compendium.Registry.get(ctx, "one-byte-over", "0.1.0")
  end
end
