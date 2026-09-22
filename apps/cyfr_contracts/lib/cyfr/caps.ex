# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Caps do
  @moduledoc """
  The operator's ceilings, as the layers below the tenancy domain ask
  them: how many rows of a kind a caller may add, and how many bytes an
  athanor may hold.

  This shared runtime port holds only its injected implementation term.
  The contract is declared here, in the layer that depends
  on the answer; the one implementation is `Sanctum.Tenancy.Caps`, which
  reads the configured caps and counts the athanor's bytes; and
  `Cyfr.Application` writes it in at boot with `install!/1`. Arca asks
  through this module so that a persistence facade can refuse an over-cap
  write without naming the tenancy domain, which sits above it.

  ## The two questions

  `check_storage/2` is asked before a tenant write lands: the athanor's
  stored bytes plus the `incoming` bytes must stay under the byte ceiling.
  It takes the actor because the tree measured is the actor's own — the
  athanor comes from the authenticated caller and never from an argument
  a caller chose — and the incoming byte count because only the writer
  knows how much it is about to write.

  `check_counted/3` is asked before a capped row is inserted. It takes the
  actor for the same reason: a cap bounds what one tenant or one person
  may hold, and which one that is comes from the caller, not from the
  arguments. It takes the cap `key` because the ceilings are separate
  meanings (`keys/0`), and a zero-arity `count` rather than a number
  because only the domain that owns those rows can count them — Arca
  counts an athanor's threads, the tenancy domain counts athanors, groups,
  pairs and seats — and this port sits below all of them. The count runs
  only while its cap is configured, so a server with the cap off pays no
  query.

  ## Fail closed

  Both answers distinguish a refusal from an unavailable answer. A cap
  that is reached is `{:error, {:limit_reached, key, cap}}`. A count or a
  byte walk that cannot answer is `{:error, {:cap_unverifiable, key}}` or
  `{:error, :storage_unverifiable}` — never `:ok`, because a ceiling that
  admits whenever the store blinks is not a ceiling.

  The port itself keeps the same posture. `impl/0` raises
  `Cyfr.Caps.NotInstalledError` when nothing has been installed, so a
  process that checks a cap before boot wired one fails where it asked
  rather than reading an uninstalled port as a server with no caps.
  """

  alias Cyfr.Actor

  # The port's own term. Read on every capped write, so it is a
  # `:persistent_term` and not configuration, and written once at boot.
  @key {__MODULE__, :impl}

  @keys [
    :max_athanors,
    :max_groups_per_person,
    :max_pairs_per_person,
    :max_members_per_group,
    :max_threads_per_athanor,
    :mint_per_hour,
    :athanor_storage_bytes
  ]

  @typedoc """
  A cap key: one ceiling, one meaning. `:athanor_storage_bytes` is the one
  `check_storage/2` answers; the rest are counted (`check_counted/3`).
  """
  @type key ::
          :max_athanors
          | :max_groups_per_person
          | :max_pairs_per_person
          | :max_members_per_group
          | :max_threads_per_athanor
          | :mint_per_hour
          | :athanor_storage_bytes

  @typedoc """
  How the caller counts what a counted cap bounds. Run only while the cap
  is configured; an `{:error, _}` is a count the store could not answer,
  not a count of zero.
  """
  @type count :: (-> {:ok, non_neg_integer()} | {:error, term()})

  @typedoc "What a counted cap decides: admitted, at its ceiling, or unanswerable."
  @type counted_decision ::
          :ok
          | {:error, {:limit_reached, key(), pos_integer()}}
          | {:error, {:cap_unverifiable, key()}}

  @typedoc "What the byte cap decides: admitted, at its ceiling, or unanswerable."
  @type storage_decision ::
          :ok
          | {:error, {:limit_reached, :athanor_storage_bytes, pos_integer()}}
          | {:error, :storage_unverifiable}

  @doc """
  Whether `actor` may add one more of what `key` bounds, given a `count`
  of what it holds now.
  """
  @callback check_counted(Actor.t(), key(), count()) :: counted_decision()

  @doc """
  Whether `actor`'s athanor may hold `incoming` more bytes than it holds
  now.
  """
  @callback check_storage(Actor.t(), non_neg_integer()) :: storage_decision()

  @doc """
  The cap keys: the vocabulary the port and its implementation share, so
  the two cannot drift on what a ceiling is called.
  """
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc """
  Install the cap port's implementation. Called once by
  `Cyfr.Application` at boot, before anything that writes.

  A module that does not export both callbacks is refused here, loudly, at
  boot — not on the first capped write of whichever call site asked first.
  """
  @spec install!(module()) :: module()
  def install!(module) when is_atom(module) do
    unless Code.ensure_loaded?(module) and
             function_exported?(module, :check_counted, 3) and
             function_exported?(module, :check_storage, 2) do
      raise ArgumentError,
            "#{inspect(module)} does not implement Cyfr.Caps: both " <>
              "check_counted/3 and check_storage/2 are required"
    end

    :persistent_term.put(@key, module)
    module
  end

  @doc """
  Erase the installed implementation, leaving the port as boot found it.
  The inverse of `install!/1`, for a test that installs one of its own; a
  running server never calls it, and one that did would refuse every
  capped write rather than admit it.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The installed implementation.

  Raises `Cyfr.Caps.NotInstalledError` when there is none. An uninstalled
  port is not a server without caps: it is a server that cannot say, and
  a write it cannot measure does not land.
  """
  @spec impl() :: module()
  def impl do
    case :persistent_term.get(@key, :not_installed) do
      :not_installed -> raise Cyfr.Caps.NotInstalledError
      module -> module
    end
  end

  @doc "Ask the installed implementation `c:check_counted/3`."
  @spec check_counted(Actor.t(), key(), count()) :: counted_decision()
  def check_counted(%Actor{} = actor, key, count)
      when key in @keys and is_function(count, 0) do
    impl().check_counted(actor, key, count)
  end

  @doc "Ask the installed implementation `c:check_storage/2`."
  @spec check_storage(Actor.t(), non_neg_integer()) :: storage_decision()
  def check_storage(%Actor{} = actor, incoming) when is_integer(incoming) and incoming >= 0 do
    impl().check_storage(actor, incoming)
  end
end
