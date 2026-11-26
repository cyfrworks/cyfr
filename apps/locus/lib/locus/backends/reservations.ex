# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Reservations do
  @moduledoc """
  What a box's sessions hold (`Locus.Backends.Owners`), their places and
  uids, one reservation per session, each in one state and moved by one authority.
  Data only: the owner table holds it and acts on what it answers.

  A reservation is a session's heir tag (`t:tag/0`: its ledger, its session,
  its athanor, its row, the generation and epoch that opened it, its session
  key, its lifetime and its kept home) and its state:

  | State | Holds | Event | Next | Authority |
  |---|---|---|---|---|
  | `reserved` | an open admitted, its home being made or its pool read | `:started` | `asked` | the table: it started the session's process |
  | | | `:abandoned` | released | the table: its preparation answered and it started no session process, so nothing was asked |
  | `asked` | a session process that may have asked its launcher | `:spawned` | `running` | the launcher, answering the spawn |
  | `asked`, `running`, `ending` | | `:confirmed` | released | the launcher, through the session (`:vacated`: refused with nothing made, or released) |
  | `asked`, `running` | a process the launcher may run | `:unfollowed` | `ending` | the table: its session process died, its spawn's answer was lost, or its owner retired |
  | `asked`, `running`, `ending` | | `:heir` | released | the launcher, to the spawn's heir: nothing of it is left |
  | `ending` | a process no session follows | `{:fence, :none}` | released | the launcher's fence: none is held, and none will start |
  | | | `{:fence, :pending}`, `{:fence, :failed}` | `ending` | none: asked again at the next sweep |
  | none | | `{:adopted, tag}` | `ending` | the launcher, naming a process it holds for this ledger |

  An event a state does not name moves nothing, and an event for no
  reservation moves nothing: a release heard before an adoption names it
  is then settled by the ending's fence, which answers `:none` for a
  process already gone. Nothing else releases a reservation: no timeout, no
  caller's death and no clock. An ending is asked of its launcher's fence
  (`c:Locus.Launcher.fence/2`) until it is released, so a fence that was
  not answered, or answered while the process ran, is asked again. Its
  cost: a fence that answers `:none` stands for the life of the launcher's
  client, which keeps one entry for each such tag (`Locus.Keeper`).

  Every state holds the session's place; every state but `reserved`
  holds a scratch session's uid of the pool, which only its process takes.
  Every state but `reserved` stands for a process the launcher may still
  run under its tag's row and key (`process?/4`). A tag that names no row
  or key names a process of no key. A close names a lifetime
  (`t:lifetime/0`), which an adoption carries in the tag, so it needs no
  owner and finds nothing of another lifetime (`of_lifetime/2`).
  """

  @typedoc "A session's heir tag, which a table that adopts it holds by."
  @type tag :: %{
          ledger: term(),
          session: key(),
          athanor: String.t(),
          server: String.t(),
          g: pos_integer(),
          e: pos_integer(),
          key: term(),
          lifetime: String.t(),
          home_id: String.t() | nil
        }

  @typedoc "One lifetime: one process of one key, as the version that opened it names it."
  @type lifetime :: %{
          athanor: String.t(),
          server: String.t(),
          g: pos_integer(),
          e: pos_integer(),
          key: term(),
          lifetime: String.t()
        }

  @typedoc "A session, by its owner and its id."
  @type key :: {reference() | term(), String.t()}

  @typedoc "A reservation's state."
  @type state :: :reserved | :asked | :running | :ending

  @typedoc "Whether an ending's fence is to be asked, being asked, or was answered `:pending`."
  @type fence :: :unasked | :asking | :pending | nil

  @type reservation :: %{tag: tag(), state: state(), fence: fence()}
  @type t :: %{optional(key()) => reservation()}

  @typedoc "What moves a reservation."
  @type event ::
          :started
          | :abandoned
          | :spawned
          | :confirmed
          | :unfollowed
          | :heir
          | :asking
          | {:fence, :none | :pending | :failed}
          | {:adopted, tag()}

  @doc "No reservations."
  @spec new() :: t()
  def new, do: %{}

  @doc "An open admitted: `tag` reserved."
  @spec reserve(t(), tag()) :: t()
  def reserve(reservations, %{session: key} = tag),
    do: Map.put(reservations, key, %{tag: tag, state: :reserved, fence: nil})

  @doc "The reservations after `event` for the session `key`."
  @spec event(t(), key(), event()) :: t()
  def event(reservations, key, event) do
    case transition(Map.get(reservations, key), event) do
      :released -> Map.delete(reservations, key)
      :absent -> reservations
      reservation -> Map.put(reservations, key, reservation)
    end
  end

  # The table above, clause by clause.
  defp transition(%{state: :reserved} = r, :started), do: %{r | state: :asked}
  defp transition(%{state: :reserved}, :abandoned), do: :released
  defp transition(%{state: :asked} = r, :spawned), do: %{r | state: :running}

  defp transition(%{state: state}, :confirmed) when state in [:asked, :running, :ending],
    do: :released

  defp transition(%{state: state} = r, :unfollowed) when state in [:asked, :running],
    do: %{r | state: :ending, fence: :unasked}

  defp transition(%{state: state}, :heir) when state in [:asked, :running, :ending],
    do: :released

  defp transition(%{state: :ending, fence: fence} = r, :asking)
       when fence in [:unasked, :pending],
       do: %{r | fence: :asking}

  defp transition(%{state: :ending}, {:fence, :none}), do: :released

  defp transition(%{state: :ending, fence: :asking} = r, {:fence, :pending}),
    do: %{r | fence: :pending}

  defp transition(%{state: :ending, fence: :asking} = r, {:fence, :failed}),
    do: %{r | fence: :unasked}

  defp transition(nil, {:adopted, tag}), do: %{tag: tag, state: :ending, fence: :unasked}
  defp transition(nil, _event), do: :absent
  defp transition(reservation, _event), do: reservation

  @doc "Whether `key` holds a reservation."
  @spec held?(t(), key()) :: boolean()
  def held?(reservations, key), do: Map.has_key?(reservations, key)

  @doc """
  Whether the launcher may still run a process of the session key `key` of
  `athanor`'s row `server`: a reservation past its open's preparation whose
  tag names them.
  """
  @spec process?(t(), String.t(), String.t(), term()) :: boolean()
  def process?(reservations, athanor, server, key) do
    Enum.any?(reservations, fn
      {_key, %{state: state, tag: %{athanor: ^athanor, server: ^server, key: ^key}}} ->
        state != :reserved

      _other ->
        false
    end)
  end

  @doc "Every reservation of the lifetime `named`, and of no other."
  @spec of_lifetime(t(), lifetime()) :: [key()]
  def of_lifetime(reservations, named) do
    for {key, %{tag: tag}} <- reservations,
        Map.take(tag, [:athanor, :server, :g, :e, :key, :lifetime]) == named,
        do: key
  end

  @doc "The pool's uids held: every scratch session's whose process may run."
  @spec uids(t()) :: non_neg_integer()
  def uids(reservations),
    do:
      Enum.count(reservations, fn {_key, r} -> r.state != :reserved and r.tag.home_id == nil end)

  @doc "The endings whose fence is to be asked: never asked, unanswered, or answered `:pending`."
  @spec to_fence(t()) :: [reservation()]
  def to_fence(reservations),
    do:
      for(
        {_key, %{state: :ending, fence: f} = r} <- reservations,
        f in [:unasked, :pending],
        do: r
      )

  @doc "The endings, by session."
  @spec endings(t()) :: t()
  def endings(reservations), do: Map.filter(reservations, fn {_key, r} -> r.state == :ending end)
end
