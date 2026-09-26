# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism do
  @moduledoc """
  The console's shell-plane services — what `PrismWeb`'s LiveViews lean on
  that is not itself a page.

  - `Prism.TinctureRegistry` — the member-facing tincture cache, populated
    lazily per athanor.
  - `Prism.Frames` — the shell's tincture frames and their credentials.
  - `Prism.Labels` / `Prism.Tray` — mode vocabulary and the notification
    tray's badge state.
  - `Prism.SafeMode` — what the system layer offers when a desktop fails.

  `Aqua` owns agent orchestration; Prism renders its state.
  """

  use Boundary,
    deps: [Grimoire, Sanctum, Arca, Cyfr, Compendium, Aqua, Crucible, CyfrWeb],
    exports: [
      Frames,
      Labels,
      SafeMode,
      TinctureRegistry,
      Tray
    ],
    check: [aliases: true]
end
