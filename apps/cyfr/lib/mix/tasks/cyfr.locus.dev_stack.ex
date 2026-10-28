# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Locus.DevStack do
  @shortdoc "What the source development stack's runtime needs, read as a mix boot reads it"

  @moduledoc """
  The settings `scripts/dev-stack.sh` starts the source development
  stack's runtime with (CONTRIBUTING.md, "Running from source"), read
  from the checkout's `.env` and the environment by the reader and in the
  order `config/runtime.exs` reads them (`Cyfr.EnvFiles`, the environment
  over the file), so the stack and the mix boot beside it agree on every
  value. The script reads no `.env` of its own.

      mix cyfr.locus.dev_stack key SERVICE_ID WORKER_URL HOST_API_BIND

  prints `LOCUS_RUNTIME_KEY=<64 hex>`, the key of SERVICE_ID derived from
  `CYFR_LOCUS_RUNTIME_ROOT` (`Prima.WorkerAuth.worker_key/2`), and
  `CYFR_HOST_API_PORT=<port>`, the port the boot's host API listens on.
  It refuses, naming the variable and its fix, a malformed root, a root
  the environment sets empty over the file, a `CYFR_LOCUS_RUNTIME_WORKERS`
  other than `SERVICE_ID=WORKER_URL`, a `CYFR_HOST_API_BIND` other than
  HOST_API_BIND and a `CYFR_HOST_API_URL` other than the host API at
  HOST_API_BIND: each would send runs, or the runtime's calls, somewhere
  the stack is not. A root set nowhere is refused with exit status 3, the
  one refusal the script answers by writing a root into `.env`.

      mix cyfr.locus.dev_stack endpoint

  prints `CYFR_PORT=<port>`, the port the boot's loopback listener
  serves, where `scripts/dev-stack.sh check` reaches the server.
  """

  use Boundary, classify_to: Cyfr

  use Mix.Task

  @root "CYFR_LOCUS_RUNTIME_ROOT"
  @workers "CYFR_LOCUS_RUNTIME_WORKERS"
  @bind "CYFR_HOST_API_BIND"
  @url "CYFR_HOST_API_URL"

  @impl Mix.Task
  def run(["key", service_id, worker_url, host_api_bind]) do
    env = environment()
    # config/runtime.exs's reader: an empty value is unset. The resolvers
    # it hands values to trim them first, and so do the checks below.
    getenv = fn name -> if Map.get(env, name) == "", do: nil, else: Map.get(env, name) end

    with {:ok, host_api} <- Cyfr.RuntimeConfig.resolve_host_api(getenv),
         :ok <- workers(getenv, service_id, worker_url),
         :ok <- bind(getenv, host_api_bind),
         :ok <- url(getenv, "http://#{host_api_bind}:#{host_api.port}"),
         {:ok, key} <- key(getenv.(@root), service_id) do
      Mix.shell().info("LOCUS_RUNTIME_KEY=" <> Base.encode16(key, case: :lower))
      Mix.shell().info("CYFR_HOST_API_PORT=#{host_api.port}")
    else
      {:error, message} -> Mix.raise(message)
      {:error, message, status} -> Mix.raise(message, exit_status: status)
    end
  end

  def run(["endpoint"]) do
    env = environment()

    case Cyfr.RuntimeConfig.resolve_access(%{file: file_env(), process: env, release?: false}) do
      {:ok, %{listeners: %{loopback: {_address, port}}}} ->
        Mix.shell().info("CYFR_PORT=#{port}")

      {:error, %{code: code, payload: payload}} ->
        Mix.raise(Prima.Refusal.message({code, payload}))
    end
  end

  def run(_args) do
    Mix.raise(
      "usage: mix cyfr.locus.dev_stack key SERVICE_ID WORKER_URL HOST_API_BIND | endpoint"
    )
  end

  # The names and values a mix boot reads: the .env file at the project
  # root, then the environment over it.
  defp environment,
    do: Cyfr.EnvFiles.source!(env_files() ++ [System.get_env()], side_effect: false)

  defp file_env do
    case env_files() do
      [] -> nil
      files -> Cyfr.EnvFiles.source!(files, side_effect: false)
    end
  end

  defp env_files do
    # arca:bypass-ok=B — the operator's .env file at the project root, read
    # as the boot's runtime configuration reads it, with no Arca configured.
    path = Path.join(File.cwd!(), ".env")
    if File.regular?(path), do: [path], else: []
  end

  defp workers(getenv, service_id, worker_url) do
    want = "#{service_id}=#{worker_url}"

    case blank_to_nil(getenv.(@workers)) do
      nil ->
        :ok

      text ->
        case Cyfr.RuntimeConfig.resolve_workers(getenv) do
          {:ok, [%{id: ^service_id, url: ^worker_url}]} -> :ok
          {:ok, _elsewhere} -> disagrees(@workers, text, want)
          {:error, message} -> {:error, message}
        end
    end
  end

  defp bind(getenv, host_api_bind) do
    case blank_to_nil(getenv.(@bind)) do
      nil ->
        :ok

      text ->
        if :inet.parse_address(String.to_charlist(text)) ==
             :inet.parse_address(String.to_charlist(host_api_bind)),
           do: :ok,
           else: disagrees(@bind, text, host_api_bind)
    end
  end

  defp url(getenv, want) do
    case blank_to_nil(getenv.(@url)) do
      nil ->
        :ok

      text ->
        if Prima.WorkerWire.base_url(text) == {:ok, want},
          do: :ok,
          else: disagrees(@url, text, want)
    end
  end

  defp disagrees(name, have, want) do
    {:error,
     "#{name} is #{have}, and the dev stack needs #{want}. Unset it in .env and the " <>
       "environment, or set it to #{want}."}
  end

  defp key(nil, _service_id) do
    if System.get_env(@root) == nil do
      {:error, "#{@root} is set in neither .env nor the environment.", 3}
    else
      {:error,
       "#{@root} is set empty in the environment, which overrides .env. Unset it there, " <>
         "so the root .env holds is the one CYFR and the runtime share."}
    end
  end

  defp key(text, service_id) do
    with {:ok, root} <- root(text),
         {:ok, key} <- Prima.WorkerAuth.worker_key(root, service_id) do
      {:ok, key}
    else
      {:error, {:invalid_field, :service}} ->
        {:error, "#{inspect(service_id)} is not a service id"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp root(text) do
    case Prima.MacEnvelope.decode_root(text) do
      {:ok, root} ->
        {:ok, root}

      :error ->
        {:error,
         "#{@root} is not 64 hexadecimal digits. Generate one with `openssl rand -hex 32`, " <>
           "or remove its line from .env and scripts/dev-stack.sh writes one."}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
