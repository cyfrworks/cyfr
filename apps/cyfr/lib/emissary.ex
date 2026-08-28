# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary do
  @moduledoc """
  MCP protocol layer: JSON-RPC routing, sessions, SSE buffering, the tool and
  resource registries, and external MCP server supervision.

  Emissary owns the transport and dispatch; each namespace registers its own
  tools/resources (see `Emissary.MCP.ToolProvider`). Shared primitives like
  `Cyfr.UUID7` live in the glue namespace, not here.
  """
end
