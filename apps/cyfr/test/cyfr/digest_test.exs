# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DigestTest do
  @moduledoc """
  A file set's digest depends on its paths and bytes alone: not on the
  order the files arrive in, and never equal for two different sets whose
  paths and bytes concatenate alike.
  """

  use ExUnit.Case, async: true

  test "a file set's digest is order-independent and counts every byte" do
    files = [{"index.html", "<p>hi</p>"}, {"assets/app.js", "go()"}]

    assert {digest, 13} = Cyfr.Digest.file_set(files)
    assert {^digest, 13} = Cyfr.Digest.file_set(Enum.reverse(files))
    assert {^digest, 13} = Cyfr.Digest.file_set(Map.new(files))
    assert "sha256:" <> _ = digest
  end

  test "sets whose paths and bytes concatenate alike digest differently" do
    {one, _} = Cyfr.Digest.file_set(%{"a" => "bc"})
    {two, _} = Cyfr.Digest.file_set(%{"ab" => "c"})
    {three, _} = Cyfr.Digest.file_set(%{"a" => "b", "c" => ""})

    assert Enum.uniq([one, two, three]) == [one, two, three]
  end
end
