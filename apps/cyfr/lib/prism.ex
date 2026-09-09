# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism do
  @moduledoc """
  The console's shell-plane services — what `PrismWeb`'s LiveViews lean on
  that is not itself a page.

  - `Prism.TelemetryBridge` — telemetry → PubSub for live console updates.
  - `Prism.TinctureRegistry` — the member-facing tincture cache, populated
    lazily per athanor.
  - `Prism.Labels` / `Prism.Tray` — mode vocabulary and the notification
    tray's badge state.

  `Aqua` owns agent orchestration; Prism renders its state.
  """
end
