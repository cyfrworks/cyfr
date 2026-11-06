# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Confirmation do
  @moduledoc """
  The `confirmation` tool: a person's pending confirmations of sensitive
  changes, in the athanor in focus. A confirmation is never a permission
  for a similar change: each proves one record, which the change's
  repeat consumes (`Sanctum.Consent.Authz`).

  Every action names a record by its public `ref`
  (`Prima.Confirmation.ref/1`), as `pending` and the stream list it, so
  any client of the person reads, proves and cancels it. None takes the
  secret `id` the `confirmation_required` signal answered to the asking
  request: that secret is presented only by that request's client, when
  it repeats the change (`PrismWeb.Ops`'s `confirmation_id:`, the device
  intent's `confirmation_id`), never as an argument, so no request-log row
  keeps it, and a `ref` never repeats a change.

  A record is confirmed by a key of the person's account signing this
  CYFR's `confirm` request that names it (`Sanctum.SignIn`), and by
  nothing else: no sign-in method, emailed code or other CYFR's word.

    * `request` mints that request for one pending record of the caller's
      own person, bound to what asked: a person's browser by their
      session, with `url`, the account pages' sign page that a passkey
      signs it at, or a protected device by its own channel, which signs
      it after its local unlock.
    * `confirm` takes the answer and dispatches it: a passkey's answer
      (the fragment the account pages returned, under the session the
      request was bound to) or a device's (`{challenge, kid, sig}`, on
      its own channel). The answer must be to that record's request, by a
      key the person's account lists under the head this CYFR reads
      (`Sanctum.SignIn.answer/3`), and the record is then confirmed by
      that key at that head.
    * `pending` answers the person's open confirmations, or with a
      `request` the one record that ref names, with the previews the CYFR
      stored, so another of their devices shows the CYFR's record rather
      than the asking client's word, and with the asker, a name for the
      client that asked, so the person tells their own request from
      another's; with `methods`, the proof this client gives: `passkey`
      for a person's browser, `device` for a protected device's channel.
    * `cancel` ends one.

  While the CYFR's storage reserve is depleted (`Arca.StorageReserve`),
  `pending` answers only the person's records of an action declared
  `reduces_authority`, so a client reconnecting then still finds a
  revocation waiting on it, and the gate admits a `request`, a proof or a
  cancel only by a ref naming such a record: the freed reserve completes a
  revocation, not another change.

  Every action is the person's own, on the external plane, through an
  interactive surface (`consent: :interactive`), and reaches only records
  of the context's own person.

  The stream `confirmation.changes` rides the bus's `confirmations` topic
  (`Cyfr.Bus.confirmations/2`), bound to its holder, the context's own
  person: a client of theirs hears each record of theirs opened,
  confirmed, consumed, cancelled, voided or expired, as its `ref`, what
  happened to it (`kind`), its `operation` and its `expires_at`, never the
  secret, the arguments or the preview, which it reads through `pending`
  under its own session. The asking client knows its own record's events
  by the `ref` of the secret it holds, and repeats its change once its
  record is confirmed, wherever it was proven.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.{Context, Pairing}

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new(
          "confirmation",
          "request",
          "Ask a key of your account to confirm a pending change",
          [ref()],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "confirmation",
          "confirm",
          "Confirm a pending change",
          [
            ref(),
            Arg.new("answer", :json,
              required: true,
              description:
                "confirm: the answer to the confirmation's request, from a passkey at the account pages or from your device"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "confirmation",
          "pending",
          "List your pending confirmations",
          [
            Arg.new("request", :string,
              description:
                "pending: one pending confirmation's ref, to read that request's record alone"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("confirmation", "cancel", "Cancel a pending change", [ref()],
          kind: :write,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Your pending confirmations of sensitive changes: confirm one with a passkey of your account or a device of yours after its unlock, list them with what each would change and which client asked, or cancel one.",
      title: "Confirmations"
    )
  end

  defp ref,
    do:
      Arg.new("ref", :string,
        required: true,
        description:
          "The pending confirmation's ref, as confirmation.pending and the confirmation.changes stream name it"
      )

  @doc false
  # The one stream a person's clients hear their confirmations on: bound
  # to its holder, so a grant reaches that person's topic alone.
  def streams do
    [
      %Prima.Provider.Stream{
        name: "confirmation.changes",
        topic: :confirmations,
        projection: ["ref", "kind", "operation", "expires_at"],
        subject: ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z",
        bind: :holder,
        deadline_bound: 86_400
      }
    ]
  end

  def handle(%Context{} = ctx, %{"action" => "request", "ref" => ref}) when is_binary(ref) do
    with {:ok, user_id} <- person(ctx),
         {:ok, _row} <- own(Context.actor(ctx), ref, user_id),
         {:ok, binding, opts} <- Sanctum.SignIn.binding(ctx) do
      case Sanctum.SignIn.request(:confirm, binding, [ctx: ctx, ref: ref] ++ opts) do
        {:ok, %{request: request, url: url}} ->
          {:ok, Prima.MapUtil.put_present(%{request: Prima.SignIn.encode(request)}, :url, url)}

        {:error, reason} ->
          {:error, refusal(reason)}
      end
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "confirm", "ref" => ref, "answer" => answer})
      when is_binary(ref) do
    with {:ok, user_id} <- person(ctx),
         {:ok, _row} <- own(Context.actor(ctx), ref, user_id),
         {:ok, binding, _opts} <- Sanctum.SignIn.binding(ctx),
         {:ok, answer} <- answer(answer) do
      case Sanctum.SignIn.answer(answer, binding, ref: ref) do
        {:ok, %{purpose: :confirm, ref: ^ref}} ->
          confirmed(ctx, ref)

        {:error, reason} ->
          {:error, refusal(reason)}
      end
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "pending"} = args) do
    with {:ok, user_id} <- person(ctx),
         {:ok, rows} <- open(ctx, user_id) do
      methods = if device?(ctx), do: ["device"], else: ["passkey"]

      confirmations =
        rows
        |> requested(args["request"])
        |> Enum.map(&pending(&1, methods))

      {:ok, %{confirmations: confirmations}}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cancel", "ref" => ref}) when is_binary(ref) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx),
         {:ok, _row} <- own(actor, ref, user_id) do
      case Arca.PendingConfirmations.cancel(actor, ref) do
        {:ok, row} ->
          Sanctum.Consent.Authz.announce(:cancelled, row)
          {:ok, %{ref: row.ref, state: row.state}}

        {:error, :not_open} ->
          {:error, refusal(:not_pending)}

        {:error, _unanswered} ->
          {:error, refusal(:unavailable)}
      end
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => "confirm", "ref" => ref}) when is_binary(ref),
    do: {:error, {:invalid_argument, "Missing required argument: answer"}}

  def handle(_ctx, %{"action" => action}) when action in ~w(request confirm cancel),
    do: {:error, {:invalid_argument, "Missing required argument: ref"}}

  def handle(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "confirmation.#{action}"}}

  def handle(_ctx, _args), do: {:error, :action_missing}

  # A passkey's answer as the fragment the account pages returned, or a
  # device's as its JSON.
  defp answer(fragment) when is_binary(fragment), do: {:ok, fragment}

  defp answer(%{} = map) do
    case Prima.SignIn.DeviceAnswer.decode(map) do
      {:ok, answer} -> {:ok, answer}
      {:error, _malformed} -> {:error, :answer_refused}
    end
  end

  defp answer(_answer), do: {:error, :answer_refused}

  # The confirmed record, as the person's clients read it.
  defp confirmed(ctx, ref) do
    case Arca.PendingConfirmations.get(Context.actor(ctx), ref) do
      {:ok, row} -> {:ok, %{ref: row.ref, state: row.state, expires_at: row.expires_at}}
      {:error, _unanswered} -> {:ok, %{ref: ref, state: "confirmed"}}
    end
  end

  # A protected device's channel: the device gives its own proof.
  defp device?(%Context{auth_method: :device, client_id: client_id}) when is_binary(client_id),
    do: true

  defp device?(%Context{}), do: false

  # A person, in an athanor, who could give a proof.
  defp person(%Context{} = ctx) do
    if Pairing.can_confirm?(ctx) and is_binary(ctx.athanor_id) and ctx.athanor_id != "",
      do: {:ok, ctx.user_id},
      else: {:error, :unauthenticated}
  end

  # The records a `pending` read answers: the one its `request` names, or
  # every open one. While the storage reserve is depleted, only those of
  # an action declared `reduces_authority` (`Sanctum.Catalog`), whose
  # confirmations the gate still admits.
  defp requested(rows, request) do
    rows = if is_binary(request), do: Enum.filter(rows, &(&1.ref == request)), else: rows

    if Arca.StorageReserve.depleted?(),
      do: Enum.filter(rows, &Sanctum.Catalog.reduces_authority?(&1.operation)),
      else: rows
  end

  defp open(ctx, user_id) do
    case Arca.PendingConfirmations.list_open(Context.actor(ctx), user_id) do
      {:ok, rows} -> {:ok, rows}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The record `ref` names, in the context's athanor, of the context's own
  # person: a ref of another person, another athanor or none is not found.
  defp own(actor, ref, user_id) do
    case Arca.PendingConfirmations.get(actor, ref) do
      {:ok, %{user_id: ^user_id} = row} -> {:ok, row}
      {:ok, _another} -> {:error, {:not_found, "confirmation", ref}}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # An open record as a client of its person reads it: its ref, what it
  # would change, as the CYFR stored it, which client asked, and the proof
  # this client gives.
  defp pending(row, methods) do
    %{
      ref: row.ref,
      operation: row.operation,
      action: row.action,
      preview: Jason.decode!(row.preview),
      asker: Jason.decode!(row.asker),
      state: row.state,
      expires_at: row.expires_at,
      methods: methods
    }
  end

  # The confirmations' own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`), each with the sentence its person reads; the
  # vocabulary's and the stores' own reasons pass as they are.
  defp refusal(:answer_refused),
    do:
      refused(
        :unauthenticated,
        :answer_refused,
        "That answer does not confirm this change here: confirm it again"
      )

  defp refusal(:not_pending),
    do: refused(:conflict, :not_pending, "This confirmation is no longer waiting for a proof")

  defp refusal(:expired),
    do: refused(:forbidden, :expired, "This confirmation expired; ask for the change again")

  defp refusal(:revoked),
    do:
      refused(
        :forbidden,
        :revoked,
        "The device or passkey that would confirm this no longer stands here"
      )

  defp refusal(:unauthenticated),
    do:
      refused(
        :unauthenticated,
        :unauthenticated,
        "Only a person signed in here, or on a device of theirs, can confirm"
      )

  defp refusal(reason), do: reason

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}
end
