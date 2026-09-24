# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Resources do
  @moduledoc """
  The MCP resource index: what `resources/list` and
  `resources/templates/list` advertise, and which declared operation
  admits a read of a URI.

  The index is derived from the operation table's providers when
  `Grimoire.Catalog.load!/0` builds the table, and held beside it in
  Grimoire's `:persistent_term` (`{Grimoire, :resources}`), written once
  per member. The advertised lists are `c:Prima.Provider.resources/0` and
  `c:Prima.Provider.resource_templates/0` of every provider in the table;
  the scheme index maps a URI's scheme to the one operation that declares
  it in `resource_schemes`, so `resources/read` becomes a call of that
  operation through the gate (`Grimoire.call_external/4`) — this module
  reads nothing and authorizes nothing. That every advertised scheme has
  exactly one owner is `Grimoire.Catalog.audit_resource_schemes/1`'s boot
  check, which runs before the index is built.
  """

  @key {Grimoire, :resources}

  @typedoc "The index: the advertised lists and the scheme → operation map."
  @type table :: %{
          resources: [map()],
          templates: [map()],
          schemes: %{String.t() => {String.t(), String.t()}}
        }

  @doc """
  List all available resources from all providers.

  Returns a list of resource descriptors for MCP `resources/list`.
  """
  @spec list_resources() :: [map()]
  def list_resources, do: table().resources

  @doc """
  List all available resource templates from all providers.

  Returns a list of resource template descriptors for MCP `resources/templates/list`.
  """
  @spec list_resource_templates() :: [map()]
  def list_resource_templates, do: table().templates

  @doc """
  The declared operation that admits a read of `uri`: `{:ok, tool, action}`,
  or a typed argument refusal for a URI that names no scheme or a scheme
  no operation declares.
  """
  @spec resolve(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, {:invalid_argument, String.t()}}
  def resolve(uri) when is_binary(uri) do
    case Prima.Provider.resource_scheme(uri) do
      {:ok, scheme} ->
        case table().schemes do
          %{^scheme => {tool, action}} -> {:ok, tool, action}
          _ -> {:error, {:invalid_argument, "No provider found for scheme: #{scheme}"}}
        end

      :error ->
        {:error, {:invalid_argument, "Invalid URI format: #{uri}"}}
    end
  end

  @doc "The index this member holds."
  @spec table() :: table()
  def table, do: :persistent_term.get(@key)

  @doc false
  # The index of `providers`, in their order: what each advertises, and
  # the scheme each declared resource operation owns. Built by the
  # catalog, after its audit, from the providers the table holds.
  @spec build([module()]) :: table()
  def build(providers) do
    %{
      resources: for(p <- providers, r <- advertised(p, :resources), do: format_resource(r)),
      templates:
        for(
          p <- providers,
          t <- advertised(p, :resource_templates),
          do: format_resource_template(t)
        ),
      schemes:
        for(
          p <- providers,
          tool <- p.tools(),
          %Prima.Operation{} = operation <- Map.get(tool, :operations, []),
          scheme <- operation.resource_schemes,
          into: %{},
          do: {scheme, {operation.tool, operation.action}}
        )
    }
  end

  @doc false
  # Written by the catalog alone, beside the table it was built with.
  @spec put(table()) :: :ok
  def put(%{resources: _, templates: _, schemes: _} = table),
    do: :persistent_term.put(@key, table)

  defp advertised(provider, fun) do
    if function_exported?(provider, fun, 0), do: apply(provider, fun, []), else: []
  end

  defp format_resource(resource) do
    %{
      "uri" => Map.get(resource, :uri) || Map.get(resource, "uri"),
      "name" => Map.get(resource, :name) || Map.get(resource, "name"),
      "description" => Map.get(resource, :description) || Map.get(resource, "description"),
      "mimeType" =>
        Map.get(resource, :mimeType) || Map.get(resource, "mimeType") || Prima.MediaType.json()
    }
  end

  defp format_resource_template(template) do
    %{
      "uriTemplate" => Map.get(template, :uriTemplate) || Map.get(template, "uriTemplate"),
      "name" => Map.get(template, :name) || Map.get(template, "name"),
      "description" => Map.get(template, :description) || Map.get(template, "description"),
      "mimeType" =>
        Map.get(template, :mimeType) || Map.get(template, "mimeType") || Prima.MediaType.json()
    }
  end
end
