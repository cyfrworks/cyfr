# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Reservations do
  @moduledoc """
  The memory a box's sessions hold (`Locus.Backends.Owners`), one
  reservation per session, each in one state and moved by one authority.
  Data only: the owner table holds it and acts on what it answers.

  A reservation is a session's heir tag (`t:tag/0`: its ledger, its session,
  its athanor, its memory bound and its kept home) and its state:

  | State | Holds | Event | Next | Authority |
  |---|---|---|---|---|
  | `reserved` | an open admitted, its home being made or its pool read | `:started` | `asked` | the table: it started the session's process |
  | | | `:abandoned` | released | the table: it started no session process, so nothing was asked |
  | `asked` | a session process that may have asked its launcher | `:spawned` | `running` | the launcher, answering the spawn |
  | `asked`, `running`, `ending` | | `:confirmed` | released | the launcher, through the session (`:vacated`: refused, or released) |
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

  Every state holds the session's memory bound; every state but `reserved`
  holds a scratch session's uid of the pool, which only its process takes.
  """

  @typedoc "A session's heir tag, which a table that adopts it holds by."
  @type tag :: %{
          ledger: term(),
          session: key(),
          athanor: String.t(),
          memory_bytes: pos_integer(),
          home_id: String.t() | nil
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

  @doc "The bytes the reservations of the athanors `athanor?` takes hold."
  @spec held_bytes(t(), (String.t() -> boolean())) :: non_neg_integer()
  def held_bytes(reservations, athanor? \\ fn _ -> true end) do
    for {_key, %{tag: tag}} <- reservations, athanor?.(tag.athanor), reduce: 0 do
      sum -> sum + tag.memory_bytes
    end
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
