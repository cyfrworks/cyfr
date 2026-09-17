# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Keys do
  @moduledoc """
  The keys CYFR and its execution workers authenticate each other with
  (`Cyfr.WorkerAuth`).

  The worker root is `config :cyfr, :worker_key` (`CYFR_WORKER_KEY`, 32
  bytes). Without one, the root is 32 random bytes minted when the
  application starts and held only in this BEAM, which serves only a
  worker service running in this BEAM; a restart then retires every
  assignment, worker and attempt key the previous boot issued. Every other
  key is derived from the root.

  `generation/0` is the control-plane generation assignments are issued
  under and host calls are checked against: the generation of the claim
  this boot holds (`Cyfr.ControlPlane.generation/0`), or `1` for a boot
  that claims no control plane (a cluster node, or claiming switched off).
  A generation the control plane cannot answer is a refusal, never `1`:
  no assignment is issued and no host call verifies under it.
  """

  alias Cyfr.WorkerAuth

  @key {__MODULE__, :root}

  @doc "The worker root. Only CYFR holds it."
  @spec root() :: binary()
  def root do
    case :persistent_term.get(@key, nil) do
      nil -> mint()
      root -> root
    end
  end

  @doc false
  # Set once at application start; the lazy path in `root/0` covers only a
  # caller that beat the start.
  def mint do
    root =
      case Application.get_env(:cyfr, :worker_key) do
        <<_::binary-size(32)>> = configured -> configured
        nil -> :crypto.strong_rand_bytes(32)
      end

    :persistent_term.put(@key, root)
    root
  end

  @doc "The key assignments are MAC'd with (`Cyfr.Assignment`)."
  @spec assign_key() :: binary()
  def assign_key, do: WorkerAuth.assign_key(root())

  @doc """
  The key of the worker service `service` (its configured id, never its
  boot), from which its dispatch and dispatch seal keys derive
  (`Cyfr.WorkerAuth.worker_key/2`).
  """
  @spec worker_key(String.t()) :: {:ok, binary()} | {:error, Cyfr.MacEnvelope.invalid_field()}
  def worker_key(service) when is_binary(service), do: WorkerAuth.worker_key(root(), service)

  @doc """
  The keys of one attempt at one fence and generation on one worker
  service: the key its runner signs host calls with and the key it seals
  them with.
  """
  @spec attempt_keys(WorkerAuth.attempt()) ::
          {:ok, WorkerAuth.attempt_keys()} | {:error, Cyfr.MacEnvelope.invalid_field()}
  def attempt_keys(attempt) when is_map(attempt), do: WorkerAuth.attempt_keys(root(), attempt)

  @doc """
  The generation assignments are issued under and host calls must present
  (`generation/1` of the control plane's answer).
  """
  @spec generation() :: {:ok, pos_integer()} | {:error, :unavailable}
  def generation, do: generation(Cyfr.ControlPlane.generation())

  @doc """
  The generation a control-plane answer (`Cyfr.ControlPlane.generation/0`)
  issues and checks keys under: the claim's own, `1` for `:none` (a boot
  that claims no control plane), and `{:error, :unavailable}` for anything
  else, a refusal to read the claim included.
  """
  @spec generation(term()) :: {:ok, pos_integer()} | {:error, :unavailable}
  def generation({:ok, generation}) when is_integer(generation) and generation > 0,
    do: {:ok, generation}

  def generation(:none), do: {:ok, 1}
  def generation(_unknown), do: {:error, :unavailable}
end
