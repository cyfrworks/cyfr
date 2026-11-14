# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigest do
  @moduledoc """
  What a consent records of a tool server, and the digest a grant's
  tool_server resource pins: both from one definition, so the record a
  grant and a preview show and the digest a use is checked against cannot
  drift.

  `recorded/1` is what is recorded of a row, nothing a person may not
  read: its address (an http row's url, a program's command) and each
  header (http) or environment variable (program) by its name with the
  vault entry it names, a literal by its name alone, marked literal:

      %{"address" => "https://mcp.example/v1",
        "headers" => [%{"name" => "authorization", "entry" => "github", "scheme" => "Bearer"},
                      %{"name" => "user-agent", "literal" => true}]}

      %{"address" => "npx -y @modelcontextprotocol/server-github",
        "env" => [%{"name" => "GITHUB_TOKEN", "entry" => "gh"},
                  %{"name" => "NODE_ENV", "literal" => true}]}

  A literal's value is never recorded: it is a secret the page never sees.

  The digest is `JCS({id, transport, enabled, record, literals, mark,
  program})`: the record, and what it must cover beyond it, never
  resolved values. Rotating a referenced vault entry must not move the
  digest, while each of these must, so a definition that reaches more no
  longer matches a grant made for the old one and the person is asked
  again at use:

    * the address whole (scheme, host, port and path; a program's command);
    * every header and env name with its template, through the record: a
      vault-bound one by the entry it names and its scheme, and a literal,
      beside the record, by its value (`literals`), since a peer may route
      on any header (a literal `Host` sends the call and its credentials
      elsewhere). A name added, removed, pointed at another entry or given
      another literal moves the digest; a vault entry rotated in place
      does not;
    * a program's mark and its `program` member, everything else that
      decides what it is and reaches, each setting it holds: its hosts
      (the set of names, in one order; absent, every public host), its
      home (a kept home is the row's own folder, named by the row's id),
      its memory and disk bounds and its sign-in command;
    * the row's id, so a row deleted and made again under its name does.

  So a record that is the same under a moved digest is a literal's value,
  or a setting beyond the record, that moved.

  The server's tool patterns and its timeout are left out: a grant
  carries its own patterns and only ever reaches their intersection with
  the server's (`tool_patterns/1`). An http row has no mark, command, env
  or program; a program has no url.
  Only a tool server has a digest: an `http` row or a program marked
  `mcp`; a `driven` program offers no tools. A program of either mark is
  recorded: its install confirmation shows and binds the record
  (`Emissary.External.Provider`).

  There is deliberately no stored digest column — a stored digest is a cache someone
  forgets to recompute; deriving at read makes "changed config ⇒ mismatch ⇒
  deny" true by construction.

  This is the *consent* identity. The supervisor's process-reconciliation
  digest is a different digest on purpose: it covers `timeout_ms` and the
  row's epoch (process identity), which consent has no business pinning.
  """

  alias Prima.JCS
  alias Prima.ToolPattern
  alias Prima.VaultRef

  @typedoc "What is recorded of a tool server (`recorded/1`)."
  @type server_record :: %{required(String.t()) => String.t() | [map()]}

  @doc "Compute the digest for a server's stored configuration."
  @spec compute(map()) :: {:ok, String.t()} | {:error, term()}
  def compute(%{mark: "driven"} = server), do: {:error, {:invalid_server_config, server}}

  def compute(server) do
    with {:ok, record, literals} <- record_of(server) do
      JCS.hash(
        %{
          "id" => server.id,
          "transport" => server.transport,
          "enabled" => server.enabled,
          "record" => record,
          "literals" => literals
        }
        |> with_program(server.mark, server.program)
      )
    end
  end

  @doc """
  What is recorded of a stored server row (`Arca.McpServerStorage`) as
  the moduledoc shows it, `{:error, {:invalid_server_config, _}}` for one
  that is no tool server or does not read.
  """
  @spec recorded(map()) :: {:ok, server_record()} | {:error, term()}
  def recorded(server) do
    with {:ok, record, _literals} <- server |> fields() |> record_of(), do: {:ok, record}
  end

  # The record and, beside it, each literal's value by its name: what the
  # digest covers that the record must not carry.
  defp record_of(
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
              ((transport == "http" and is_binary(url) and is_nil(mark) and is_nil(command) and
                  is_nil(env) and is_nil(program)) or
                 (transport == "program" and is_nil(url) and mark in ["mcp", "driven"] and
                    is_binary(command) and is_map(env) and is_map(program))) and
              is_boolean(enabled) and is_map(headers) do
    {address, member, values} =
      if transport == "http", do: {url, "headers", headers}, else: {command, "env", env}

    case readable_hosts(program) do
      :ok ->
        {:ok, %{"address" => address, member => named(values)}, literals(values)}

      :error ->
        {:error, {:invalid_server_config, server}}
    end
  end

  defp record_of(other), do: {:error, {:invalid_server_config, other}}

  # Each name with the entry it names, or marked literal, in name order.
  defp named(values) do
    values
    |> Enum.map(fn {name, value} ->
      case VaultRef.template(value) do
        {:ok, %{scheme: nil, name: entry}} ->
          %{"name" => to_string(name), "entry" => entry}

        {:ok, %{scheme: scheme, name: entry}} ->
          %{"name" => to_string(name), "entry" => entry, "scheme" => scheme}

        :error ->
          %{"name" => to_string(name), "literal" => true}
      end
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp literals(values) do
    for {name, value} <- values, not VaultRef.vault_ref?(value), into: %{} do
      {to_string(name), to_string(value)}
    end
  end

  defp readable_hosts(%{"hosts" => hosts}) when not is_nil(hosts) do
    if is_list(hosts) and Enum.all?(hosts, &is_binary/1), do: :ok, else: :error
  end

  defp readable_hosts(_program), do: :ok

  # JCS takes no null, so an absent member is left out: a program's mark
  # and program members are present, each setting it has not left absent.
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
  def from_server(server), do: server |> fields() |> compute()

  # A stored row as `compute/1` and `recorded/1` read it.
  defp fields(server) do
    config = Arca.McpServerStorage.config(server)

    %{
      id: server.id,
      transport: server.transport,
      mark: Map.get(server, :mark),
      url: server.url,
      enabled: server.enabled == true,
      headers: config["headers"] || %{},
      command: if(server.transport == "program", do: config["command"]),
      env: if(server.transport == "program", do: config["env"] || %{}),
      program: program(server)
    }
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
