# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Admission do
  @moduledoc """
  What a send is held to before anything is written, in order: the text
  and its size, the sender's standing (the athanor open, the sender its
  person), and who it addresses. Only the name is decided here; the
  agent resolves inside the turn.

  ## Who may post where

  Every message carries `sent_by` (`"person"` or an agent name) and an
  addressee. The thread is a room of the person's, a daily or a workspace
  thread (`kind: "daily"` or `"workspace"`), or a crew member's child
  thread (`kind: "crew"`, its `agent` the member):

    * A person's message in a room is a turn of the soul, whatever
      names its text holds: a job reaches a crew member only by the
      soul's hand-off. A child thread admits no message of the person's.
    * A turn of the soul may address any crew member: that is
      `crew.ask` (`Aqua.Crew`), whose request row this rule admits
      (`request/4`).
    * A request delivered into a child thread is a turn of the member
      there, sent by whoever sent the request.
    * A turn of a child thread may address only the thread and request
      that asked it: its reply lands on the request's thread and opens
      the soul's turn. A request row whose sender is the person is
      answered the same way: no send writes one, but such a row stays
      pending until its member answers it.
    * A line of the server's is a turn of the soul under the `schedule`
      origin, whatever names its text holds: a line with nobody present
      asks no crew member. A schedule's line (`:schedule`) is sent as the
      person, into a daily thread or the workspace thread the schedule
      names (`Aqua.ScheduleTurns`), and a post of the server's own
      (`:server`) by the server (`Prima.Author.system/0`), into a daily
      thread. No other kind of thread admits one.
    * A workspace thread's opening (`:opening`, the row its opening's
      transaction wrote there) is a turn of the soul in that workspace
      thread, which works it, sent by the person who asked.
    * A workspace thread's report (`:report`) is a turn of the soul in a
      daily thread, sent by the soul that worked it. No other kind of
      thread admits one.

  Anything else is refused `:not_addressable`.
  """

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  # A person's rooms: the threads a crew member's child thread works under.
  @rooms Aqua.Tape.room_kinds()

  # One human line, in bytes: the one bound every sender passes through.
  @max_message_bytes 32 * 1024
  @person "person"
  @server Prima.Author.system()

  @typedoc "What a send is: a turn of the named agent, opened or a steer of one."
  @type decision :: {:turn, String.t()}

  @typedoc """
  The thread a send lands in, as the runner read it: its kind, its room
  (`parent_id`, for a child thread) and its member (`agent`).
  """
  @type thread :: %{
          id: String.t(),
          kind: String.t(),
          parent_id: String.t() | nil,
          agent: String.t() | nil
        }

  @doc "The `sent_by` of a person's message."
  @spec person() :: String.t()
  def person, do: @person

  @doc """
  Admit `text` from `ctx` into `thread`, or refuse it with the reason the
  sender is told: `:empty`, `:message_too_long`, `:archived`,
  `:not_member`, `:not_addressable`. `opts`:
  `:attachments`, `:schedule` (a
  schedule's line) and `:server` (a post of the server's own), each
  admitted only under the `schedule` origin, `:opening`
  (the opening row a workspace thread's delivery starts), `:report` (a
  workspace thread's report delivered to a daily thread), `:sent_by`
  (`"person"` when absent), `:request` (the request row a delivery
  carries into a child thread) and `:reply` (`%{request: row, ...}`, the
  request a member's reply answers). Answers the decision and the
  trimmed text.
  """
  @spec check(Context.t(), String.t(), thread(), String.t(), keyword()) ::
          {:ok, decision(), String.t()} | {:error, term()}
  def check(%Context{} = ctx, athanor_id, thread, text, opts) do
    text = String.trim(text || "")
    attachments = Keyword.get(opts, :attachments, [])

    cond do
      text == "" and attachments == [] -> {:error, :empty}
      byte_size(text) > @max_message_bytes -> {:error, :message_too_long}
      true -> with :ok <- standing(ctx, athanor_id), do: addressed(ctx, thread, text, opts)
    end
  end

  @doc "The athanor is open and the caller's own."
  @spec standing(Context.t(), String.t()) ::
          :ok | {:error, :archived | :not_member | :unavailable}
  def standing(%Context{user_id: user_id} = ctx, athanor_id) do
    cond do
      ctx.athanor_id != athanor_id ->
        {:error, :not_member}

      not Athanors.active?(athanor_id) ->
        {:error, :archived}

      not Users.own_athanor?(user_id, athanor_id) ->
        {:error, :not_member}

      true ->
        case Sanctum.Tenancy.revalidate(ctx) do
          {:ok, %Context{authenticated: true, athanor_id: ^athanor_id}} -> :ok
          {:ok, _} -> {:error, :not_member}
          {:error, :unavailable} = error -> error
        end
    end
  end

  @doc """
  Whether the turn of `agent` in `thread` may ask `member`: only the
  soul's turn in a room asks, and only a crew member of `roster` (the
  athanor's agents, the soul first) is asked.
  """
  @spec request(thread(), String.t(), String.t(), [map()]) :: :ok | {:error, :not_addressable}
  def request(%{kind: kind}, agent, member, roster) when kind in @rooms do
    if Prima.AgentRef.soul?(agent) and member?(roster, member),
      do: :ok,
      else: {:error, :not_addressable}
  end

  def request(_thread, _agent, _member, _roster), do: {:error, :not_addressable}

  @doc "Whether `name` is a crew member of `roster`: an agent there that is not the soul."
  @spec member?([map()], String.t()) :: boolean()
  def member?(roster, name) when is_binary(name) do
    not Prima.AgentRef.soul?(name) and Enum.any?(roster, &(&1["name"] == name))
  end

  def member?(_roster, _name), do: false

  defp addressed(ctx, thread, text, opts) do
    sent_by = Keyword.get(opts, :sent_by, @person)

    decided =
      cond do
        Keyword.has_key?(opts, :schedule) -> scheduled(thread, sent_by, ctx.origin)
        Keyword.get(opts, :server) == true -> servers(thread, sent_by, @server, ctx.origin)
        true -> address(thread, sent_by, opts)
      end

    case decided do
      {:ok, decision} -> {:ok, decision, text}
      {:error, _} = refused -> refused
    end
  end

  defp address(thread, sent_by, opts) do
    cond do
      opening = Keyword.get(opts, :opening) -> opening(thread, sent_by, opening)
      Keyword.has_key?(opts, :report) -> report(thread, sent_by)
      reply = Keyword.get(opts, :reply) -> reply(thread, sent_by, reply)
      request = Keyword.get(opts, :request) -> delivered(thread, sent_by, request)
      sent_by == @person -> persons(thread)
      true -> {:error, :not_addressable}
    end
  end

  # A schedule's line, sent as its person, on a daily thread or on the
  # workspace thread a turn there set it from: the soul's turn, whatever
  # names its text holds.
  defp scheduled(%{kind: kind}, @person, :schedule) when kind in ["daily", "workspace"],
    do: {:ok, {:turn, Prima.AgentRef.soul_name()}}

  defp scheduled(_thread, _sent_by, _origin), do: {:error, :not_addressable}

  # A line of the server's own on a daily thread, sent by the server: the
  # soul's turn, whatever names its text holds.
  defp servers(%{kind: "daily"}, sent_by, sent_by, :schedule),
    do: {:ok, {:turn, Prima.AgentRef.soul_name()}}

  defp servers(_thread, _sent_by, _expected, _origin), do: {:error, :not_addressable}

  # An opening, delivered into the workspace thread that holds it, sent by
  # the person who asked.
  defp opening(%{kind: "workspace", id: thread_id}, @person, %{thread_id: thread_id}),
    do: {:ok, {:turn, Prima.AgentRef.soul_name()}}

  defp opening(_thread, _sent_by, _opening), do: {:error, :not_addressable}

  # A report, delivered into a daily thread by the soul whose workspace
  # thread it reports.
  defp report(%{kind: "daily"}, sent_by) when is_binary(sent_by) do
    if Prima.AgentRef.soul?(sent_by),
      do: {:ok, {:turn, sent_by}},
      else: {:error, :not_addressable}
  end

  defp report(_thread, _sent_by), do: {:error, :not_addressable}

  # A member's reply: on the thread of the request it answers, which was
  # addressed to it, a turn of the soul. A request row the person sent,
  # which no send writes but which stays pending until answered, is
  # answered to the soul as well.
  defp reply(
         %{kind: kind, id: thread_id},
         member,
         %{request: %{thread_id: thread_id, addressee: member, sent_by: asker}}
       )
       when kind in @rooms and is_binary(member) and member != @person do
    if asker == @person or Prima.AgentRef.soul?(asker),
      do: {:ok, {:turn, Prima.AgentRef.soul_name()}},
      else: {:error, :not_addressable}
  end

  defp reply(_thread, _sent_by, _reply), do: {:error, :not_addressable}

  # A request delivered into the child thread of its member, under its
  # room, sent by whoever sent it.
  defp delivered(
         %{kind: "crew", parent_id: room, agent: member},
         sent_by,
         %{thread_id: room, addressee: member, sent_by: sent_by}
       )
       when is_binary(room) and is_binary(member),
       do: {:ok, {:turn, member}}

  defp delivered(_thread, _sent_by, _request), do: {:error, :not_addressable}

  # A person in a room speaks to the soul, whatever names the text holds;
  # a person in a child thread speaks to nobody.
  defp persons(%{kind: kind}) when kind in @rooms, do: {:ok, {:turn, Prima.AgentRef.soul_name()}}
  defp persons(_thread), do: {:error, :not_addressable}
end
