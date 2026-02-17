defmodule Prism do
  @moduledoc """
  Prism - Phoenix LiveView Dashboard for CYFR.

  Provides a web GUI for all CYFR operations: running components,
  managing secrets/policies/keys, browsing the registry, monitoring
  executions, and viewing audit trails.

  Prism runs on its own endpoint (port 4001) and calls through
  `Emissary.MCP.ToolRegistry.call/3` for all tool invocations.
  """
end
