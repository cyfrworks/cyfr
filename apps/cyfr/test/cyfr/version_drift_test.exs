# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.VersionDriftTest do
  @moduledoc """
  Every release view states `Prima.Version.current/0`.

  `scripts/release.sh` bumps the root and every application's `mix.exs`
  together; each is held to the compiled value here. The frozen Locus wire vector, Codex's tag-derived
  version, the images' ref-derived tags and `Cyfr.Release` are not
  version views and are not read.
  """
  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @root Path.expand("../../../..", __DIR__)

  test "the root and every application's mix.exs state it" do
    files = [Path.join(@root, "mix.exs") | SourceTree.files!(Path.join(@root, "apps/*/mix.exs"))]

    assert length(files) >= 7

    for file <- files do
      assert [_, version] = Regex.run(~r/^\s*version: "([^"]+)",?$/m, File.read!(file)),
             "#{Path.relative_to(file, @root)} states no version"

      assert version == Prima.Version.current(),
             "#{Path.relative_to(file, @root)} states #{version}, " <>
               "the build states #{Prima.Version.current()}"
    end
  end
end
