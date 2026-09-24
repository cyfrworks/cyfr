# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Credentials do
  @moduledoc """
  What this worker service is and how it reaches CYFR, read from
  `config :opus` and nothing else: its service id (`:service_id`), the
  worker key CYFR derived for that id (`:service_key`, 64 hexadecimal
  digits; `Prima.WorkerAuth.worker_key/2` on CYFR's side), the base URL of
  CYFR's host API (`:host_url`), and the address its own listener binds
  (`:bind`, `:port`).

  `:host_url` (`OPUS_HOST_URL`) is the address this worker service is
  configured to reach CYFR at, and it is where an attempt's host calls
  and a runner's exit report go only when the attempt's assignment names
  no member address of its own. An assignment that names one wins for
  that attempt, always: it is the only one of the two that knows which
  member issued the work, and only that member holds the attempt's
  process. A deployment of more than one member gives every member an
  address (`CYFR_HOST_API_URL`) and refuses to boot without it, so this
  value is the fallback of a deployment with exactly one member to fall
  back to.

  The worker key is the one secret a worker service holds. Its dispatch
  key signs the requests CYFR sends it and the reports it sends CYFR, and
  its dispatch seal key opens the keys of the attempts CYFR starts on it
  (`Prima.WorkerAuth`); both derive here, once, and the root they derive
  from is never seen by this service. A missing or malformed value refuses
  the boot (`load!/0`): a worker service that cannot say who it is or
  where CYFR is runs nothing. So does CYFR's own configuration in the
  `opus` release's environment (`refused_environment/1`): the worker root,
  the keyring and the database URL are the control plane's, and a worker
  release that can see them was given more than a worker holds.

  `install/1` keeps the loaded credentials for the processes that need
  them between calls (`current/0`): the worker listener verifying a
  request, and the worker service reporting a runner's exit.
  """

  @service_id ~r/\Awrk_[A-Za-z0-9_-]{1,64}\z/
  @key {__MODULE__, :current}
  @control_plane_only ~w(CYFR_WORKER_KEY CYFR_CRYPTO_KEYRING CYFR_DATABASE_URL)

  @derive {Inspect, except: [:worker_key, :dispatch_key, :dispatch_seal_key]}
  @enforce_keys [
    :service_id,
    :worker_key,
    :dispatch_key,
    :dispatch_seal_key,
    :host_url,
    :bind,
    :port
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          service_id: String.t(),
          worker_key: binary(),
          dispatch_key: binary(),
          dispatch_seal_key: binary(),
          host_url: String.t(),
          bind: :inet.ip_address(),
          port: :inet.port_number()
        }

  @typedoc "Which configured value refused, and why."
  @type refusal :: {:missing | :malformed, :service_id | :service_key | :host_url | :bind | :port}

  @doc "The credentials `config :opus` spells, or the first value that refuses."
  @spec load() :: {:ok, t()} | {:error, refusal()}
  def load, do: load(Application.get_all_env(:opus))

  @doc "The credentials `env` (the `:opus` application environment) spells."
  @spec load(keyword()) :: {:ok, t()} | {:error, refusal()}
  def load(env) when is_list(env) do
    with {:ok, service_id} <- service_id(Keyword.get(env, :service_id)),
         {:ok, worker_key} <- service_key(Keyword.get(env, :service_key)),
         {:ok, host_url} <- host_url(Keyword.get(env, :host_url)),
         {:ok, bind} <- bind(Keyword.get(env, :bind)),
         {:ok, port} <- port(Keyword.get(env, :port)) do
      {:ok,
       %__MODULE__{
         service_id: service_id,
         worker_key: worker_key,
         dispatch_key: Prima.WorkerAuth.dispatch_key(worker_key),
         dispatch_seal_key: Prima.WorkerAuth.dispatch_seal_key(worker_key),
         host_url: host_url,
         bind: bind,
         port: port
       }}
    end
  end

  @doc """
  The names in `env` (a map of environment variables) that only the
  control plane may hold: the worker root, the keyring and the database
  URL. Empty for an environment a worker release may run in.
  """
  @spec refused_environment(%{optional(String.t()) => String.t()}) :: [String.t()]
  def refused_environment(env) when is_map(env),
    do: Enum.filter(@control_plane_only, &is_map_key(env, &1))

  @doc """
  `load/0`, raising on a value that refuses so the boot stops there. In
  the `opus` release (`RELEASE_NAME`), an environment that carries the
  control plane's configuration refuses as well.
  """
  @spec load!() :: t()
  def load! do
    refused =
      if System.get_env("RELEASE_NAME") == "opus",
        do: refused_environment(System.get_env()),
        else: []

    if refused != [] do
      raise ArgumentError,
            "[Opus.Credentials] the opus release must not see #{Enum.join(refused, ", ")}: " <>
              "the worker root, the keyring and the database are CYFR's"
    end

    case load() do
      {:ok, credentials} ->
        credentials

      {:error, {:missing, key}} ->
        raise ArgumentError, "[Opus.Credentials] config :opus, #{inspect(key)} is not set"

      {:error, {:malformed, key}} ->
        raise ArgumentError,
              "[Opus.Credentials] config :opus, #{inspect(key)} is malformed: #{expected(key)}"
    end
  end

  @doc "Keep `credentials` as the running service's, for `current/0`."
  @spec install(t()) :: :ok
  def install(%__MODULE__{} = credentials), do: :persistent_term.put(@key, credentials)

  @doc "The installed credentials, or `nil` before the worker service has started."
  @spec current() :: t() | nil
  def current, do: :persistent_term.get(@key, nil)

  @doc "The 32 bytes `text`, a worker key as 64 hexadecimal digits, spells."
  @spec decode_key(term()) :: {:ok, binary()} | :error
  def decode_key(text), do: Prima.MacEnvelope.decode_root(text)

  defp service_id(nil), do: {:error, {:missing, :service_id}}

  defp service_id(id) when is_binary(id) do
    if Regex.match?(@service_id, id), do: {:ok, id}, else: {:error, {:malformed, :service_id}}
  end

  defp service_id(_id), do: {:error, {:malformed, :service_id}}

  defp service_key(nil), do: {:error, {:missing, :service_key}}

  defp service_key(text) do
    case decode_key(text) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:malformed, :service_key}}
    end
  end

  defp host_url(nil), do: {:error, {:missing, :host_url}}

  defp host_url(url) do
    case Prima.WorkerWire.base_url(url) do
      {:ok, base} -> {:ok, base}
      :error -> {:error, {:malformed, :host_url}}
    end
  end

  defp bind(nil), do: {:error, {:missing, :bind}}

  defp bind(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, {:malformed, :bind}}
    end
  end

  defp bind(_address), do: {:error, {:malformed, :bind}}

  defp port(nil), do: {:error, {:missing, :port}}
  defp port(port) when is_integer(port) and port in 0..65_535, do: {:ok, port}
  defp port(_port), do: {:error, {:malformed, :port}}

  @doc "What a well-formed value of `key` is, for the message that refuses one."
  @spec expected(:service_id | :service_key | :host_url | :bind | :port) :: String.t()
  def expected(:service_id), do: "`wrk_` followed by 1 to 64 letters, digits, `_` or `-`"
  def expected(:service_key), do: "exactly 64 hexadecimal digits (the derived worker key)"
  def expected(:host_url), do: "an http or https URL with a host and no path"
  def expected(:bind), do: "an IPv4 or IPv6 address"
  def expected(:port), do: "an integer from 0 to 65535"
end
