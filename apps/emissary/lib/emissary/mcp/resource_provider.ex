defmodule Emissary.MCP.ResourceProvider do
  @moduledoc """
  Behaviour for MCP resource providers.

  Resource providers expose data as MCP resources that clients can discover
  and read. Resources follow the URI pattern `service://path`.

  ## Implementation

  Providers implement two callbacks:

  1. `resources/0` - returns a list of resource templates available
  2. `read/2` - reads a specific resource given context and URI

  ## Example

      defmodule MyApp.ResourceProvider do
        @behaviour Emissary.MCP.ResourceProvider

        @impl true
        def resources do
          [
            %{
              uri: "myapp://config",
              name: "Application Config",
              description: "Current application configuration",
              mimeType: "application/json"
            }
          ]
        end

        @impl true
        def read(_ctx, "myapp://config") do
          {:ok, %{content: Jason.encode!(Application.get_all_env(:myapp))}}
        end

        def read(_ctx, _uri), do: {:error, :not_found}
      end

  """

  alias Sanctum.Context

  @doc """
  Returns a list of available resources.

  Each resource should be a map with:
  - `:uri` - Resource URI (required)
  - `:name` - Human-readable name (required)
  - `:description` - Description of the resource (optional)
  - `:mimeType` - MIME type hint (optional, defaults to application/json)
  """
  @callback resources() :: [map()]

  @doc """
  Read a resource by URI.

  Returns `{:ok, content_map}` or `{:error, reason}`.
  The content_map should have `:content` key with the resource data.
  """
  @callback read(Context.t(), uri :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Check if a module implements the ResourceProvider behaviour.
  """
  def implements?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :resources, 0) and
      function_exported?(module, :read, 2)
  end
end
