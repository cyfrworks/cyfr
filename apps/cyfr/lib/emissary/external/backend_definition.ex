# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.BackendDefinition do
  @moduledoc """
  The backends of a `stdio` MCP server: what `config.backends` may hold.

  A stdio server runs its backends on the MCP bridge
  (`Emissary.External.Backends`), each a shell command with an environment:

      [%{"name" => "github", "command" => "npx -y @modelcontextprotocol/server-github",
         "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token"}}]

  `validate/1` accepts a list of at most `max_backends/0` backends
  (`:max_backends_per_server`, default 4) and answers it normalized, or
  `{:error, {:invalid_argument, message}}`:

    * a name matches `^[a-z0-9][a-z0-9-]{0,31}$` and is unique;
    * a command is a non-empty string of at most 4096 bytes with no NUL
      byte and no `vault:` — every process in the bridge can read a command
      line, so a credential never goes in one;
    * an env name matches `^[A-Z_][A-Z0-9_]{0,63}$` and is none of
      `PATH HOME USER LOGNAME SHELL TMPDIR PWD`, nor prefixed with one of
      `reserved_prefixes/0` (`CYFR_`, `MCP_BRIDGE_`, `KEEPER_`) — the
      bridge sets the first, and the prefixes are CYFR's, the bridge's and
      the keeper's, the list the keeper and the bridge refuse too;
    * an env value is a vault template (`Prima.VaultRef`); only the
      non-secret names in `literal_names/0` may hold a literal instead.
  """

  alias Prima.VaultRef

  @name ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @reserved_names ~w(PATH HOME USER LOGNAME SHELL TMPDIR PWD)
  @reserved_prefixes ~w(CYFR_ MCP_BRIDGE_ KEEPER_)
  @literal_names ~w(NODE_ENV LOG_LEVEL TZ LANG LC_ALL NO_COLOR DEBUG)
  @max_text_bytes 4096

  @typedoc "One validated backend."
  @type backend :: %{String.t() => String.t() | %{String.t() => String.t()}}

  @doc "The most backends one server may define (`:max_backends_per_server`)."
  @spec max_backends() :: pos_integer()
  def max_backends, do: Application.get_env(:cyfr, :max_backends_per_server, 4)

  @doc "The env names that may hold a literal value."
  @spec literal_names() :: [String.t()]
  def literal_names, do: @literal_names

  @doc "The prefixes no env name may carry."
  @spec reserved_prefixes() :: [String.t()]
  def reserved_prefixes, do: @reserved_prefixes

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

  defp check_command(name, command) when is_binary(command) do
    cond do
      String.trim(command) == "" ->
        invalid("Backend '#{name}' needs a command")

      byte_size(command) > @max_text_bytes ->
        invalid("Backend '#{name}' has a command longer than #{@max_text_bytes} bytes")

      String.contains?(command, <<0>>) ->
        invalid("Backend '#{name}' has a NUL byte in its command")

      String.contains?(String.downcase(command), VaultRef.prefix()) ->
        invalid(
          "Backend '#{name}' names a vault entry in its command — command lines are " <>
            "visible to every process in the bridge; pass it through env instead"
        )

      true ->
        :ok
    end
  end

  defp check_command(name, _command), do: invalid("Backend '#{name}' needs a command string")

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

      key in @reserved_names or String.starts_with?(key, @reserved_prefixes) ->
        invalid("Backend '#{backend}' env name #{key} is reserved")

      VaultRef.unresolved_ref?(value) ->
        invalid(
          "Backend '#{backend}' env #{key} names a reference this server does not resolve — " <>
            "use \"vault:ENTRY\""
        )

      VaultRef.vault_ref?(value) ->
        {:ok, {key, value}}

      key not in @literal_names ->
        invalid(
          "Backend '#{backend}' env #{key} must reference a vault entry (\"vault:ENTRY\"); " <>
            "only #{Enum.join(@literal_names, ", ")} may hold a literal"
        )

      byte_size(value) > @max_text_bytes or String.contains?(value, <<0>>) ->
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
