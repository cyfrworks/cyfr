# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DocsDriftTest do
  @moduledoc """
  CLAUDE.md is the operating manual every session reads before touching
  the tree; a storage root it does not name is a root nobody defends.
  This binds its storage-tree sentence to the layout SSOT the same way
  the drift guards bind the protocol literals.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @claude_md Path.join(@repo_root, "CLAUDE.md")
  @readme Path.join(@repo_root, "README.md")

  test "CLAUDE.md's storage tree names every tenant root and global prefix" do
    doc = File.read!(@claude_md)

    # The tenant roots appear in one brace group after the athanor id.
    for root <- Arca.Storage.tenant_roots() do
      assert doc =~ root,
             "tenant root #{root} is missing from CLAUDE.md's storage tree"
    end

    # The global server roots ride in a `data/{...}` group of their own.
    for prefix <- Arca.Storage.global_prefixes() do
      assert doc =~ prefix,
             "global prefix #{prefix} is missing from CLAUDE.md's storage tree"
    end
  end

  test "README's storage tree names every tenant root and global prefix" do
    doc = File.read!(@readme)

    # The README draws the tree with a trailing slash per directory —
    # matched with the slash so "metadata" prose can't stand in for `meta/`.
    for root <- Arca.Storage.tenant_roots() ++ Arca.Storage.global_prefixes() do
      assert doc =~ root <> "/",
             "root #{root}/ is missing from README's storage tree"
    end
  end
end
