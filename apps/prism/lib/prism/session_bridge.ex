defmodule Prism.SessionBridge do
  @moduledoc """
  Reads and writes `~/.cyfr/config.json` to share session tokens
  between Codex (Go CLI) and Prism (Elixir web dashboard).

  The config format matches `apps/codex/internal/config/store.go`:

      {
        "current_context": "local",
        "contexts": {
          "local": {
            "url": "http://localhost:4000",
            "session_id": "TOKEN"
          }
        }
      }
  """

  alias Sanctum.Session

  @config_dir ".cyfr"
  @config_file "config.json"

  @doc """
  Load the session token from `~/.cyfr/config.json` and validate it.

  Returns `{:ok, token}` if the config contains a valid, non-expired
  session token for the current context. Returns `:error` otherwise.
  """
  def load_token do
    with {:ok, config} <- read_config(),
         {:ok, token} <- extract_token(config),
         {:ok, _user} <- Session.get_user(token) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  @doc """
  Save a session token to `~/.cyfr/config.json`.

  Preserves existing config fields and other contexts. Creates the
  config file and directory if they don't exist.
  """
  def save_token(token) do
    config =
      case read_config() do
        {:ok, existing} -> existing
        :error -> default_config()
      end

    context_name = config["current_context"] || "local"

    contexts = config["contexts"] || %{}
    context = contexts[context_name] || %{"url" => "http://localhost:4000"}
    context = Map.put(context, "session_id", token)
    contexts = Map.put(contexts, context_name, context)
    config = Map.put(config, "contexts", contexts)

    write_config(config)
  end

  defp config_path do
    home = System.user_home!()
    Path.join([home, @config_dir, @config_file])
  end

  defp read_config do
    path = config_path()

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, config} when is_map(config) -> {:ok, config}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  defp extract_token(config) do
    context_name = config["current_context"] || "local"

    case get_in(config, ["contexts", context_name, "session_id"]) do
      nil -> :error
      "" -> :error
      token -> {:ok, token}
    end
  end

  defp write_config(config) do
    path = config_path()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(config, pretty: true),
         :ok <- File.write(path, json),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_config do
    %{
      "current_context" => "local",
      "contexts" => %{
        "local" => %{
          "url" => "http://localhost:4000"
        }
      }
    }
  end
end
