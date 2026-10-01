# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Confirmation do
  @moduledoc """
  The `confirmation` tool: a person's pending confirmations of sensitive
  changes, in the athanor in focus. A confirmation is never a permission
  for a similar change: each proves one record, which the change's
  repeat, naming the record's id, consumes (`Sanctum.Consent.Authz`).

    * `confirm` proves one with a passkey assertion over its digest
      (`Sanctum.Passkeys.assert/3`) or the one-time code emailed for it
      (`Sanctum.Auth.EmailVerification.verify_code/3`), exactly one of the
      two. A forced-fresh OpenID Connect login confirms the record on its
      own page, once the person approves the preview it shows there
      (`Sanctum.Auth.OIDC.reauth_callback/1`, `reauth_decide/3`).
    * `reauth` begins that login, answering the issuer's URL, or sends the
      code.
    * `pending` answers the person's open confirmations with the previews
      the home stored, so another of their devices shows the home's record
      rather than the asking client's word, and with the WebAuthn request
      options a passkey proves each with.
    * `cancel` ends one.

  Every action is the person's own, on the external plane, through an
  interactive surface (`consent: :interactive`), and reaches only records
  of the context's own person.

  The stream `confirmation.changes` rides the bus's `confirmations` topic
  (`Cyfr.Bus.confirmations/2`), bound to its holder, the context's own
  person: a client of theirs hears each record of theirs opened,
  confirmed, consumed, cancelled, voided or expired, as its `id`, its
  `operation` and its `expires_at`, never the arguments or the preview,
  which it reads through `pending` under its own session.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Auth.{EmailVerification, OIDC}
  alias Sanctum.{Context, Passkeys, Pairing}

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new(
          "confirmation",
          "confirm",
          "Confirm a pending change",
          [
            id(),
            Arg.new("assertion", :json,
              description:
                "confirm: a WebAuthn assertion over the confirmation's digest, from a passkey registered here"
            ),
            Arg.new("code", :string,
              description: "confirm: the one-time code sent to your verified email for it"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "confirmation",
          "reauth",
          "Begin a re-authentication for a pending change",
          [
            id(),
            Arg.new("method", :string,
              required: true,
              enum: ["oidc", "email"],
              description:
                "reauth: a fresh OpenID Connect sign-in, or a one-time code to your verified email"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("confirmation", "pending", "List your pending confirmations", [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("confirmation", "cancel", "Cancel a pending change", [id()],
          kind: :write,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Your pending confirmations of sensitive changes: confirm one with a passkey, a fresh sign-in or an emailed code, list them with what each would change, or cancel one.",
      title: "Confirmations"
    )
  end

  defp id,
    do:
      Arg.new("id", :string,
        required: true,
        description: "The pending confirmation, as the confirmation_required signal named it"
      )

  @doc false
  # The one stream a person's clients hear their confirmations on: bound
  # to its holder, so a grant reaches that person's topic alone.
  def streams do
    [
      %Prima.Provider.Stream{
        name: "confirmation.changes",
        topic: :confirmations,
        projection: ["id", "operation", "expires_at"],
        subject: ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z",
        bind: :holder,
        deadline_bound: 86_400
      }
    ]
  end

  def handle(%Context{} = ctx, %{"action" => "confirm", "id" => id} = args) when is_binary(id) do
    case {args["assertion"], args["code"]} do
      {assertion, nil} when is_map(assertion) ->
        answered(Passkeys.assert(ctx, id, assertion))

      {nil, code} when is_binary(code) and code != "" ->
        answered(EmailVerification.verify_code(ctx, id, code))

      _neither_or_both ->
        {:error,
         {:invalid_argument, "Give exactly one proof: a passkey assertion or the emailed code"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "reauth", "id" => id, "method" => method})
      when is_binary(id) do
    case method do
      "oidc" -> answered(OIDC.reauth_url(ctx, id))
      "email" -> answered(EmailVerification.send_code(ctx, id))
      _other -> {:error, {:invalid_argument, "The method is oidc or email"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "pending"}) do
    with {:ok, user_id} <- person(ctx),
         {:ok, rows} <- open(ctx, user_id),
         {:ok, credentials} <- credentials(ctx, user_id) do
      {:ok, %{confirmations: Enum.map(rows, &pending(&1, credentials))}}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "cancel", "id" => id}) when is_binary(id) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx),
         {:ok, _row} <- own(actor, id, user_id) do
      case Arca.PendingConfirmations.cancel(actor, id) do
        {:ok, row} ->
          Sanctum.Consent.Authz.announce(:cancelled, row)
          {:ok, %{id: row.id, state: row.state}}

        {:error, :not_open} ->
          {:error, refusal(:not_pending)}

        {:error, _unanswered} ->
          {:error, refusal(:unavailable)}
      end
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => action}) when action in ~w(confirm reauth cancel),
    do: {:error, {:invalid_argument, "Missing required argument: id"}}

  def handle(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "confirmation.#{action}"}}

  def handle(_ctx, _args), do: {:error, :action_missing}

  defp answered({:ok, answer}), do: {:ok, answer}
  defp answered({:error, reason}), do: {:error, refusal(reason)}

  # A person, in an athanor, who could give a proof.
  defp person(%Context{} = ctx) do
    if Pairing.can_confirm?(ctx) and is_binary(ctx.athanor_id) and ctx.athanor_id != "",
      do: {:ok, ctx.user_id},
      else: {:error, :unauthenticated}
  end

  defp open(ctx, user_id) do
    case Arca.PendingConfirmations.list_open(Context.actor(ctx), user_id) do
      {:ok, rows} -> {:ok, rows}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The person's active passkeys here, read as the context's own.
  defp credentials(ctx, user_id) do
    case Arca.Passkeys.list(Context.actor(ctx), user_id, state: :active) do
      {:ok, rows} ->
        {:ok,
         for(
           row <- rows,
           row.rp_id == Passkeys.rp_id(),
           do: %{"type" => "public-key", "id" => row.credential_id}
         )}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp own(actor, id, user_id) do
    case Arca.PendingConfirmations.get(actor, id) do
      {:ok, %{user_id: ^user_id} = row} -> {:ok, row}
      {:ok, _another} -> {:error, {:not_found, "confirmation", id}}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", id}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # An open record as a client of its person reads it: what it would
  # change, as the home stored it, and how a passkey proves it — the
  # challenge is the raw bytes of the record's digest.
  defp pending(row, credentials) do
    "sha256:" <> hex = row.digest

    %{
      id: row.id,
      operation: row.operation,
      action: row.action,
      preview: Jason.decode!(row.preview),
      state: row.state,
      expires_at: row.expires_at,
      webauthn: %{
        "challenge" => Prima.Identity.Encoding.b64(Base.decode16!(hex, case: :lower)),
        "rpId" => row.rp_id,
        "allowCredentials" => credentials,
        "userVerification" => "required",
        "timeout" => max(DateTime.diff(row.expires_at, DateTime.utc_now(), :millisecond), 0)
      }
    }
  end

  # The confirmations' own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`), each with the sentence its person reads; the
  # vocabulary's and the stores' own reasons pass as they are.
  defp refusal(:assertion_refused),
    do:
      refused(
        :unauthenticated,
        :assertion_refused,
        "The passkey's answer does not prove this confirmation here"
      )

  defp refusal(:code_refused),
    do: refused(:unauthenticated, :code_refused, "That code does not confirm this change")

  defp refusal(:confirmation_cancelled),
    do:
      refused(
        :forbidden,
        :confirmation_cancelled,
        "Too many wrong codes: this confirmation was cancelled; ask for the change again"
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
