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
  addressee. The thread is the person's own (`kind: "own"`, a room) or a
  crew member's child thread (`kind: "crew"`, its `agent` the member):

    * A person's message in a room addresses the soul, or the crew
      member it names (an `@name`, else an explicit pick): the soul's is
      a turn, a member's a request to it. In a child thread it addresses
      the thread's member, and naming anyone else is refused.
    * A turn of the soul may address any crew member: that is
      `crew.ask` (`Aqua.Crew`), whose request row this rule admits
      (`request/3`).
    * A request delivered into a child thread is a turn of the member
      there, sent by whoever sent the request.
    * A turn of a child thread may address only the thread and request
      that asked it: its reply lands on the request's thread, addressed
      to the request's sender, and opens the soul's turn when that sender
      is the soul, or is room content when it is the person.

  Anything else is refused `:not_addressable`.
  """

  alias Aqua.Roster
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  # One human line, in bytes: the one bound every sender passes through.
  @max_message_bytes 32 * 1024
  @person "person"

  @typedoc """
  What a send is: a turn of the named agent (opened, or a steer of one),
  a request to the named crew member, or room content that opens nothing.
  """
  @type decision :: {:turn, String.t()} | {:request, String.t()} | :content

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
  `:not_member`, `:no_agent`, `:not_addressable`. `opts`:
  `:attachments`, `:agents` (the sender's roster), `:agent` (an explicit
  pick), `:last` (the agent of the thread's last turn), `:sent_by`
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
      true -> with :ok <- standing(ctx, athanor_id), do: address(thread, text, opts)
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
  def request(%{kind: "own"}, agent, member, roster) do
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

  defp address(thread, text, opts) do
    sent_by = Keyword.get(opts, :sent_by, @person)

    case address(thread, sent_by, text, opts) do
      {:ok, decision} -> {:ok, decision, text}
      {:error, _} = refused -> refused
    end
  end

  defp address(thread, sent_by, text, opts) do
    cond do
      reply = Keyword.get(opts, :reply) -> reply(thread, sent_by, reply)
      request = Keyword.get(opts, :request) -> delivered(thread, sent_by, request)
      sent_by == @person -> persons(thread, text, opts)
      true -> {:error, :not_addressable}
    end
  end

  # A member's reply: on the thread of the request it answers, which was
  # addressed to it, to whoever sent that request.
  defp reply(
         %{kind: "own", id: thread_id},
         member,
         %{request: %{thread_id: thread_id, addressee: member, sent_by: asker}}
       )
       when is_binary(member) and member != @person do
    cond do
      asker == @person -> {:ok, :content}
      Prima.AgentRef.soul?(asker) -> {:ok, {:turn, asker}}
      true -> {:error, :not_addressable}
    end
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

  # A person in a room: an `@name` in the text wins, then an explicit
  # pick, then the agent of the previous turn, then the athanor's first
  # (the roster lists the soul first). The soul's is a turn, a member's a
  # request.
  defp persons(%{kind: "own"}, text, opts) do
    roster = Keyword.get(opts, :agents, [])
    {_stripped, mentioned} = Roster.parse_mention(text, roster)

    with {:ok, name} <-
           pick(roster, mentioned, Keyword.get(opts, :agent), Keyword.get(opts, :last)) do
      cond do
        Prima.AgentRef.soul?(name) -> {:ok, {:turn, name}}
        member?(roster, name) -> {:ok, {:request, name}}
        true -> {:error, :not_addressable}
      end
    end
  end

  # A person in a child thread speaks to its member, and to nobody else.
  defp persons(%{kind: "crew", agent: member}, text, opts) when is_binary(member) do
    roster = Keyword.get(opts, :agents, [])

    case Roster.parse_mention(text, roster) do
      {_text, nil} -> {:ok, {:turn, member}}
      {_text, %{"name" => ^member}} -> {:ok, {:turn, member}}
      {_text, _other} -> {:error, :not_addressable}
    end
  end

  defp persons(_thread, _text, _opts), do: {:error, :not_addressable}

  defp pick(roster, mentioned, explicit, last) do
    cond do
      match?(%{"name" => n} when is_binary(n), mentioned) -> {:ok, mentioned["name"]}
      match?(%{"name" => n} when is_binary(n), explicit) -> {:ok, explicit["name"]}
      is_binary(explicit) and explicit != "" -> {:ok, explicit}
      is_binary(last) and Prima.AgentRef.soul?(last) -> {:ok, last}
      match?(%{"name" => n} when is_binary(n), List.first(roster)) -> {:ok, hd(roster)["name"]}
      true -> {:error, :no_agent}
    end
  end
end
