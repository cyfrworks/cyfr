# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderEnvTest do
  @moduledoc """
  A build runs user code (a project's build script, a crate's build.rs),
  so the environment it sees is the toolchain's allowlist and nothing of
  the server's own — no database URL, no key material, and no inherited
  output location — and the homes it writes are its own: created with the
  build, distinct from every other build's, and gone when it ends.
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

  @tag :requires_node
  test "a build's home, Cargo home and npm cache are its own, and go with it" do
    source_files = %{
      "package.json" =>
        Jason.encode!(%{
          name: "home-probe",
          private: true,
          scripts: %{build: "mkdir -p dist && env > dist/env.txt && touch \"$HOME/left-behind\""}
        })
    }

    homes =
      for _build <- 1..2 do
        assert {:ok, %{output_files: %{"env.txt" => env}}} =
                 Builder.compile(source_files, :javascript, target_type: :tincture)

        values =
          for line <- String.split(env, "\n"),
              [k, v] <- [String.split(line, "=", parts: 2)],
              into: %{},
              do: {k, v}

        Map.take(values, ["HOME", "CARGO_HOME", "npm_config_cache"])
      end

    [first, second] = homes
    tmp = Path.expand(System.tmp_dir!())

    for {key, dir} <- first do
      assert String.starts_with?(Path.expand(dir), tmp), "#{key} is not under the build tree"
      refute dir == second[key], "#{key} is shared between builds"
      refute File.exists?(dir), "#{key} outlived its build"
    end

    refute first["HOME"] == System.user_home()
  end
end
