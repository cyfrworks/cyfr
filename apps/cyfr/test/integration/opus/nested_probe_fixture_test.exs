# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.NestedProbeFixtureTest do
  @moduledoc """
  The `nested-probe` fixture is the build its README records: its source,
  its lock and its binary hash to the digests `build.sh` printed, so a
  source change without a rebuild, or a binary built another way, fails
  here (`build.sh --check` proves the binary a fresh build's).
  """

  use ExUnit.Case, async: true

  alias Opus.Test.NestedExecution, as: Probe

  test "the probe's binary and sources are the ones its README records" do
    dir = Path.dirname(Probe.wasm_path())
    readme = File.read!(Path.join(dir, "README.md"))

    for name <- ["src/lib.rs", "Cargo.lock", "nested_probe.wasm"] do
      assert [_, recorded] =
               Regex.run(~r/^#{Regex.escape(name)}\s+(sha256:[0-9a-f]{64})$/m, readme)

      assert Prima.Digest.sha256(File.read!(Path.join(dir, name))) == recorded, name
    end
  end
end
