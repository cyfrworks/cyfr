# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Definition do
  @moduledoc """
  A program row's definition: the one command and environment its
  `config` holds (`validate/1`), the program settings a row carries beside
  them (`validate_row/1`), and the program a sync defines (`program/2`,
  `wire/1`).

  A program row runs one program on the backends service Locus serves
  (`Opus.Programs`), a shell command with an environment:

      %{"command" => "npx -y @modelcontextprotocol/server-github",
        "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token"}}

  On the wire the program is named `program_name/0`, the same for every
  row: the row itself is the owner the service runs it under.

  `validate/1` answers the definition normalized, or
  `{:error, {:invalid_argument, message}}`:

    * the config holds no key but `config_keys/0`;
    * the command meets `Prima.LocusBackends.check_command/1`: text beyond
      whitespace, at most `Prima.LocusBackends.max_command_bytes/0` bytes,
      no NUL byte and no `vault:` — every process on the service can read
      a command line, so a credential never goes in one;
    * an env name matches `^[A-Z_][A-Z0-9_]{0,63}$` and is none of the
      wire's reserved names (`Prima.LocusBackends.reserved_env_names/0`:
      `PATH HOME USER LOGNAME SHELL TMPDIR PWD`), nor prefixed with one of
      `Prima.LocusBackends.reserved_env_prefixes/0` (`CYFR_`, `LOCUS_`,
      `KEEPER_`) — the keeper sets the names, and the prefixes are CYFR's,
      Locus's and the keeper's, the list the keeper and the service refuse
      too;
    * an env value is a vault template (`Prima.VaultRef`); only the
      non-secret names in `Prima.LocusBackends.literal_env_names/0` may
      hold a literal, of at most 4096 bytes, instead;
    * the env names at most `Prima.LocusBackends.max_env_names/0`
      variables besides `TERM`, which a terminal is given when the env
      names none.

  `warnings/1` answers what a definition does that the administrator may
  choose but is told of, one sentence each: a command that holds one of
  its own vault-bound env names as an expansion (`$NAME`, `${NAME…}`,
  quoted or escaped alike), or, beside a vault-bound name, a command
  substitution, arithmetic expansion or indirection (`$(`, a backtick,
  `$[`, `${!`, `${ `, `${|`), read with its line continuations joined,
  places the value on the command line. The check reads the command's
  text, not what a program it starts does: `printenv NAME | xargs …` or a
  program that passes the value to a child puts it on a command line too.
  """

  alias Prima.{KeeperProtocol, LocusBackends, VaultRef}

  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @max_literal_bytes 4096
  @program_name "program"

  @program_keys ~w(mark home memory_bytes home_max_bytes hosts)
  # What a program's config may hold: its definition, its settings, and
  # the keys every row's config shares.
  @config_keys ~w(command env transport timeout_ms tool_patterns console) ++ @program_keys

  @typedoc "A validated definition: the command and its environment as stored."
  @type definition :: %{String.t() => String.t() | %{String.t() => String.t()}}

  @doc "The name every program goes by on the backends wire."
  @spec program_name() :: String.t()
  def program_name, do: @program_name

  @doc "The keys a program's config may hold."
  @spec config_keys() :: [String.t()]
  def config_keys, do: @config_keys

  @doc "Validate and normalize a program's config to its definition: its command and env."
  @spec validate(term()) :: {:ok, definition()} | {:error, {:invalid_argument, String.t()}}
  def validate(%{} = config) do
    with :ok <- only_keys(config),
         :ok <- check_command(config["command"]),
         {:ok, env} <- check_env(Map.get(config, "env") || %{}) do
      {:ok, %{"command" => config["command"], "env" => env}}
    end
  end

  def validate(_config), do: invalid("config must be an object")

  @doc "The vault entry names a definition's env templates reference, sorted and unique."
  @spec entry_names(term()) :: [String.t()]
  def entry_names(%{"env" => %{} = env}),
    do: env |> VaultRef.names() |> Enum.uniq() |> Enum.sort()

  def entry_names(_definition), do: []

  # The command runs as `/bin/sh -c command` (Locus.Backends.Backend), so a
  # vault-bound name the shell expands puts the disclosed value in a child's
  # argv, which every process on the backends service can read. The forms
  # that compute a value at run time can expand any name. A
  # backslash-newline is joined before the shell reads a word, so it is
  # joined here too.
  @computed ["$(", "`", "$[", "${!", "${ ", "${\t", "${\n", "${|"]

  @doc """
  The warnings a program's definition carries: each vault-bound env name
  its command expands, then, beside the vault-bound names it does not
  expand, the first form that computes a value when the shell runs it.
  Empty when there is nothing to warn of.
  """
  @spec warnings(term()) :: [String.t()]
  def warnings(%{"command" => command} = definition) when is_binary(command) do
    bound =
      case Map.get(definition, "env") do
        %{} = env -> for {key, value} <- Enum.sort(env), VaultRef.vault_ref?(value), do: key
        _absent -> []
      end

    text = String.replace(command, "\\\n", "")
    {expanded, beside} = Enum.split_with(bound, &expands?(text, &1))
    form = if beside != [], do: Enum.find(@computed, &String.contains?(text, &1))

    Enum.map(expanded, &warning({:expands, &1})) ++
      if(form, do: [warning({:computes, form, beside})], else: [])
  end

  def warnings(_definition), do: []

  defp expands?(text, key) do
    Regex.match?(~r/\$\{?#{Regex.escape(key)}(?![A-Za-z0-9_])/, text)
  end

  @exposed "on the command line, where every process on the backends service, other " <>
             "athanors' programs included, can read it; the safe route is to let the " <>
             "program read it from its environment"

  defp warning({:expands, var}) do
    "The command expands #{var}, a vault-bound env name: the value is placed #{@exposed}."
  end

  defp warning({:computes, form, vars}) do
    "The command has #{inspect(form)} beside the vault-bound #{Enum.join(vars, ", ")}: " <>
      "a command substitution, arithmetic expansion or indirection can place the value " <>
      "#{@exposed}."
  end

  # Aqua's two browsers: the person's, and the second, for work a
  # workspace thread keeps apart, each a row of its own.
  @browser_names %{person: "aqua-browser", apart: "aqua-browser-apart"}
  @browser_command "cyfr-browser"

  @typedoc "Which of Aqua's two browsers: the person's, or the one for work kept apart."
  @type chrome :: :person | :apart

  @doc """
  The name the row of Aqua's browser `chrome` goes by: the person's
  (`:person`), or the second, which a workspace thread opened apart uses
  (`:apart`).
  """
  @spec browser_name(chrome()) :: String.t()
  def browser_name(chrome \\ :person) when is_map_key(@browser_names, chrome),
    do: Map.fetch!(@browser_names, chrome)

  @doc "The command of Aqua's browser: the browser driver."
  @spec browser_command() :: String.t()
  def browser_command, do: @browser_command

  # The profile; the Chromium it runs is the image's.
  @browser_home_bytes 2 * 1024 * 1024 * 1024

  @doc """
  Aqua's browser as the config of the row a person adds once
  (`mcp_servers.create`, confirmed as any program's definition is), which
  the Programs page's form is filled from: the browser driver's command,
  which starts the image's Chromium over its debugging pipe inside the
  box, with no environment, driven, in the row's kept folder, which holds
  its profile, bounded at `memory_bytes` and its folder at 2 GiB.
  """
  @spec browser(pos_integer()) :: map()
  def browser(memory_bytes) when is_integer(memory_bytes) do
    %{
      "transport" => "program",
      "command" => @browser_command,
      "env" => %{},
      "mark" => "driven",
      "home" => "kept",
      "memory_bytes" => memory_bytes,
      "home_max_bytes" => @browser_home_bytes
    }
  end

  @doc """
  Whether a stored row is one of Aqua's browsers: named by
  `browser_name/1`, the driver's command with no environment, driven, in
  a kept folder. Each of the two has its own folder, so its own profile,
  and its hosts and bounds are the person's to set, as any program's are;
  a row of either name with any other command, an environment, another
  mark or a scratch folder is not the browser.
  """
  @spec browser?(map()) :: boolean()
  def browser?(%{name: name, transport: "program", mark: "driven", home: "kept"} = row)
      when is_binary(name) do
    config = Arca.McpServerStorage.config(row)

    name in Map.values(@browser_names) and config["command"] == @browser_command and
      Map.get(config, "env", %{}) in [nil, %{}]
  end

  def browser?(_row), do: false

  # The program brains CYFR ships a driver for: the row's name, the title a
  # person reads, and the command its install form is prefilled with, the
  # driver first and the harness at the version its driver was probed
  # against. `Arca.McpServerStorage.driver/1` is the one list of driver
  # words; a test holds each command to it.
  @brains [
    %{
      name: "claude-code",
      title: "Claude Code",
      command: "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323"
    },
    %{
      name: "openai-codex",
      title: "OpenAI Codex",
      command: "cyfr-codex npx -y @openai/codex@0.169.0"
    },
    # Antigravity is no npm package: `cyfr-fetch` fetches Google's release of
    # it at its version, checked against its SHA-512, into the row's folder.
    %{
      name: "antigravity",
      title: "Antigravity",
      command:
        "cyfr-antigravity cyfr-fetch agy 1.5.16 " <>
          "amd64=https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.16-5250855658717184/linux-x64/cli_linux_x64.tar.gz" <>
          "#3dee9f26e298156db673f6ce2a0f5dfed5b30006e04ceb9809c68070e7b717587b33a3da0f8bc2eda45af81a50bc8b14c82b28ae5832bcfe3e7fd49397117b31 " <>
          "arm64=https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.16-5250855658717184/linux-arm/cli_linux_arm64.tar.gz" <>
          "#23c193151499a4986fd5fa0d8132665cc8ffbad6cc0b3ff4fd53a2cb68abb76b149a992b836d53063443cd89add335f14d8134fb02abdcecbf6e1eaef6c53d33"
    },
    # OpenCode's npm package fetches every Linux build of it; `cyfr-fetch`
    # fetches the one release archive for the machine instead.
    %{
      name: "opencode",
      title: "OpenCode",
      command:
        "cyfr-opencode cyfr-fetch opencode 2.4.1 " <>
          "amd64=https://github.com/anomalyco/opencode/releases/download/v2.4.1/opencode-linux-x64.tar.gz" <>
          "#c691f7840dd3429952c6508b0bad427f1e8611f2038b339c4ba3a78dfadcbca27eeb492e76d30d06733e3a37a8eea944e90ccff960b5f5a5d3aa43674873b2b9 " <>
          "arm64=https://github.com/anomalyco/opencode/releases/download/v2.4.1/opencode-linux-arm64.tar.gz" <>
          "#2b72b08a1a2f8a8784d6c272b551578ff98bc6c67ff44c137e70aaeceece50a9dce2810c084405ecfcb61b7b7e8754d1f0450e7030107741ccda6655d25e5582"
    }
  ]

  @typedoc "A program brain CYFR ships a driver for (`brains/0`)."
  @type brain :: %{name: String.t(), title: String.t(), command: String.t()}

  @doc """
  The program brains a person can connect, in the order Aqua's setup
  lists them: each a driven row with a kept folder, named `name`, whose
  command is `command`. The one source of a brain's install: the Programs
  page's form is prefilled from it (`/programs?add=<name>`) for the person
  to confirm or change, and it runs nothing itself.
  """
  @spec brains() :: [brain()]
  def brains, do: @brains

  @doc "The program brain named `name` (`brains/0`), or nil."
  @spec brain(String.t()) :: brain() | nil
  def brain(name) when is_binary(name), do: Enum.find(@brains, &(&1.name == name))

  @typedoc "One program a sync defines, its environment as stored (templates unresolved)."
  @type program :: %{
          name: String.t(),
          command: String.t(),
          env: %{String.t() => String.t()},
          home: :scratch | :kept,
          memory_bytes: pos_integer() | nil,
          home_max_bytes: pos_integer() | nil,
          hosts: [String.t(), ...] | nil
        }

  @doc """
  The program settings a row carries beside its definition, checked: the
  `transport` is `program` (an `http` row has none); its `mark` is `mcp`
  or `driven`; `home` is `"scratch"` or `"kept"`, a kept home being the
  row's own folder; `memory_bytes` lies in the keeper's range;
  `home_max_bytes` is a kept home's alone, at least 1 MiB; `hosts`, the only hosts the
  program reaches beside the resolver and the deployment's private hosts,
  is a list the keeper takes (`Prima.KeeperProtocol.valid_hosts?/1`: 1 to
  32 distinct exact hostnames, no wildcard, scheme, port or trailing dot),
  stored as its JSON text; absent, the program reaches public hosts.
  Answers the columns to store, every one named (nil when absent), or
  `{:error, {:invalid_argument, message}}`.
  """
  @spec validate_row(map()) :: {:ok, map()} | {:error, {:invalid_argument, String.t()}}
  def validate_row(%{"transport" => "program"} = config) do
    home = Map.get(config, "home") || "scratch"
    mark = config["mark"]

    with :ok <- check_mark(mark),
         :ok <- check_home(home),
         :ok <- check_memory(config["memory_bytes"]),
         :ok <- check_home_max(home, config["home_max_bytes"]),
         {:ok, hosts} <- check_hosts(config["hosts"]) do
      {:ok,
       %{
         mark: mark,
         home: home,
         memory_bytes: config["memory_bytes"],
         home_max_bytes: config["home_max_bytes"],
         hosts: hosts
       }}
    end
  end

  def validate_row(_config), do: invalid("Only a row whose transport is program is a program")

  @doc "The config keys that are a program's settings, stored as columns rather than in `config_json`."
  @spec program_keys() :: [String.t()]
  def program_keys, do: @program_keys

  defp check_mark(mark) when mark in ["mcp", "driven"], do: :ok

  defp check_mark(_mark),
    do:
      invalid(
        "config.mark must be mcp (CYFR speaks MCP to it) or driven " <>
          "(a person or a crew member runs it)"
      )

  defp check_home(home) when home in ["scratch", "kept"], do: :ok
  defp check_home(_home), do: invalid("config.home must be scratch or kept")

  defp check_memory(nil), do: :ok

  defp check_memory(bytes) when is_integer(bytes) do
    if bytes >= KeeperProtocol.min_memory_bytes() and bytes <= KeeperProtocol.max_memory_bytes(),
      do: :ok,
      else:
        invalid(
          "config.memory_bytes must be from #{KeeperProtocol.min_memory_bytes()} to " <>
            "#{KeeperProtocol.max_memory_bytes()} bytes"
        )
  end

  defp check_memory(_bytes), do: invalid("config.memory_bytes must be a whole number of bytes")

  @min_home_bytes 1_048_576

  defp check_home_max(_home, nil), do: :ok

  defp check_home_max("kept", bytes) when is_integer(bytes) do
    max = KeeperProtocol.request_bounds().max_home_bytes

    if bytes >= @min_home_bytes and bytes <= max,
      do: :ok,
      else: invalid("config.home_max_bytes must be from #{@min_home_bytes} to #{max} bytes")
  end

  defp check_home_max("kept", _bytes),
    do: invalid("config.home_max_bytes must be a whole number of bytes")

  defp check_home_max(_home, _bytes),
    do: invalid("config.home_max_bytes bounds a kept home: set config.home to kept")

  defp check_hosts(nil), do: {:ok, nil}

  defp check_hosts(hosts) do
    if KeeperProtocol.valid_hosts?(hosts),
      do: {:ok, Jason.encode!(hosts)},
      else:
        invalid(
          "config.hosts names 1 to #{KeeperProtocol.request_bounds().max_hosts} distinct " <>
            "hostnames, each exact and lowercase: no wildcard, scheme, port or trailing dot"
        )
  end

  @doc """
  A row's settings as its `config` shows them: each program key it holds,
  `hosts` as the list it stores. An `http` row holds none.
  """
  @spec settings(map()) :: %{String.t() => term()}
  def settings(%{transport: "http"}), do: %{}

  def settings(row) do
    for key <- @program_keys,
        value = setting(row, key),
        value != nil,
        into: %{},
        do: {key, value}
  end

  defp setting(row, "hosts") do
    case stored_hosts(row) do
      {:ok, hosts} -> hosts
      {:error, _} -> Map.get(row, :hosts)
    end
  end

  defp setting(row, key), do: Map.get(row, String.to_existing_atom(key))

  # The stored network list: absent, or the JSON text of a list the keeper
  # takes. Anything else is refused, never read as no list, which would
  # open the program to every public host.
  defp stored_hosts(row) do
    case Map.get(row, :hosts) do
      nil ->
        {:ok, nil}

      text when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, hosts} ->
            if KeeperProtocol.valid_hosts?(hosts), do: {:ok, hosts}, else: unreadable()

          {:error, _} ->
            unreadable()
        end

      _other ->
        unreadable()
    end
  end

  defp unreadable, do: invalid("The program's stored hosts do not read; save the program again")

  @doc """
  The program a stored row defines from its validated definition, with the
  row's program settings, or the refusal of a row whose stored hosts do
  not read.
  """
  @spec program(map(), definition()) ::
          {:ok, program()} | {:error, {:invalid_argument, String.t()}}
  def program(row, %{"command" => command, "env" => env}) do
    with {:ok, hosts} <- stored_hosts(row) do
      {:ok,
       %{
         name: @program_name,
         command: command,
         env: env,
         home: if(Map.get(row, :home) == "kept", do: :kept, else: :scratch),
         memory_bytes: Map.get(row, :memory_bytes),
         home_max_bytes: Map.get(row, :home_max_bytes),
         hosts: hosts
       }}
    end
  end

  @doc "A program as a sync names it on the wire (`Prima.LocusBackends`): its env names, never its values."
  @spec wire(program()) :: LocusBackends.program()
  def wire(program) do
    %{
      name: program.name,
      command: program.command,
      env_names: program.env |> Map.keys() |> Enum.sort(),
      home: program.home,
      memory_bytes: program.memory_bytes,
      home_max_bytes: program.home_max_bytes,
      hosts: program.hosts
    }
  end

  defp only_keys(config) do
    case Map.keys(config) -- @config_keys do
      [] -> :ok
      extra -> invalid("config has unknown keys: #{Enum.join(Enum.sort(extra), ", ")}")
    end
  end

  # The command rule is `Prima.LocusBackends.check_command/1`'s; the
  # sentences are this surface's.
  defp check_command(command) do
    case LocusBackends.check_command(command) do
      :ok ->
        :ok

      {:error, :not_a_string} ->
        invalid("A program needs a command string: config.command")

      {:error, :empty} ->
        invalid("A program needs a command: config.command")

      {:error, :too_long} ->
        invalid("config.command is longer than #{LocusBackends.max_command_bytes()} bytes")

      {:error, :nul} ->
        invalid("config.command has a NUL byte")

      {:error, :vault_reference} ->
        invalid(
          "config.command names a vault entry — command lines are visible to every " <>
            "process on the backends service; pass it through config.env instead"
        )
    end
  end

  defp check_env(env) when is_map(env) do
    with :ok <- env_count(env) do
      check_env_entries(env)
    end
  end

  defp check_env(_env), do: invalid("config.env must be an object")

  defp env_count(env) do
    max = LocusBackends.max_env_names()

    if map_size(Map.delete(env, "TERM")) <= max,
      do: :ok,
      else: invalid("config.env names at most #{max} variables besides TERM")
  end

  defp check_env_entries(env) do
    env
    |> Enum.sort()
    |> each(fn {key, value} -> env_entry(key, value) end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp env_entry(key, value) when is_binary(key) and is_binary(value) do
    cond do
      not Regex.match?(@env_name, key) ->
        invalid("config.env name #{inspect(key)} must match #{Regex.source(@env_name)}")

      key in LocusBackends.reserved_env_names() or
          String.starts_with?(key, LocusBackends.reserved_env_prefixes()) ->
        invalid("config.env name #{key} is reserved")

      VaultRef.unresolved_ref?(value) ->
        invalid(
          "config.env #{key} names a reference this server does not resolve — " <>
            "use \"vault:ENTRY\""
        )

      VaultRef.vault_ref?(value) ->
        {:ok, {key, value}}

      key not in LocusBackends.literal_env_names() ->
        invalid(
          "config.env #{key} must reference a vault entry (\"vault:ENTRY\"); " <>
            "only #{Enum.join(LocusBackends.literal_env_names(), ", ")} may hold a literal"
        )

      byte_size(value) > @max_literal_bytes or String.contains?(value, <<0>>) ->
        invalid("config.env #{key} is not a valid value")

      true ->
        {:ok, {key, value}}
    end
  end

  defp env_entry(key, _value), do: invalid("config.env #{inspect(key)} must be a string value")

  defp each(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp invalid(message), do: {:error, {:invalid_argument, message}}
end
