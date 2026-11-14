# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigest do
  @moduledoc """
  External MCP configuration digest pinned by a consent tool_server resource.

  `JCS({id, transport, mark, url, enabled, header_entries, backends,
  program})` over what decides where the server's calls go and which
  credentials ride along, never resolved values: rotating a referenced
  vault entry must not move the digest, while each of these must, so a
  definition that reaches more no longer matches a grant made for the old
  one and the person is asked again at use:

    * the address whole (scheme, host, port and path);
    * each header that names a vault entry, by its name and its template
      (`header_entries`): one added, removed or pointed at another entry.
      A header holding a literal is the person's own value for the same
      address and is left out, so changing it, or a timeout, keeps the
      grants;
    * a program's backends (each one's name, command and env templates)
      and its `program` member, everything else that decides what it is
      and what it reaches, each setting it holds: its hosts (the set of
      names, in one order; absent, every public host), its folder's
      identity (its home and the login entry a kept home is), its memory
      and disk bounds and its sign-in command;
    * the row's id, so a row deleted and made again under its name does.

  The server's tool patterns are left out: a grant carries its own and
  only ever reaches their intersection (`tool_patterns/1`). An http row
  has neither a mark nor a program; a program's `url` is the empty string.
  Only a tool server has a digest: an `http` row or a program marked
  `mcp`; a `driven` program offers no tools.

  There is deliberately no stored digest column — a stored digest is a cache someone
  forgets to recompute; deriving at read makes "changed config ⇒ mismatch ⇒
  deny" true by construction.

  This is the *consent* identity. The supervisor's process-reconciliation
  digest is a different digest on purpose: it covers `timeout_ms` and the
  row's epoch (process identity), which consent has no business pinning.
  """

  alias Prima.JCS
  alias Prima.ToolPattern

  @doc "Compute the digest for a server's stored configuration."
  @spec compute(map()) :: {:ok, String.t()} | {:error, term()}
  def compute(
        %{
          id: id,
          transport: transport,
          mark: mark,
          url: url,
          enabled: enabled,
          headers: headers,
          backends: backends,
          program: program
        } = server
      )
      when is_binary(id) and
             ((transport == "http" and is_nil(mark)) or (transport == "program" and mark == "mcp")) and
             (is_binary(url) or is_nil(url)) and is_boolean(enabled) and is_map(headers) and
             is_list(backends) and
             ((transport == "http" and is_nil(program)) or
                (transport == "program" and is_map(program))) do
    with {:ok, backends} <- backend_templates(backends),
         :ok <- readable_hosts(program) do
      JCS.hash(
        %{
          "id" => id,
          "transport" => transport,
          "url" => url || "",
          "enabled" => enabled,
          "header_entries" => headers |> Enum.filter(&vault_bound?/1) |> templates(),
          "backends" => backends
        }
        |> with_program(mark, program)
      )
    else
      :error -> {:error, {:invalid_server_config, server}}
    end
  end

  def compute(other), do: {:error, {:invalid_server_config, other}}

  defp readable_hosts(%{"hosts" => hosts}) when not is_nil(hosts) do
    if is_list(hosts) and Enum.all?(hosts, &is_binary/1), do: :ok, else: :error
  end

  defp readable_hosts(_program), do: :ok

  # JCS takes no null, so an absent member is left out: a program's mark and
  # program members are present, each setting it has not left absent.
  defp with_program(document, nil, nil), do: document

  defp with_program(document, mark, program) do
    program =
      program
      |> Map.update("hosts", nil, &host_set/1)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.merge(document, %{"mark" => mark, "program" => program})
  end

  # What a program may reach is a set: its hosts in one order, each once.
  # Absent is no restriction, which a list, even an empty one, never reads as.
  defp host_set(hosts) when is_list(hosts), do: hosts |> Enum.uniq() |> Enum.sort()
  defp host_set(nil), do: nil

  defp vault_bound?({_name, template}), do: Prima.VaultRef.vault_ref?(template)

  defp templates(map) do
    map
    |> Enum.map(fn {name, template} ->
      %{"name" => to_string(name), "template" => to_string(template)}
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp backend_templates(backends) do
    backends
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => name, "command" => command} = backend, {:ok, acc}
      when is_binary(name) and is_binary(command) ->
        env = if is_map(backend["env"]), do: backend["env"], else: %{}

        entry = %{"name" => name, "command" => command, "env_templates" => templates(env)}
        {:cont, {:ok, [entry | acc]}}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1["name"])}
      :error -> :error
    end
  end

  @doc """
  The ONE place a peer's schema spelling is normalized on the way in.

  Some upstream servers publish `parameters` instead of `inputSchema`; both
  the descriptions digest (here) and the exposed tool definition
  (`Emissary.External.Proxy`) must apply the identical mapping, or the
  digest silently stops covering the schema it is supposed to pin.
  """
  def normalize_input_schema(tool) when is_map(tool) do
    tool["inputSchema"] || tool["parameters"] || %{}
  end

  @doc "The digest for a stored server row (`Arca.McpServerStorage`)."
  @spec from_server(map()) :: {:ok, String.t()} | {:error, term()}
  def from_server(server) do
    config = Arca.McpServerStorage.config(server)

    compute(%{
      id: server.id,
      transport: server.transport,
      mark: Map.get(server, :mark),
      url: server.url,
      enabled: server.enabled == true,
      headers: config["headers"] || %{},
      backends: config["backends"] || [],
      program: program(server)
    })
  end

  # What else decides what a program is and reaches, as its row stores it.
  # A stored host list that does not read leaves the row without a digest,
  # never with one that reads it as no restriction.
  defp program(%{transport: "program"} = server) do
    %{
      "hosts" => stored_hosts(Map.get(server, :hosts)),
      "home" => Map.get(server, :home),
      "login_entry" => Map.get(server, :login_entry_id),
      "memory_bytes" => Map.get(server, :memory_bytes),
      "home_max_bytes" => Map.get(server, :home_max_bytes),
      "login_command" => Map.get(server, :login_command)
    }
  end

  defp program(_server), do: nil

  defp stored_hosts(nil), do: nil

  defp stored_hosts(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, hosts} when is_list(hosts) -> hosts
      _ -> :unreadable
    end
  end

  defp stored_hosts(_other), do: :unreadable

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
  Digests descriptions and input schemas for tools matched by `patterns`.
  Returns `:unavailable` if a matched schema is outside the JCS domain;
  without a baseline, description drift cannot be checked.
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
