defmodule Emissary.MCP.ToolProvider do
  @moduledoc """
  Behaviour for MCP tool providers.

  Each CYFR service (Arca, Opus, etc.) implements this behaviour
  to register its tools with Emissary. This enables:

  1. **Service-owned tools**: Each service defines and handles its own tools
  2. **Decoupled transport**: Emissary stays domain-agnostic
  3. **Future distributed support**: Same interface works with :rpc.call

  ## Implementing a Provider

      defmodule Arca.MCP do
        @behaviour Emissary.MCP.ToolProvider

        @impl true
        def tools do
          [
            %{
              name: "storage",
              description: "List files at a path",
              input_schema: %{"type" => "object", ...}
            }
          ]
        end

        @impl true
        def handle("storage", ctx, args) do
          # Implementation
          {:ok, %{files: [...]}}
        end
      end

  ## Registration

  Providers are configured in `config/config.exs`:

      config :emissary, :tool_providers, [
        Arca.MCP,
        Sanctum.MCP,
        Opus.MCP,
        Compendium.MCP
      ]

  ## Future: Distributed Workers

  When running multiple Opus/Locus containers, the registry will be
  extended to track node availability and route accordingly:

      def handle(tool, ctx, args) do
        node = pick_healthy_node(tool)
        :rpc.call(node, __MODULE__, :handle, [tool, ctx, args])
      end

  """

  alias Sanctum.Context

  @type icon :: %{
          required(:src) => String.t(),
          required(:mimeType) => String.t(),
          optional(:sizes) => [String.t()]
        }

  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map(),
          optional(:title) => String.t(),
          optional(:icons) => [icon()],
          optional(:output_schema) => map(),
          optional(:annotations) => map()
        }

  @type handle_result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Return list of tool definitions this provider offers.

  Each tool definition must include:
  - `name`: Tool name (e.g., "storage", "execution", "component")
  - `description`: Human-readable description for AI agents
  - `input_schema`: JSON Schema for input validation

  Optional fields (MCP 2025-11-25):
  - `title`: Human-readable display name for the tool
  - `icons`: Array of icon definitions for UI display
  - `output_schema`: JSON Schema for output validation
  - `annotations`: Properties describing tool behavior
  """
  @callback tools() :: [tool_definition()]

  @doc """
  Handle a tool call.

  Called when an MCP client invokes a tool. The context contains
  the authenticated user and permissions.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback handle(tool_name :: String.t(), ctx :: Context.t(), args :: map()) ::
              handle_result()
end
