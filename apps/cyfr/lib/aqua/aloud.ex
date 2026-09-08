# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Aloud do
  @moduledoc """
  Saying part of a private exchange out loud.

  Talking to your own agent happens in your own estate: your files, your
  credentials, nobody else in the room. Nothing you say there reaches a
  shared topic by inference, by plumbing, or because an agent was
  "summoned" — it reaches one because you said so.

  **This is the first deliberate copy in the system**, and it is the only
  one. Everywhere else, sharing is a grant that can be withdrawn; here the
  bytes genuinely move, because a transcript is not a capability. That
  asymmetry is the point rather than an oversight: you cannot un-say
  something, and pretending otherwise by "revoking" a line somebody has
  already read would be a worse lie than copying it honestly.

  ## What it refuses, and why

    * A source you cannot read, or a target you cannot write. Membership in
      both estates, checked separately — sharing is not a way to reach an
      estate you are not in, and there is **no operator bypass**: focusing
      an estate is an audited open, but a copy out of it is a second act,
      and it belongs to members alone.
    * A line that is not YOURS. You say aloud what you said — every
      selected message must be authored by the caller, or the verb would
      let one person speak another's words under their own name. One
      extension: a line your own assistant said to you, in your own
      athanor, is yours to share — it was said to nobody else. The copy
      says so (`shared_agent: true` in its payload) and is attributed to
      you, never to the assistant. A room's assistant's lines belong to
      the room and stay refused.
    * A copy into the SAME conversation. Nothing to say aloud; the line is
      already there.

  Attachments are copied as **bytes** into the target estate's own tree. A
  reference left pointing at the source would be a link into your private
  storage handed to everyone in the room — the read would fail for them if
  the boundary held, and leak if it did not. Copying is the only version of
  this that is both honest and reachable, and it is charged to the target
  estate's quota like any other upload.
  """

  alias Arca.ConversationStorage, as: Conversations
  alias Arca.Schemas.Message
  alias Aqua.Attachments
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Members, Users}

  @agent_author Message.agent_author()

  @type error ::
          :not_a_member
          | :not_the_author
          | :same_conversation
          | :not_found
          | :nothing_to_say
          | term()

  @doc """
  Copy `message_ids` from the conversation the caller is in onto a topic in
  `target_athanor_id`, attributed to the caller.

  The source is read under `ctx` as it stands — the estate you are already
  focused on, tenant-keyed like every other read. The **target estate is
  named**, because a conversation id alone would need a lookup that spans
  tenants, and there is no such read in this system by design.

  Returns the appended rows. The originals are untouched — saying something
  aloud does not move it out of your own thread.
  """
  @spec post(Context.t(), String.t(), [String.t()], String.t(), String.t()) ::
          {:ok, [Arca.Schemas.Message.t()]} | {:error, error()}
  def post(%Context{} = ctx, source_id, message_ids, target_athanor_id, target_id)
      when is_binary(source_id) and is_list(message_ids) and
             is_binary(target_athanor_id) and is_binary(target_id) do
    cond do
      source_id == target_id ->
        {:error, :same_conversation}

      message_ids == [] ->
        {:error, :nothing_to_say}

      true ->
        with :ok <- member_of(ctx, ctx.athanor_id),
             :ok <- member_of(ctx, target_athanor_id),
             # Membership was just proven for THIS user, so focus takes its
             # member branch (the operator arm is unreachable past
             # `member_of/2`) — and adds the archive refusal a raw swap
             # skipped: nothing is said aloud into a closed furnace.
             {:ok, target_ctx} <- Context.focus(ctx, target_athanor_id),
             {:ok, _} <- Conversations.get(target_ctx, target_id),
             {:ok, rows} <- take(ctx, source_id, message_ids) do
          copy(ctx, target_ctx, source_id, target_id, rows)
        else
          {:error, :not_found} -> {:error, :not_found}
          other -> other
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # Checked on BOTH sides, and on the source too rather than trusting the
  # focus: a context is a struct, and this is the one verb that crosses
  # estates. The tenant-keyed reads would refuse a foreign conversation
  # anyway; this refuses it by name instead of as a confusing miss.
  #
  # Deliberately NO `platform_admin` arm. An operator's open of an estate
  # is audited (`Context.focus/2`); a copy out of one is a second, quieter
  # act, and letting the capability bypass membership here would make it
  # an unaudited export verb. An operator who is not a member is refused
  # like anyone else.
  defp member_of(%Context{user_id: user_id}, athanor_id)
       when is_binary(user_id) and is_binary(athanor_id) do
    if Members.member?(user_id, athanor_id), do: :ok, else: {:error, :not_a_member}
  end

  defp member_of(_ctx, _athanor_id), do: {:error, :not_a_member}

  # In the order they were said, whatever order the caller listed them.
  # Fetched by id rather than by walking the thread: a person may say aloud
  # something from far up a long conversation.
  #
  # Author-only, enforced HERE and not in a client: every selected row must
  # be the caller's own, or — when the source is the caller's own athanor —
  # their assistant's answer to them. The copy is attributed to the caller,
  # so a foreign line would be one person speaking another's words under
  # their own name — refused whole, not filtered, so the person is told
  # rather than quietly published less than they picked (the same posture
  # as a missing attachment).
  defp take(ctx, conversation_id, message_ids) do
    found =
      message_ids
      |> Enum.uniq()
      |> Enum.flat_map(fn id ->
        case Conversations.get_message(ctx, id) do
          {:ok, %{conversation_id: ^conversation_id} = row} -> [row]
          _ -> []
        end
      end)
      |> Enum.sort_by(& &1.seq)

    cond do
      found == [] -> {:error, :not_found}
      Enum.any?(found, &(not sayable?(&1, ctx))) -> {:error, :not_the_author}
      true -> {:ok, found}
    end
  end

  defp sayable?(%{author: author}, %Context{user_id: author}), do: true

  # An assistant's line is the caller's to share only when the source
  # estate is their own athanor — the one place it was said to them alone.
  defp sayable?(%{author: @agent_author, kind: "text"}, %Context{} = ctx),
    do: Users.own_athanor?(ctx.user_id, ctx.athanor_id)

  defp sayable?(_row, _ctx), do: false

  defp copy(source_ctx, target_ctx, source_id, target_id, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case say(source_ctx, target_ctx, source_id, target_id, row) do
        {:ok, appended} -> {:cont, {:ok, [appended | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, appended} -> {:ok, Enum.reverse(appended)}
      other -> other
    end
  end

  # The id is minted first so the blobs can be written under it before the
  # row exists — the same order `PrismWeb.ConversationPaneLive`
  # uses, and the reason `append/3` takes an `:id`. The target's viewers
  # hear of the row the way they hear of the runner's own — the copy has
  # to appear on the tape it was said onto.
  defp say(source_ctx, target_ctx, source_id, target_id, row) do
    message_id = Cyfr.UUID7.generate_id("msg")

    with {:ok, files} <- carry(source_ctx, source_id, row),
         {:ok, refs} <- Attachments.store(target_ctx, target_id, message_id, files) do
      payload =
        %{"aloud_from" => %{"conversation_id" => source_id, "message_id" => row.id}}
        |> put_shared_agent(row)
        |> put_refs(refs)

      case Conversations.append(target_ctx, target_id, %{
             id: message_id,
             author: target_ctx.user_id || Message.system_author(),
             kind: "text",
             content: row.content || "",
             payload: payload
           }) do
        {:ok, appended} ->
          Aqua.ConversationRunner.announce(appended)
          {:ok, appended}

        {:error, _} = err ->
          # The bytes landed but the row did not: leave nothing behind in
          # the target estate's quota.
          Attachments.discard(target_ctx, target_id, message_id, refs)
          err
      end
    end
  end

  defp put_refs(payload, []), do: payload
  defp put_refs(payload, refs), do: Map.put(payload, "attachments", refs)

  # The copy is the person's, attributed to them; the mark says the words
  # were their assistant's, so a room can render "shared from AQUA".
  defp put_shared_agent(payload, %{author: @agent_author}),
    do: Map.put(payload, "shared_agent", true)

  defp put_shared_agent(payload, _row), do: payload

  # A message's blobs as upload-shaped files, read out of the source estate
  # so `Attachments.store/4` can write them into the target's own tree.
  defp carry(source_ctx, source_id, row) do
    case Attachments.refs_of(row) do
      [] ->
        {:ok, []}

      refs ->
        loaded =
          Attachments.load(
            source_ctx,
            source_id,
            Enum.map(refs, &%{message_id: row.id, ref: &1})
          )

        if length(loaded) == length(refs) do
          {:ok, Enum.map(loaded, &to_file/1)}
        else
          # Some blob is gone. Appending the text without its attachment
          # would quietly say less than the person chose to say.
          {:error, :attachment_missing}
        end
    end
  end

  defp to_file(%{"filename" => name, "media_type" => type, "data" => data}) do
    %{"filename" => name, "media_type" => type, "bytes" => Base.decode64!(data)}
  end
end
