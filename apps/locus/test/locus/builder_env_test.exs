# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderEnvTest do
  @moduledoc """
  A build runs user code (a project's build script, a crate's build.rs),
  so the environment it sees is the toolchain's allowlist and nothing of
  the server's own — no database URL, no key material, and no inherited
  output location.
  """

  # Sets the operating system's environment for the duration of a test.
  use ExUnit.Case, async: false

  alias Locus.Builder

  @tag :requires_node
  test "a build script sees none of the server's environment beyond the toolchain's allowlist" do
    previous = Map.new(~w(CARGO_TARGET_DIR CYFR_DATABASE_URL), &{&1, System.get_env(&1)})
    System.put_env("CARGO_TARGET_DIR", "/elsewhere")
    System.put_env("CYFR_DATABASE_URL", "postgres://secret@db/cyfr")

    on_exit(fn ->
      for {key, value} <- previous,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end)

    source_files = %{
      "package.json" =>
        Jason.encode!(%{
          name: "env-probe",
          private: true,
          scripts: %{build: "mkdir -p dist && env > dist/env.txt"}
        })
    }

    assert {:ok, %{output_files: %{"env.txt" => env}}} =
             Builder.compile(source_files, :javascript, target_type: :tincture)

    refute env =~ "CARGO_TARGET_DIR="
    refute env =~ "CYFR_DATABASE_URL="
    assert env =~ "PATH="
  end
end
