# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Keys do
  @moduledoc """
  The keys CYFR and the runners of its execution attempts authenticate
  each other with (`Cyfr.WorkerAuth`).

  The worker root is 32 random bytes minted once per boot, when the
  application starts, and held only in this BEAM. Every other key is
  derived from it, so a restart retires every assignment and attempt key
  the previous boot issued.

  `generation/0` is the control-plane generation assignments are issued
  under and host calls are checked against: the generation of the claim
  this boot holds (`Cyfr.ControlPlane.generation/0`), or `1` for a boot
  that claims no control plane (a cluster node, or claiming switched off).
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
  # Minted once at application start; the lazy path in `root/0` covers only
  # a caller that beat the start.
  def mint do
    root = :crypto.strong_rand_bytes(32)
    :persistent_term.put(@key, root)
    root
  end

  @doc "The key assignments are MAC'd with (`Cyfr.Assignment`)."
  @spec assign_key() :: binary()
  def assign_key, do: WorkerAuth.assign_key(root())

  @doc "The key WorkerAPI requests and worker service reports are signed with."
  @spec dispatch_key() :: binary()
  def dispatch_key, do: WorkerAuth.dispatch_key(root())

  @doc "The key start bodies are sealed with."
  @spec dispatch_seal_key() :: binary()
  def dispatch_seal_key, do: WorkerAuth.dispatch_seal_key(root())

  @doc """
  The key of one attempt at one fence and generation, which its runner
  signs its host calls with.
  """
  @spec attempt_key(WorkerAuth.attempt()) ::
          {:ok, binary()} | {:error, Cyfr.MacEnvelope.invalid_field()}
  def attempt_key(attempt) when is_map(attempt), do: WorkerAuth.attempt_key(root(), attempt)

  @doc "The generation assignments are issued under and host calls must present."
  @spec generation() :: pos_integer()
  def generation do
    case Cyfr.ControlPlane.generation() do
      {:ok, generation} -> generation
      :none -> 1
    end
  end
end
