# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage.UnitLocator do
  @moduledoc """
  How an overlaid root's shadow units are shaped — answered from the path
  grammar alone, by the domain module that owns the root's spelling
  (`Compendium.ComponentPath` for `components/`, `Compendium.AquaPath` for
  `aqua/`), wired through the `:overlay_locators` config so `Arca` never
  gains a compile edge on Compendium.

  The layout table (`Arca.Storage`) says only WHETHER a root overlays;
  the locator says HOW: given a logical path inside its root, it answers

    * `:above_unit` — the path sits above any shadow unit (listings union
      here; writes and deletes pass untouched);
    * `{:file, unit}` — the path is at or below a file-shaped unit (the
      unit IS one file — an aqua agent; a single put materializes it);
    * `{:dir, unit, sentinel}` — the path is at or below a directory
      unit whose named sentinel file marks a completed copy (a component
      version directory, an aqua skill).

  Pure — no I/O, no context. The shape must be answerable before any file
  exists (copy-on-write consults it on the first write), and the batch
  walks stay two listings with no per-unit probes because classifying a
  leaf is a function call, not a round-trip.
  """

  @callback locate(Arca.Storage.path()) ::
              :above_unit
              | {:file, unit :: Arca.Storage.path()}
              | {:dir, unit :: Arca.Storage.path(), sentinel :: String.t()}
end
