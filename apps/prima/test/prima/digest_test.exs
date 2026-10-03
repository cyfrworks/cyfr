# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DigestTest do
  @moduledoc """
  A file set's digest depends on its paths and bytes alone: not on the
  order the files arrive in, and never equal for two different sets whose
  paths and bytes concatenate alike.
  """

  use ExUnit.Case, async: true

  test "a file set's digest is order-independent and counts every byte" do
    files = [{"index.html", "<p>hi</p>"}, {"assets/app.js", "go()"}]

    assert {digest, 13} = Prima.Digest.file_set(files)
    assert {^digest, 13} = Prima.Digest.file_set(Enum.reverse(files))
    assert {^digest, 13} = Prima.Digest.file_set(Map.new(files))
    assert "sha256:" <> _ = digest
  end

  test "sets whose paths and bytes concatenate alike digest differently" do
    {one, _} = Prima.Digest.file_set(%{"a" => "bc"})
    {two, _} = Prima.Digest.file_set(%{"ab" => "c"})
    {three, _} = Prima.Digest.file_set(%{"a" => "b", "c" => ""})

    assert Enum.uniq([one, two, three]) == [one, two, three]
  end

  test "a keyed digest is RFC 4231's HMAC-SHA256, spelled as every digest is" do
    # RFC 4231, test case 2.
    assert Prima.Digest.hmac_sha256("Jefe", "what do ya want for nothing?") ==
             "sha256:5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

    refute Prima.Digest.hmac_sha256("another key", "what do ya want for nothing?") ==
             Prima.Digest.hmac_sha256("Jefe", "what do ya want for nothing?")

    refute Prima.Digest.hmac_sha256("Jefe", "what do ya want for nothing?") ==
             Prima.Digest.sha256("what do ya want for nothing?")
  end
end
