# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism do
  @moduledoc """
  The console's shell-plane services — what `PrismWeb`'s LiveViews lean on
  that is not itself a page.

  - `Prism.TinctureRegistry` — the member-facing tincture cache, populated
    lazily per athanor.
  - `Prism.Frames` — the shell's tincture frames, their credentials and the
    canvas the glass shows.
  - `Prism.Arrangement` — the person's gestures on their screen, made on
    their layout.
  - `Prism.CanvasValidation` — a candidate canvas version trialled on the
    glass before it opens live.
  - `Prism.Labels` / `Prism.Tray` — mode vocabulary and the notification
    tray's badge state.
  - `Prism.Fallback` — the shipped canvas shown in the place of one that
    did not start or stopped, and the ways back the system layer offers.
  - `Prism.ConsentChoices` — the consent sheet's choices, pure over the
    plan's typed rows.

  `Aqua` owns agent orchestration; Prism renders its state.
  """

  use Boundary,
    deps: [Sanctum, Arca, Cyfr, Compendium, Aqua, Opus, CyfrWeb],
    exports: [
      Arrangement,
      CanvasValidation,
      ConsentChoices,
      Fallback,
      Frames,
      Labels,
      TinctureRegistry,
      Tray
    ],
    check: [aliases: true]
end
