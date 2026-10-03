# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Streams do
  @moduledoc """
  The gate's one entry for streams: an open is a declared stream intent,
  admitted once, recorded once, and answered with a bounded grant
  (`Prima.StreamGrant`).

  The stream is looked up in the table the providers declared
  (`Grimoire.Catalog.lookup_stream/1`); an undeclared name is refused as
  an undeclared operation is, `not_found`. The caller is judged as an
  action with the default declaration is (`Grimoire.Catalog.authorize_stream/2`):
  not a guest plane, a member that holds its control plane, a signed-in
  caller, an athanor to scope the grant to, a subject the stream's
  anchored grammar admits, and a credential that has not ended. A
  holder-bound stream (`bind: :holder`) takes the holder's own user id as
  its subject: supplied when the open names none, and any other refused as
  a subject the stream does not take.

  Every open is one decision (`Grimoire.Decisions`) named
  `stream:<name>`, whose request-log row's method is `streams/open`,
  appended under the log's own budget like an operation's. An admitted
  open's work is the grant it answers, so the decision closes as
  succeeded once the grant exists.

  The grant names the stream's `Cyfr.Bus` roster key and its subject,
  never a concrete topic: the gate never names the bus. The delivery owner
  above it resolves the topic (`Cyfr.Bus.granted_topic/2`), subscribes,
  and keeps enforcing the grant — its deadline, the caller's standing,
  overflow. Nothing here subscribes to anything, and a reconnect is a new
  open.
  """

  alias Grimoire.{Catalog, Decisions, Error}
  alias Sanctum.Context

  @method "streams/open"

  @doc """
  Admit the open of stream `name` with `subject` (nil for a stream that
  takes none) for `ctx`: `{:ok, grant}` whose deadline is the lesser of
  the stream's declared bound from now and the caller's credential
  deadline, or `{:error, %Prima.Refusal{stage: :admission}}`. Either way
  exactly one decision is recorded.
  """
  @spec open(Context.t(), String.t(), String.t() | nil) ::
          {:ok, Prima.StreamGrant.t()} | {:error, Prima.Refusal.t()}
  def open(%Context{} = ctx, name, subject) when is_binary(name) do
    # The open's identity, minted before its first check: one decision
    # per open, so two opens under one request never share a call id.
    ctx = %{
      ctx
      | request_id: ctx.request_id || Prima.UUID7.request_id(),
        call_id: Decisions.call_id!(nil)
    }

    tool = "stream:" <> name
    now = DateTime.utc_now()
    projection = %{method: @method, input: %{"stream" => name, "subject" => subject}}

    case admit(ctx, name, tool, subject, now) do
      {:ok, grant} ->
        record(ctx, tool, now, :admitted, nil, projection)

        Decisions.close(ctx, ctx.call_id, %{
          result: {:ok, %{"grant_id" => grant.grant_id}},
          duration_ms: 0
        })

        {:ok, grant}

      {:error, reason} ->
        refusal = Error.admission(reason)
        record(ctx, tool, now, :refused, refusal, projection)
        {:error, refusal}
    end
  end

  # The checks, in order: the plane and the member's slot before anything
  # is read, the declaration, the caller, the tenant the grant is scoped
  # to, the holder a holder-bound stream binds its subject to, the
  # subject, and the credential's remaining life.
  defp admit(ctx, name, tool, subject, now) do
    with :ok <- external_plane(ctx, tool),
         :ok <- control_plane(),
         {:ok, {_provider, stream}} <- declared(name),
         :ok <- Catalog.authorize_stream(tool, ctx),
         :ok <- tenant(ctx),
         {:ok, subject} <- bound_subject(stream, ctx, subject),
         :ok <- subject(stream, subject),
         {:ok, deadline} <- deadline(stream, ctx, now) do
      {:ok,
       %Prima.StreamGrant{
         topic: stream.topic,
         projection: stream.projection,
         subject: subject,
         deadline: deadline,
         grant_id: Prima.UUID7.generate_id("sgr")
       }}
    end
  end

  # A guest-planed context reaches nothing outside its chain, and a stream
  # is no in-chain operation.
  defp external_plane(%Context{plane: :guest}, tool), do: {:error, {:guest_plane_call, tool}}
  defp external_plane(%Context{}, _tool), do: :ok

  # A member that lost its slot admits no work, and a grant is work's door.
  defp control_plane do
    if Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost}
  end

  defp declared(name) do
    case Catalog.lookup_stream(name) do
      {:ok, entry} -> {:ok, entry}
      :miss -> {:error, {:not_found, "Stream", name}}
    end
  end

  # Every grantable topic is the athanor's own; a caller in none has no
  # topic to be granted.
  defp tenant(%Context{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "",
    do: :ok

  defp tenant(%Context{}), do: {:error, :no_athanor}

  # A holder-bound stream's subject is the holder's own user id: supplied
  # when the open names none, and refused when it names anyone else's, so
  # one person's topic is never granted to another.
  defp bound_subject(%Prima.Provider.Stream{bind: :holder} = stream, ctx, subject) do
    case {ctx.user_id, subject} do
      {holder, _subject} when not is_binary(holder) or holder == "" ->
        {:error,
         {:invalid_argument,
          "The stream #{stream.name} is delivered to its holder, and this caller names no person"}}

      {holder, nil} ->
        {:ok, holder}

      {holder, holder} ->
        {:ok, holder}

      {_holder, _another} ->
        {:error, subject_refusal(stream)}
    end
  end

  defp bound_subject(%Prima.Provider.Stream{}, _ctx, subject), do: {:ok, subject}

  defp subject(stream, subject) do
    if Prima.Provider.Stream.admits?(stream, subject),
      do: :ok,
      else: {:error, subject_refusal(stream)}
  end

  defp subject_refusal(stream),
    do: {:invalid_argument, "The stream #{stream.name} does not take that subject"}

  # Never later than the stream's bound, nor the credential the open was
  # made under; a credential already ended opens nothing.
  defp deadline(stream, %Context{credential_deadline: credential}, now) do
    bound = DateTime.add(now, stream.deadline_bound, :second)

    case credential do
      nil ->
        {:ok, bound}

      %DateTime{} = credential ->
        cond do
          DateTime.compare(credential, now) != :gt -> {:error, :expired_credential}
          DateTime.compare(credential, bound) == :lt -> {:ok, credential}
          true -> {:ok, bound}
        end
    end
  end

  defp record(ctx, tool, now, admission, refusal, projection) do
    decision = %Prima.Decision{
      call_id: ctx.call_id,
      request_id: ctx.request_id,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      plane: :external,
      tool: Decisions.bounded(tool),
      inserted_at: now,
      admission: admission,
      refusal_class: refusal && refusal.class,
      reason: refusal && refusal.message
    }

    Decisions.open(ctx, decision, projection)
  end
end
