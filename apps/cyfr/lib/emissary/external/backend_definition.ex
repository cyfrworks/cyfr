# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.BackendDefinition do
  @moduledoc """
  The backends of a `stdio` MCP server: what `config.backends` may hold.

  A stdio server runs its backends on the backends service Locus serves
  (`Emissary.External.Backends`), each a shell command with an environment:

      [%{"name" => "github", "command" => "npx -y @modelcontextprotocol/server-github",
         "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token"}}]

  `validate/1` accepts a list of at most `max_backends/0` backends
  (`:max_backends_per_server`, default 4) and answers it normalized, or
  `{:error, {:invalid_argument, message}}`:

    * a name matches `^[a-z0-9][a-z0-9-]{0,31}$` and is unique;
    * a command is a non-empty string of at most
      `Prima.LocusBackends.max_command_bytes/0` bytes with no NUL byte and
      no `vault:` — every process on the service can read a command line,
      so a credential never goes in one;
    * a command holds none of its own vault-bound env names as an
      expansion (`$NAME`, `${NAME…}`, quoted or escaped alike), and, beside
      any vault-bound name, holds no command substitution, arithmetic
      expansion or indirection (`$(`, a backtick, `$[`, `${!`, `${ `, `${|`),
      read with its line continuations joined: the value reaches the
      program through its environment, never its command line. The check
      reads the command's text, not what a program it starts does:
      `printenv NAME | xargs …` or a program that passes the value to a
      child still puts it on a command line;
    * an env name matches `^[A-Z_][A-Z0-9_]{0,63}$` and is none of the
      wire's reserved names (`Prima.LocusBackends.reserved_env_names/0`:
      `PATH HOME USER LOGNAME SHELL TMPDIR PWD`), nor prefixed with one of
      `reserved_prefixes/0` (`CYFR_`, `LOCUS_`, `KEEPER_`) — the keeper sets
      the names, and the prefixes are CYFR's, Locus's and the keeper's, the
      list the keeper and the service refuse too;
    * an env value is a vault template (`Prima.VaultRef`); only the
      non-secret names in `literal_names/0` may hold a literal, of at most
      4096 bytes, instead.
  """

  alias Prima.{LocusBackends, VaultRef}

  @name ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @max_literal_bytes 4096

  @typedoc "One validated backend."
  @type backend :: %{String.t() => String.t() | %{String.t() => String.t()}}

  @doc "The most backends one server may define (`:max_backends_per_server`)."
  @spec max_backends() :: pos_integer()
  def max_backends, do: Application.get_env(:cyfr, :max_backends_per_server, 4)

  @doc "The env names that may hold a literal value: the wire's (`Prima.LocusBackends`)."
  @spec literal_names() :: [String.t()]
  def literal_names, do: LocusBackends.literal_env_names()

  @doc "The prefixes no env name may carry: the wire's (`Prima.LocusBackends`)."
  @spec reserved_prefixes() :: [String.t()]
  def reserved_prefixes, do: LocusBackends.reserved_env_prefixes()

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

  defp backend(%{"name" => name, "command" => command} = backend) do
    with :ok <- check_name(name),
         {:ok, env} <- check_env(name, Map.get(backend, "env", %{})),
         :ok <- check_command(name, command),
         :ok <- check_expansions(name, command, env),
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

  defp check_command(name, command) when is_binary(command) do
    cond do
      String.trim(command) == "" ->
        invalid("Backend '#{name}' needs a command")

      byte_size(command) > LocusBackends.max_command_bytes() ->
        invalid(
          "Backend '#{name}' has a command longer than #{LocusBackends.max_command_bytes()} bytes"
        )

      String.contains?(command, <<0>>) ->
        invalid("Backend '#{name}' has a NUL byte in its command")

      String.contains?(String.downcase(command), VaultRef.prefix()) ->
        invalid(
          "Backend '#{name}' names a vault entry in its command — command lines are " <>
            "visible to every process on the backends service; pass it through env instead"
        )

      true ->
        :ok
    end
  end

  defp check_command(name, _command), do: invalid("Backend '#{name}' needs a command string")

  # The command runs as `/bin/sh -c command` (Locus.Backends.Backend), so a
  # vault-bound name the shell expands puts the disclosed value in a child's
  # argv, which every process on the backends service can read. The forms
  # that compute a value at run time can expand any name, so beside a
  # vault-bound name none is accepted. A backslash-newline is joined before
  # the shell reads a word, so it is joined here too.
  @computed ["$(", "`", "$[", "${!", "${ ", "${\t", "${\n", "${|"]

  defp check_expansions(name, command, env) do
    bound = for {key, value} <- env, VaultRef.vault_ref?(value), do: key
    text = String.replace(command, "\\\n", "")

    cond do
      bound == [] ->
        :ok

      expanded = Enum.find(bound, &expands?(text, &1)) ->
        invalid(
          "Backend '#{name}' expands #{expanded}, a vault-bound env name, in its command — " <>
            "command lines are visible to every process on the backends service; the value " <>
            "must reach the program through its environment, not its command line"
        )

      token = Enum.find(@computed, &String.contains?(text, &1)) ->
        invalid(
          "Backend '#{name}' has #{inspect(token)} in its command beside " <>
            "the vault-bound #{Enum.join(bound, ", ")} — a command substitution, arithmetic " <>
            "expansion or indirection can expand it, and command lines are visible to every " <>
            "process on the backends service; the value must reach the program through its " <>
            "environment, not its command line"
        )

      true ->
        :ok
    end
  end

  defp expands?(text, key) do
    Regex.match?(~r/\$\{?#{key}(?![A-Za-z0-9_])/, text)
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
          String.starts_with?(key, reserved_prefixes()) ->
        invalid("Backend '#{backend}' env name #{key} is reserved")

      VaultRef.unresolved_ref?(value) ->
        invalid(
          "Backend '#{backend}' env #{key} names a reference this server does not resolve — " <>
            "use \"vault:ENTRY\""
        )

      VaultRef.vault_ref?(value) ->
        {:ok, {key, value}}

      key not in literal_names() ->
        invalid(
          "Backend '#{backend}' env #{key} must reference a vault entry (\"vault:ENTRY\"); " <>
            "only #{Enum.join(literal_names(), ", ")} may hold a literal"
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
