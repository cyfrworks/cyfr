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

  # The three operator guides are compile-embedded reference material every
  # athanor is given (@external_resource into the aqua tool) — they drift
  # exactly like README did, and only CLAUDE.md/README were pinned here.
  # component-guide's storage tree shipped without meta/ for that reason.
  @guides ~w(component-guide.md tincture-guide.md integration-guide.md)

  test "every guide that draws the athanor tree names every tenant root" do
    for guide <- @guides do
      source = File.read!(Path.join(@repo_root, guide))

      # Only guides that actually draw the per-athanor tree are held to it.
      if source =~ "athanors/{athanor_id}/\n" or source =~ "└── athanors" or
           source =~ "athanors/{athanor_id}/`" do
        for root <- Arca.Storage.tenant_roots() do
          assert source =~ "#{root}/",
                 "tenant root #{root}/ is missing from #{guide}'s storage tree"
        end
      end
    end
  end

  test "component-guide's manifest field table documents the closed key roster" do
    source = File.read!(Path.join(@repo_root, "component-guide.md"))

    for key <- Compendium.Manifest.known_keys() do
      assert source =~ "| `#{key}` |",
             "manifest key `#{key}` (Compendium.Manifest.known_keys/0) is missing " <>
               "from component-guide.md's field table"
    end
  end

  test "the guides' tincture-block keys are ones the code actually reads" do
    # The truth roster: what the validator shape-checks plus what the
    # registry/controller consume (entry, icon, tagline, public, build,
    # window, connect, media). A key documented that nothing reads — the
    # old `sandbox` row — teaches authors a knob that does not exist.
    documented_only = ~w(sandbox)

    for guide <- ~w(component-guide.md tincture-guide.md), key <- documented_only do
      source = File.read!(Path.join(@repo_root, guide))

      refute source =~ "`#{key}` |",
             "#{guide} documents tincture.#{key} as a field, but nothing reads it"
    end
  end
end
