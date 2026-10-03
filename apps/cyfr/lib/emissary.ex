# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary do
  @moduledoc """
  MCP protocol layer: JSON-RPC routing, sessions, SSE buffering, the tool and
  resource registries, and external MCP server supervision.

  Emissary owns the transport; each namespace registers its own tools and
  resources (see `Prima.Provider`), the assistant's `thread` and `notes`
  included (`Aqua.Providers.Thread`, `Aqua.Providers.Notes`). Shared
  primitives like `Prima.UUID7` live in the glue namespace, not here.
  """

  use Boundary,
    deps: [Grimoire, Sanctum, Arca, Cyfr, Crucible, CyfrWeb],
    exports: [
      External.Proxy,
      MCP,
      MCP.Progress,
      MCP.Router,
      MCP.Subscriptions,
      Supervisor
    ],
    check: [aliases: true]
end
