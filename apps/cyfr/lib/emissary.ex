# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary do
  @moduledoc """
  MCP protocol layer: JSON-RPC routing, sessions, SSE buffering, the tool and
  resource registries, and external MCP server supervision.

  Emissary owns the transport and dispatch; each namespace registers its own
  tools/resources (see `Prima.Provider`) — except the two
  person-surface tools Emissary registers itself, `thread` and
  `notes`: they wrap `Aqua`/`Arca` domain functions, and `Aqua.ToolSeamTest`
  keeps the agent harness from owning a provider of its own. Shared
  primitives like `Prima.UUID7` live in the glue namespace, not here.
  """
end
