# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigest do
  @moduledoc """
  The immutable configuration identity of an external MCP server —
  what a consent's `tool_server` resource pins (§3.8).

  `JCS({url, enabled, header_templates, tool_patterns})` over the stored
  header **templates** (`vault:CONNECTION` references and non-credential
  literals), never resolved values: rotating a referenced Connection must
  not move the digest, while re-pointing the URL or swapping a header
  reference must. There is deliberately no stored digest column — a
  stored digest is a cache someone forgets to recompute; deriving at
  read makes "changed config ⇒ mismatch ⇒ deny" true by construction.

  This is the *consent* identity. The supervisor's process-reconciliation
  digest is a different digest on purpose: it covers `timeout_ms`
  (process identity), which consent has no business pinning.
  """

  alias Sanctum.JCS
  alias Sanctum.ToolPattern

  @doc "Compute the digest for a server's stored configuration."
  @spec compute(map()) :: {:ok, String.t()} | {:error, term()}
  def compute(%{url: url, enabled: enabled, headers: headers, tool_patterns: patterns})
      when is_binary(url) and is_boolean(enabled) and is_map(headers) and is_list(patterns) do
    header_templates =
      headers
      |> Enum.map(fn {name, template} ->
        %{"name" => to_string(name), "template" => to_string(template)}
      end)
      |> Enum.sort_by(& &1["name"])

    JCS.hash(%{
      "url" => url,
      "enabled" => enabled,
      "header_templates" => header_templates,
      "tool_patterns" => Enum.sort(patterns)
    })
  end

  def compute(other), do: {:error, {:invalid_server_config, other}}

  @doc """
  The ONE place a peer's schema spelling is normalized on the way in.

  Some upstream servers publish `parameters` instead of `inputSchema`; both
  the descriptions digest (here) and the exposed tool definition
  (`Emissary.MCP.ExternalProvider`) must apply the identical mapping, or the
  digest silently stops covering the schema it is supposed to pin.
  """
  def normalize_input_schema(tool) when is_map(tool) do
    tool["inputSchema"] || tool["parameters"] || %{}
  end

  @doc "The digest for a stored `Arca.Schemas.McpServer` row."
  @spec from_server(map()) :: {:ok, String.t()} | {:error, term()}
  def from_server(server) do
    config = Arca.McpServerStorage.config(server)

    compute(%{
      url: server.url,
      enabled: server.enabled == true,
      headers: config["headers"] || %{},
      tool_patterns: tool_patterns(server)
    })
  end

  @doc """
  A server's exposure patterns: what the operator allowed this server to
  offer at all, before any consent narrows further. Absent means
  everything (`["*"]`); a present list is an allowlist, so invalid
  entries drop out and an empty or all-invalid list exposes nothing —
  never silently widening back to `*`.
  """
  @spec tool_patterns(map()) :: [String.t()]
  def tool_patterns(server) do
    config = Arca.McpServerStorage.config(server)

    case config["tool_patterns"] do
      list when is_list(list) -> Enum.filter(list, &ToolPattern.valid?/1)
      _ -> ["*"]
    end
  end

  @doc """
  The D8 baseline: a digest over the descriptions and input schemas of
  the tools matched by `patterns`, so later drift is detectable. Returns
  `:unavailable` when any matched tool's schema falls outside the JCS
  domain (upstream schemas are arbitrary JSON) — no baseline means no
  drift checks, never a false one.
  """
  @spec descriptions_digest([map()], [String.t()]) :: {:ok, String.t()} | :unavailable
  def descriptions_digest(tools, patterns) when is_list(tools) and is_list(patterns) do
    matched =
      Enum.filter(tools, fn tool ->
        name = tool["name"] || ""
        Enum.any?(patterns, &ToolPattern.matches?(&1, name))
      end)

    matched
    |> Enum.reduce_while({:ok, %{}}, fn tool, {:ok, acc} ->
      input = %{
        "description" => tool["description"] || "",
        "inputSchema" => normalize_input_schema(tool)
      }

      case JCS.hash(input) do
        {:ok, hash} -> {:cont, {:ok, Map.put(acc, tool["name"] || "", hash)}}
        {:error, _} -> {:halt, :unavailable}
      end
    end)
    |> case do
      {:ok, entries} ->
        case JCS.hash(entries) do
          {:ok, digest} -> {:ok, digest}
          {:error, _} -> :unavailable
        end

      :unavailable ->
        :unavailable
    end
  end
end
