# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigest do
  @moduledoc """
  What a consent records of a tool server, and the digest a grant's
  tool_server resource pins: both from one definition, so the record a
  grant and a preview show and the digest a use is checked against cannot
  drift.

  `recorded/1` is what is recorded of a row, everything that decides what
  it is and reaches but a literal's value, nothing a person may not read:
  its address (an http row's url, a program's command) and each header
  (http) or environment variable (program) by its name with the vault
  entry it names, a literal by its name alone, marked literal; and a
  program's settings: its `folder` (`"kept"`, the row's own folder kept
  between runs, or `"scratch"`), its `hosts` (the set of names it
  reaches, sorted, each once; absent, every public host, which `[]`
  never reads as), its `memory_bytes` and `home_max_bytes` bounds and its
  `sign_in_command`, each absent when the row leaves it unset:

      %{"address" => "https://mcp.example/v1",
        "headers" => [%{"name" => "authorization", "entry" => "github", "scheme" => "Bearer"},
                      %{"name" => "user-agent", "literal" => true}]}

      %{"address" => "npx -y @modelcontextprotocol/server-github",
        "env" => [%{"name" => "GITHUB_TOKEN", "entry" => "gh"},
                  %{"name" => "NODE_ENV", "literal" => true}],
        "folder" => "kept",
        "hosts" => ["api.github.com", "github.com"],
        "memory_bytes" => 268435456,
        "home_max_bytes" => 1073741824,
        "sign_in_command" => "gh auth login"}

  A literal's value is never recorded: it is a secret the page never sees.

  The digest is `JCS({id, transport, enabled, mark, record, literals})`:
  the record, each literal's value by its name beside it (`literals`),
  and the row's identity, never resolved values. Rotating a referenced
  vault entry must not move the digest, while each of these must, so a
  definition that reaches more no longer matches a grant made for the
  old one and the person is asked again at use:

    * everything the record holds: the address whole (scheme, host, port
      and path; a program's command), every header and env name with the
      entry it names and its scheme, and a program's settings. A name
      added, removed or pointed at another entry moves the digest; a
      vault entry rotated in place does not;
    * a literal's value, since a peer may route on any header (a literal
      `Host` sends the call and its credentials elsewhere);
    * the row's id, so a row deleted and made again under its name does,
      and whether it is enabled.

  So a record that is the same under a moved digest is a value the record
  does not show that moved: a literal's, the row's id or whether it is
  enabled.

  The server's tool patterns and its timeout are left out: a grant
  carries its own patterns and only ever reaches their intersection with
  the server's (`tool_patterns/1`). An http row has no mark, command, env
  or program settings; a program has no url.

  Every row has this digest (`definition/1`), and it is the one answer to
  whether a row's definition changed: a program's change asks its
  confirmation exactly when it moves the digest
  (`Emissary.External.Provider`), and a login need's binding of a driven
  program is approved at it (`Sanctum.Mount`), so a binding made for one
  definition does not mount another. A grant's tool_server resource pins
  it only of a tool server (`from_server/1`): an `http` row or a program
  marked `mcp`; a `driven` program offers no tools.

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
  @type server_record :: %{
          required(String.t()) => String.t() | pos_integer() | [map() | String.t()]
        }

  @doc "Compute the digest for a server's stored configuration."
  @spec compute(map()) :: {:ok, String.t()} | {:error, term()}
  def compute(server) do
    with {:ok, record, literals} <- record_of(server) do
      %{
        "id" => server.id,
        "transport" => server.transport,
        "enabled" => server.enabled,
        "record" => record,
        "literals" => literals
      }
      |> put_present("mark", server.mark)
      |> JCS.hash()
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
    if transport == "http" do
      {:ok, %{"address" => url, "headers" => named(headers)}, literals(headers)}
    else
      case settings(program) do
        {:ok, settings} ->
          {:ok, Map.merge(settings, %{"address" => command, "env" => named(env)}), literals(env)}

        :error ->
          {:error, {:invalid_server_config, server}}
      end
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

  # A program's settings as the record holds them, each one it leaves
  # unset absent: JCS takes no null, and absent hosts (every public host)
  # must never read as a list. A setting that does not read leaves the row
  # without a record, never with one that reads it as wider.
  defp settings(%{"home" => folder} = program) when folder in ["kept", "scratch"] do
    with {:ok, hosts} <- host_set(program["hosts"]),
         true <- Enum.all?(["memory_bytes", "home_max_bytes"], &bound?(program[&1])),
         true <- is_nil(program["login_command"]) or nonempty?(program["login_command"]) do
      {:ok,
       %{"folder" => folder}
       |> put_present("hosts", hosts)
       |> put_present("memory_bytes", program["memory_bytes"])
       |> put_present("home_max_bytes", program["home_max_bytes"])
       |> put_present("sign_in_command", program["login_command"])}
    else
      _unreadable -> :error
    end
  end

  defp settings(_program), do: :error

  # What a program may reach is a set: its hosts in one order, each once.
  defp host_set(nil), do: {:ok, nil}

  defp host_set(hosts) when is_list(hosts) do
    if Enum.all?(hosts, &nonempty?/1),
      do: {:ok, hosts |> Enum.uniq() |> Enum.sort()},
      else: :error
  end

  defp host_set(_hosts), do: :error

  defp bound?(bytes), do: is_nil(bytes) or (is_integer(bytes) and bytes > 0)

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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

  @doc """
  The digest of a stored row's definition (`Arca.McpServerStorage`), of
  any transport and mark, `{:error, {:invalid_server_config, _}}` for one
  whose record does not read. A row an add or an update would store reads
  the same way, its `id` the stored row's.
  """
  @spec definition(map()) :: {:ok, String.t()} | {:error, term()}
  def definition(server), do: server |> fields() |> compute()

  @doc """
  The digest a grant's tool_server resource pins of a stored tool server:
  its `definition/1`. A `driven` program is no tool server and has none.
  """
  @spec from_server(map()) :: {:ok, String.t()} | {:error, term()}
  def from_server(%{transport: "program", mark: "driven"} = server),
    do: {:error, {:invalid_server_config, server}}

  def from_server(server), do: definition(server)

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

  # A program's settings as its row stores them (`settings/1` records
  # them). A stored host list that does not read leaves the row without a
  # record, never with one that reads it as no restriction.
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
