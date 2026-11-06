# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Definition do
  @moduledoc """
  A program row's definition: what `config.backends` may hold, the program
  settings a row carries beside it (`validate_row/1`), and the programs a
  sync defines (`programs/2`, `wire/1`).

  A `stdio` or `pipe` row runs its backends on the backends service Locus
  serves (`Opus.Programs`), each a shell command with an environment:

      [%{"name" => "github", "command" => "npx -y @modelcontextprotocol/server-github",
         "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token"}}]

  `validate/1` accepts a list of at most `max_backends/0` backends (4)
  and answers it normalized, or
  `{:error, {:invalid_argument, message}}`:

    * a name matches `^[a-z0-9][a-z0-9-]{0,31}$` and is unique;
    * a command meets `Prima.LocusBackends.check_command/1`: text beyond
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
      hold a literal, of at most 4096 bytes, instead.

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

  @name ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @max_literal_bytes 4096
  @max_backends 4

  @typedoc "One validated backend."
  @type backend :: %{String.t() => String.t() | %{String.t() => String.t()}}

  @doc "The most backends one server may define."
  @spec max_backends() :: pos_integer()
  def max_backends, do: @max_backends

  @doc "Validate and normalize a stdio server's backends."
  @spec validate(term()) :: {:ok, [backend()]} | {:error, {:invalid_argument, String.t()}}
  def validate(backends) when is_list(backends) do
    cond do
      backends == [] ->
        invalid("A stdio server needs at least one backend")

      length(backends) > max_backends() ->
        invalid("A stdio server defines at most #{max_backends()} backends")

      true ->
        with {:ok, normalized} <- each(backends, &backend/1),
             :ok <- unique_names(normalized) do
          {:ok, normalized}
        end
    end
  end

  def validate(_backends), do: invalid("config.backends must be a list of backends")

  @doc "The vault entry names the backends' env templates reference, sorted and unique."
  @spec entry_names(term()) :: [String.t()]
  def entry_names(backends) when is_list(backends) do
    backends
    |> Enum.flat_map(fn
      %{"env" => %{} = env} -> VaultRef.names(env)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def entry_names(_backends), do: []

  @doc """
  The warnings a stdio server's backends carry, in backend order: each
  vault-bound env name a command expands, then, beside the vault-bound
  names it does not expand, the first form that computes a value when the
  shell runs it. Empty when there is nothing to warn of.
  """
  @spec warnings(term()) :: [String.t()]
  def warnings(backends) when is_list(backends), do: Enum.flat_map(backends, &backend_warnings/1)
  def warnings(_backends), do: []

  # The command runs as `/bin/sh -c command` (Locus.Backends.Backend), so a
  # vault-bound name the shell expands puts the disclosed value in a child's
  # argv, which every process on the backends service can read. The forms
  # that compute a value at run time can expand any name. A
  # backslash-newline is joined before the shell reads a word, so it is
  # joined here too.
  @computed ["$(", "`", "$[", "${!", "${ ", "${\t", "${\n", "${|"]

  defp backend_warnings(%{"name" => name, "command" => command} = backend)
       when is_binary(command) do
    bound =
      case Map.get(backend, "env") do
        %{} = env -> for {key, value} <- Enum.sort(env), VaultRef.vault_ref?(value), do: key
        _absent -> []
      end

    text = String.replace(command, "\\\n", "")
    {expanded, beside} = Enum.split_with(bound, &expands?(text, &1))
    form = if beside != [], do: Enum.find(@computed, &String.contains?(text, &1))

    Enum.map(expanded, &warning(name, {:expands, &1})) ++
      if(form, do: [warning(name, {:computes, form, beside})], else: [])
  end

  defp backend_warnings(_backend), do: []

  defp expands?(text, key) do
    Regex.match?(~r/\$\{?#{Regex.escape(key)}(?![A-Za-z0-9_])/, text)
  end

  @exposed "on the command line, where every process on the backends service, other " <>
             "athanors' backends included, can read it; the safe route is to let the " <>
             "program read it from its environment"

  defp warning(backend, {:expands, var}) do
    "Backend '#{backend}' expands #{var}, a vault-bound env name, in its command: " <>
      "the value is placed #{@exposed}."
  end

  defp warning(backend, {:computes, form, vars}) do
    "Backend '#{backend}' has #{inspect(form)} in its command beside the vault-bound " <>
      "#{Enum.join(vars, ", ")}: a command substitution, arithmetic expansion or " <>
      "indirection can place the value #{@exposed}."
  end

  @typedoc "One program a sync defines, its environment as stored (templates unresolved)."
  @type program :: %{
          name: String.t(),
          command: String.t(),
          env: %{String.t() => String.t()},
          login_command: String.t() | nil,
          home: :scratch | :kept,
          memory_bytes: pos_integer() | nil,
          home_max_bytes: pos_integer() | nil,
          hosts: [String.t(), ...] | nil
        }

  @doc """
  The program settings a row carries beside its backends, checked: a
  `transport` of `stdio` or `pipe` (an `http` row has none); a `pipe` row
  has exactly one backend, the program its catalyst drives; `home` is
  `"scratch"` or `"kept"`, and a kept `stdio` row names the login entry its
  sessions run in (`login_entry_id`; whether it is one is the caller's to
  check); `memory_bytes` lies in the keeper's range; `home_max_bytes` is a
  kept home's alone, at least 1 MiB; `login_command` meets
  `Prima.LocusBackends.check_command/1`; `hosts`, the only hosts the
  program reaches beside the resolver and the deployment's private hosts,
  is a list the keeper takes (`Prima.KeeperProtocol.valid_hosts?/1`: 1 to
  32 distinct exact hostnames, no wildcard, scheme, port or trailing dot),
  stored as its JSON text; absent, the program reaches public hosts.
  Answers the columns to store, every one named (nil when absent), or
  `{:error, {:invalid_argument, message}}`.
  """
  @spec validate_row(map()) :: {:ok, map()} | {:error, {:invalid_argument, String.t()}}
  def validate_row(%{"transport" => transport} = config) when transport in ["stdio", "pipe"] do
    home = Map.get(config, "home") || "scratch"

    with :ok <- one_program(transport, config["backends"]),
         :ok <- check_home(home),
         :ok <- check_memory(config["memory_bytes"]),
         :ok <- check_home_max(home, config["home_max_bytes"]),
         :ok <- check_login_command(config["login_command"]),
         {:ok, entry} <- check_login_entry(transport, home, config["login_entry_id"]),
         {:ok, hosts} <- check_hosts(config["hosts"]) do
      {:ok,
       %{
         home: home,
         memory_bytes: config["memory_bytes"],
         home_max_bytes: config["home_max_bytes"],
         login_command: config["login_command"],
         login_entry_id: entry,
         hosts: hosts
       }}
    end
  end

  def validate_row(_config), do: invalid("Only a stdio or pipe server is a program")

  @program_keys ~w(home memory_bytes home_max_bytes login_command login_entry_id hosts)

  @doc "The config keys that are a program's settings, stored as columns rather than in `config_json`."
  @spec program_keys() :: [String.t()]
  def program_keys, do: @program_keys

  defp one_program("pipe", backends) when is_list(backends) and length(backends) != 1,
    do: invalid("A pipe server is one program: it defines exactly one backend")

  defp one_program(_transport, _backends), do: :ok

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

  defp check_login_command(nil), do: :ok

  defp check_login_command(command) do
    case LocusBackends.check_command(command) do
      :ok -> :ok
      {:error, :vault_reference} -> invalid("config.login_command names a vault entry")
      {:error, _} -> invalid("config.login_command is not a command a program may run")
    end
  end

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

  # A kept stdio row's sessions run in its login entry's home; a pipe row's
  # catalyst names its entry by its need, so the row names none.
  defp check_login_entry("stdio", "kept", entry) when is_binary(entry) and entry != "",
    do: {:ok, entry}

  defp check_login_entry("stdio", "kept", _entry),
    do: invalid("A kept stdio server names the login entry its home is: config.login_entry_id")

  defp check_login_entry(_transport, _home, nil), do: {:ok, nil}

  defp check_login_entry("pipe", _home, _entry),
    do: invalid("A pipe server names no login entry: its catalyst's need binds one")

  defp check_login_entry(_transport, _home, _entry),
    do: invalid("config.login_entry_id names the entry of a kept home: set config.home to kept")

  @doc """
  The programs a stored row defines: one per validated backend, each with
  the row's program settings, or the refusal of a row whose stored hosts
  do not read.
  """
  @spec programs(map(), [backend()]) ::
          {:ok, [program()]} | {:error, {:invalid_argument, String.t()}}
  def programs(row, backends) do
    with {:ok, hosts} <- stored_hosts(row) do
      {:ok,
       for backend <- backends do
         %{
           name: backend["name"],
           command: backend["command"],
           env: backend["env"],
           login_command: Map.get(row, :login_command),
           home: if(Map.get(row, :home) == "kept", do: :kept, else: :scratch),
           memory_bytes: Map.get(row, :memory_bytes),
           home_max_bytes: Map.get(row, :home_max_bytes),
           hosts: hosts
         }
       end}
    end
  end

  @doc "A program as a sync names it on the wire (`Prima.LocusBackends`): its env names, never its values."
  @spec wire(program()) :: LocusBackends.program()
  def wire(program) do
    %{
      name: program.name,
      command: program.command,
      login_command: program.login_command,
      env_names: program.env |> Map.keys() |> Enum.sort(),
      home: program.home,
      memory_bytes: program.memory_bytes,
      home_max_bytes: program.home_max_bytes,
      hosts: program.hosts
    }
  end

  defp backend(%{"name" => name, "command" => command} = backend) do
    with :ok <- check_name(name),
         :ok <- check_command(name, command),
         {:ok, env} <- check_env(name, Map.get(backend, "env", %{})),
         :ok <- only_keys(name, backend) do
      {:ok, %{"name" => name, "command" => command, "env" => env}}
    end
  end

  defp backend(_backend), do: invalid("Every backend needs a name and a command")

  defp only_keys(name, backend) do
    case Map.keys(backend) -- ["name", "command", "env"] do
      [] -> :ok
      extra -> invalid("Backend '#{name}' has unknown keys: #{Enum.join(Enum.sort(extra), ", ")}")
    end
  end

  defp check_name(name) when is_binary(name) do
    if Regex.match?(@name, name),
      do: :ok,
      else: invalid("Backend name #{inspect(name)} must match #{Regex.source(@name)}")
  end

  defp check_name(name), do: invalid("Backend name #{inspect(name)} must be a string")

  # The command rule is `Prima.LocusBackends.check_command/1`'s; the
  # sentences are this surface's.
  defp check_command(name, command) do
    case LocusBackends.check_command(command) do
      :ok ->
        :ok

      {:error, :not_a_string} ->
        invalid("Backend '#{name}' needs a command string")

      {:error, :empty} ->
        invalid("Backend '#{name}' needs a command")

      {:error, :too_long} ->
        invalid(
          "Backend '#{name}' has a command longer than #{LocusBackends.max_command_bytes()} bytes"
        )

      {:error, :nul} ->
        invalid("Backend '#{name}' has a NUL byte in its command")

      {:error, :vault_reference} ->
        invalid(
          "Backend '#{name}' names a vault entry in its command — command lines are " <>
            "visible to every process on the backends service; pass it through env instead"
        )
    end
  end

  defp check_env(name, env) when is_map(env) do
    env
    |> Enum.sort()
    |> each(fn {key, value} -> env_entry(name, key, value) end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp check_env(name, _env), do: invalid("Backend '#{name}' env must be an object")

  defp env_entry(backend, key, value) when is_binary(key) and is_binary(value) do
    cond do
      not Regex.match?(@env_name, key) ->
        invalid(
          "Backend '#{backend}' env name #{inspect(key)} must match #{Regex.source(@env_name)}"
        )

      key in LocusBackends.reserved_env_names() or
          String.starts_with?(key, LocusBackends.reserved_env_prefixes()) ->
        invalid("Backend '#{backend}' env name #{key} is reserved")

      VaultRef.unresolved_ref?(value) ->
        invalid(
          "Backend '#{backend}' env #{key} names a reference this server does not resolve — " <>
            "use \"vault:ENTRY\""
        )

      VaultRef.vault_ref?(value) ->
        {:ok, {key, value}}

      key not in LocusBackends.literal_env_names() ->
        invalid(
          "Backend '#{backend}' env #{key} must reference a vault entry (\"vault:ENTRY\"); " <>
            "only #{Enum.join(LocusBackends.literal_env_names(), ", ")} may hold a literal"
        )

      byte_size(value) > @max_literal_bytes or String.contains?(value, <<0>>) ->
        invalid("Backend '#{backend}' env #{key} is not a valid value")

      true ->
        {:ok, {key, value}}
    end
  end

  defp env_entry(backend, key, _value),
    do: invalid("Backend '#{backend}' env #{inspect(key)} must be a string value")

  defp unique_names(backends) do
    names = Enum.map(backends, & &1["name"])

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> invalid("Backend name '#{dup}' is used twice")
    end
  end

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
