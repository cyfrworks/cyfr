# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ArchiveTest do
  use ExUnit.Case, async: true

  alias Compendium.Archive

  describe "gunzip_bounded/2" do
    test "round-trips ordinary content" do
      content = String.duplicate("hello world ", 1000)
      assert {:ok, ^content} = Archive.gunzip_bounded(:zlib.gzip(content), byte_size(content))
    end

    test "refuses output past the bound — the decompression-bomb guard" do
      # 1 MB of zeros gzips to ~1 KB; a 1000-byte ceiling must refuse it
      # without materializing the megabyte.
      bomb = :zlib.gzip(:binary.copy(<<0>>, 1_000_000))
      assert byte_size(bomb) < 5_000
      assert {:error, :too_large} = Archive.gunzip_bounded(bomb, 1_000)
    end

    test "answers a message, not a raise, for non-gzip bytes" do
      assert {:error, message} = Archive.gunzip_bounded("not gzip at all", 1_000)
      assert is_binary(message)
    end
  end

  describe "create_tar_gz/1" do
    test "round-trips through :erl_tar" do
      assert {:ok, gz} =
               Archive.create_tar_gz([
                 {~c"src/lib.rs", "fn main() {}"},
                 {~c"src/Cargo.toml", "[package]"}
               ])

      {:ok, tar} = Archive.gunzip_bounded(gz, 1_000_000)
      {:ok, entries} = :erl_tar.extract({:binary, tar}, [:memory])

      assert Enum.sort(entries) == [
               {~c"src/Cargo.toml", "[package]"},
               {~c"src/lib.rs", "fn main() {}"}
             ]
    end
  end
end
