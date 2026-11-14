# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigest do
  @moduledoc """
  External MCP configuration digest pinned by a consent tool_server resource.

  `JCS({id, transport, mark, url, enabled, header_templates, command,
  env_templates, program})` over what decides where the server's calls go and which
  credentials ride along, never resolved values: rotating a referenced
  vault entry must not move the digest, while each of these must, so a
  definition that reaches more no longer matches a grant made for the old
  one and the person is asked again at use:

    * the address whole (scheme, host, port and path);
    * every header, by its name and its template (`header_templates`): a
      vault-bound one by the entry it names, a literal by its value, since
      a peer may route on any header (a literal `Host` sends the call and
      its credentials elsewhere). A header added, removed, pointed at
      another entry or given another literal moves the digest; a vault
      entry rotated in place does not;
    * a program's command and its env, every name with its template
      (`env_templates`), a literal by its value as a header's is, and its
      `program` member, everything else that decides what it is and what
      it reaches, each setting it holds: its hosts (the set of names, in
      one order; absent, every public host), its home (a kept home is the
      row's own folder, named by the row's id), its memory and disk bounds
      and its sign-in command;
    * the row's id, so a row deleted and made again under its name does.

  The server's tool patterns and its timeout are left out: a grant
  carries its own patterns and only ever reaches their intersection with
  the server's (`tool_patterns/1`). An http row has no mark, command, env
  or program; a program's `url` is the empty string.
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
          command: command,
          env: env,
          program: program
        } = server
      )
      when is_binary(id) and
             ((transport == "http" and is_nil(mark) and is_nil(command) and is_nil(env) and
                 is_nil(program)) or
                (transport == "program" and mark == "mcp" and is_binary(command) and is_map(env) and
                   is_map(program))) and
             (is_binary(url) or is_nil(url)) and is_boolean(enabled) and is_map(headers) do
    case readable_hosts(program) do
      :ok ->
        JCS.hash(
          %{
            "id" => id,
            "transport" => transport,
            "url" => url || "",
            "enabled" => enabled,
            "header_templates" => templates(headers)
          }
          |> with_program(mark, command, env, program)
        )

      :error ->
        {:error, {:invalid_server_config, server}}
    end
  end

  def compute(other), do: {:error, {:invalid_server_config, other}}

  defp readable_hosts(%{"hosts" => hosts}) when not is_nil(hosts) do
    if is_list(hosts) and Enum.all?(hosts, &is_binary/1), do: :ok, else: :error
  end

  defp readable_hosts(_program), do: :ok

  # JCS takes no null, so an absent member is left out: a program's mark,
  # command, env and program members are present, each setting it has not
  # left absent.
  defp with_program(document, nil, nil, nil, nil), do: document

  defp with_program(document, mark, command, env, program) do
    program =
      program
      |> Map.update("hosts", nil, &host_set/1)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.merge(document, %{
      "mark" => mark,
      "command" => command,
      "env_templates" => templates(env),
      "program" => program
    })
  end

  # What a program may reach is a set: its hosts in one order, each once.
  # Absent is no restriction, which a list, even an empty one, never reads as.
  defp host_set(hosts) when is_list(hosts), do: hosts |> Enum.uniq() |> Enum.sort()
  defp host_set(nil), do: nil

  defp templates(map) do
    map
    |> Enum.map(fn {name, template} ->
      %{"name" => to_string(name), "template" => to_string(template)}
    end)
    |> Enum.sort_by(& &1["name"])
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
      command: if(server.transport == "program", do: config["command"]),
      env: if(server.transport == "program", do: config["env"] || %{}),
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
