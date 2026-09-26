# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Mix do
  @moduledoc """
  The boundary the Mix tasks under `lib/mix/tasks` classify to. A task
  runs from the command line against the gate's operation table or a
  shared contract, and names exactly the boundaries listed here.
  """

  use Boundary, top_level?: true, deps: [Grimoire], exports: [], check: [aliases: true]
end
