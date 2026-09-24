# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.VersionTest do
  @moduledoc """
  `Cyfr.Version.current/0` is the one version every release view states.

  `scripts/release.sh` bumps the root and every application's `mix.exs`
  and the bridge's `package.json` and lock together; each is held to the
  compiled value here. The frozen Locus wire vector, Codex's tag-derived
  version, the images' ref-derived tags and `Cyfr.Release` are not
  version views and are not read.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Test.SourceTree

  @root Path.expand("../../../..", __DIR__)
  @lib Path.expand("../../lib", __DIR__)

  test "the compiled version is the contracts application's" do
    assert Cyfr.Version.current() == to_string(Application.spec(:cyfr_contracts, :vsn))
    assert Cyfr.Version.current() =~ ~r/\A\d+\.\d+\.\d+\z/
  end

  test "the root and every application's mix.exs state it" do
    files = [Path.join(@root, "mix.exs") | SourceTree.files!(Path.join(@root, "apps/*/mix.exs"))]

    assert length(files) >= 7

    for file <- files do
      assert [_, version] = Regex.run(~r/^\s*version: "([^"]+)",?$/m, File.read!(file)),
             "#{Path.relative_to(file, @root)} states no version"

      assert version == Cyfr.Version.current(),
             "#{Path.relative_to(file, @root)} states #{version}, " <>
               "the build states #{Cyfr.Version.current()}"
    end
  end

  test "the bridge's package and its lock state it" do
    package =
      @root |> Path.join("apps/mcp-bridge/package.json") |> File.read!() |> Jason.decode!()

    lock =
      @root |> Path.join("apps/mcp-bridge/package-lock.json") |> File.read!() |> Jason.decode!()

    assert package["version"] == Cyfr.Version.current()
    assert lock["version"] == Cyfr.Version.current()
    assert lock["packages"][""]["version"] == Cyfr.Version.current()
  end

  test "no contracts beam reads Mix or an application's spec at run time" do
    modules =
      for module <- Application.spec(:cyfr_contracts, :modules),
          String.starts_with?(to_string(module.module_info(:compile)[:source]), @lib <> "/"),
          do: module

    assert Cyfr.Version in modules and Cyfr.BuilderProtocol in modules

    for module <- modules do
      {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])

      for {m, f, a} <- imports do
        name = Atom.to_string(m)

        refute m == Mix or String.starts_with?(name, "Elixir.Mix."),
               "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a} at run time"

        refute {m, f} in [{Application, :spec}, {:application, :get_key}],
               "#{inspect(module)} reads an application spec at run time"
      end
    end
  end
end
