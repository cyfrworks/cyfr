# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.SandboxTest do
  @moduledoc """
  The sandbox owner at a test's end (`Arca.Test.Sandbox`): a setting the
  test wrote goes with its transaction, and the settings cache, one per
  node, agrees with the store once the owner is gone, whatever read the
  setting before that, the test itself or work ending after it.

  Each case's check runs in an `on_exit` registered before the owner's,
  so after the rollback, and reads the store as it stands outside every
  sandbox.
  """

  use ExUnit.Case, async: false

  alias Arca.PlatformSettings

  @key "a_sandboxed_cap"
  @defaults %{@key => %{default: 50, stale: :refuse}}

  setup tags do
    before = PlatformSettings.installed()

    on_exit(fn ->
      after_rollback =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fn ->
          PlatformSettings.effective(@key)
        end)

      if before,
        do: PlatformSettings.install_defaults!(before),
        else: PlatformSettings.uninstall()

      assert after_rollback == {:ok, 50}
    end)

    Arca.Test.Sandbox.setup!(tags)
    PlatformSettings.install_defaults!(Map.merge(before || %{}, @defaults))
    :ok
  end

  defp put!(value) do
    {:ok, %{revision: revision}} = PlatformSettings.all()
    {:ok, _next} = PlatformSettings.put(@key, value, revision, "test")
  end

  test "a setting the test wrote and read is not read from the cache after its rollback" do
    put!(1_000_000)
    assert PlatformSettings.effective(@key) == {:ok, 1_000_000}
  end

  test "a setting read after the test's own invalidation, as its work ends, is not read from " <>
         "the cache after its rollback" do
    put!(1_000_000)
    on_exit(fn -> PlatformSettings.effective(@key) end)
    PlatformSettings.invalidate(@key)
  end
end
