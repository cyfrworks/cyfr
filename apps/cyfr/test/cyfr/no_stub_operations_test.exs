# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NoStubOperationsTest do
  @moduledoc """
  No operation on the roster answers as a stub.

  An operation declared ahead of its work once answered
  `{:error, :not_built}`, and `Prima.Refusal` classified that answer as
  unavailable. Every such handler is filled, so the stub's word leaves the
  tree: no code line of any application's `lib` names `not_built`, which
  covers a handler and anything it delegates to, and the refusal
  vocabulary no longer classifies it, so a stub that came back would
  surface as an unclassified error rather than pass for a refusal.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @root Path.expand("../../../..", __DIR__)
  @stub ~r/\bnot_built\b/

  defp lib_files do
    for lib <- SourceTree.app_libs(@root),
        path <- SourceTree.files!(Path.join([@root, lib, "**/*.ex"])),
        do: path
  end

  # The code lines of `path` that name the stub, comments and documentation
  # left out.
  defp stub_lines(path) do
    for {line, n} <- SourceTree.code_lines(path),
        line =~ @stub,
        do: {Path.relative_to(path, @root), n}
  end

  test "no code line of any application names the stub's answer" do
    files = lib_files()
    assert length(files) > 500, "the scan found #{length(files)} files — it is not reading"

    found = Enum.flat_map(files, &stub_lines/1)

    assert found == [],
           """
           These lines name `not_built`. An operation on the roster does its
           work or refuses with a reason `Prima.Refusal` classifies; a path
           the admission roster defers answers `:deferred`.

           #{Enum.map_join(found, "\n", fn {path, n} -> "  #{path}:#{n}" end)}
           """
  end

  test "the scan reads every operation provider on the roster" do
    scanned = MapSet.new(lib_files())
    operations = Grimoire.Catalog.operations()

    assert map_size(operations) > 20

    for {tool, {provider, _meta}} <- operations do
      source = provider.module_info(:compile)[:source] |> to_string() |> Path.expand()

      assert MapSet.member?(scanned, source),
             "#{tool}'s provider #{inspect(provider)} is defined in #{source}, outside the scan"
    end
  end

  test "the refusal vocabulary does not classify a stub" do
    refute Prima.Refusal.reason?(:not_built)
  end

  test "a planted stub is found, and a comment naming one is not" do
    path =
      Path.join(System.tmp_dir!(), "cyfr-planted-stub-#{System.unique_integer([:positive])}.ex")

    on_exit(fn -> File.rm(path) end)

    File.write!(path, """
    defmodule Planted.Provider do
      # Answered not_built once; a comment is no answer.
      def handle(_action, _ctx, _args), do: {:error, :not_built}
    end
    """)

    assert [{_path, 3}] = stub_lines(path)
  end
end
