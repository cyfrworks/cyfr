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

    * `confirm` proves one with a passkey assertion over its digest
      (`Sanctum.Passkeys.assert/3`), the one-time code emailed for it
      (`Sanctum.Auth.EmailVerification.verify_code/3`) or a protected
      device's `device_proof` over the `confirm` challenge `pending`
      answered it (`Sanctum.DeviceUnlock.confirm_proof/3`), or, for a
      person whose keys are at another home, the `home_assertion` that home
      certified after the person confirmed there
      (`Sanctum.RemoteCertification.verify_confirmation/3`, recorded as
      `home`), exactly one of the four. A device proof is taken only on that device's own channel
      (`auth_method: :device`, a client that reports a holder), for a
      record of the device's person in the athanor it is certified for,
      and records the device as the confirmer; the device's screen draws
      the preview the home stored and asks its person to unlock again
      before it signs. A forced-fresh OpenID Connect login confirms the record on its
      own page, once the person approves the preview it shows there
      (`Sanctum.Auth.OIDC.reauth_callback/1`, `reauth_decide/3`). A click
      or a tap alone proves nothing: only these proofs confirm a record.
    * `reauth` begins that login, answering the issuer's URL, or sends the
      code.
    * `pending` answers the person's open confirmations, or with a
      `request` the one record that ref names, with the previews
      the home stored, so another of their devices shows the home's record
      rather than the asking client's word; with the asker, a name for the
      client that asked, so the person tells their own request from
      another's; with the WebAuthn request options a passkey proves each
      with; and with `methods`, the proofs this person can give here, from
      `passkey` (a passkey of theirs is registered at this home), `oidc`
      (a fresh sign-in at the identity provider of their linked door),
      `email` (a code can reach their verified email) and `home` (their
      keys are at another home, which certifies their confirmation). A
      record of such a person carries `at_home`, what their browser
      carries to their own home for it: this home as `audience`, the
      record's `athanor`, `ref`, `digest`, `expires_at`, `preview` and its
      `preview_digest` (`Sanctum.RemoteCertification.preview_digest/1`). A
      client offers only those it can carry out. A sign-in and a code are
      offered only inside their windows
      (`Sanctum.Pairing.sign_in_may_confirm/2`): while the person recovers
      from a declared restore, or, before their first passkey or device,
      for that first one; a record of anything else for a person who never
      held one is marked `enroll`, and its client offers adding a passkey
      or a device first. A record that adds a device, a passkey or a door
      (`Sanctum.Pairing.addition?/1`), once a passkey or a paired device
      ever existed for the person, is marked `restricted` and offers only
      a `passkey`, `home` or `device`. To a
      protected device's channel, `pending` with a `request` also answers
      that record's `challenge`, the `confirm` challenge its `device_proof`
      signs (the record's ref and stored digest, expiring no later than the
      record), and offers `device` among its `methods`.
    * `cancel` ends one.

  While the home's storage reserve is depleted (`Arca.StorageReserve`),
  `pending` answers only the person's records of an action declared
  `reduces_authority`, so a client reconnecting then still finds a
  revocation waiting on it, and the gate admits a `request`, a proof, a
  re-authentication or a cancel only by a ref naming such a record: the
  freed reserve completes a revocation, not another change.

  While the person recovers from a declared restore (their
  `restore_people` row is open, `Arca.SecurityTransitions.restore_open/2`),
  a passkey proves nothing for them: `pending` marks each record `restore:
  true`, offers no `passkey` among its `methods` and no credential in its
  WebAuthn options, so a door this home re-authenticates or an emailed
  code is the proof, and `confirm` with an assertion is refused
  (`Sanctum.Pairing.restore_source_refusal/0`). Otherwise each record is
  `restore: false`. The mark is per record, beside `restricted`, though it
  is the person's state and so the same on every record of theirs.

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
  by the `ref` of the secret it holds.
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
            ref(),
            Arg.new("assertion", :json,
              description:
                "confirm: a WebAuthn assertion over the confirmation's digest, from a passkey registered here"
            ),
            Arg.new("code", :string,
              description: "confirm: the one-time code sent to your verified email for it"
            ),
            Arg.new("device_proof", :json,
              description:
                "confirm: a protected device's proof over the confirm challenge pending answered it"
            ),
            Arg.new("home_assertion", :json,
              description:
                "confirm: your own CYFR's certified assertion that you confirmed this change there"
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
            ref(),
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
        "Your pending confirmations of sensitive changes: confirm one with a passkey, a fresh sign-in, an emailed code, a protected device's unlock or your own CYFR's confirmation, list them with what each would change and which client asked, or cancel one.",
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

  def handle(%Context{} = ctx, %{"action" => "confirm", "ref" => ref} = args)
      when is_binary(ref) do
    case {args["assertion"], args["code"], args["device_proof"], args["home_assertion"]} do
      {assertion, nil, nil, nil} when is_map(assertion) ->
        with :ok <- passkey_may_prove(ctx), do: answered(Passkeys.assert(ctx, ref, assertion))

      {nil, code, nil, nil} when is_binary(code) and code != "" ->
        answered(EmailVerification.verify_code(ctx, ref, code))

      {nil, nil, proof, nil} when is_map(proof) ->
        answered(device_confirm(ctx, ref, proof))

      {nil, nil, nil, assertion} when is_map(assertion) ->
        answered(home_confirm(ctx, ref, assertion))

      _none_or_more ->
        {:error,
         {:invalid_argument,
          "Give exactly one proof: a passkey assertion, the emailed code, a device's proof or your CYFR's assertion"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "reauth", "ref" => ref, "method" => method})
      when is_binary(ref) do
    case method do
      "oidc" -> answered(OIDC.reauth_url(ctx, ref))
      "email" -> answered(EmailVerification.send_code(ctx, ref))
      _other -> {:error, {:invalid_argument, "The method is oidc or email"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "pending"} = args) do
    with {:ok, user_id} <- person(ctx),
         {:ok, rows} <- open(ctx, user_id),
         rows = requested(rows, args["request"]),
         {:ok, restore?} <- recovering(user_id),
         {:ok, credentials} <- credentials(ctx, user_id, restore?),
         {:ok, latched?} <- latched(user_id),
         {:ok, remote?} <- remote(user_id) do
      methods = methods(user_id, credentials) ++ if(remote?, do: ["home"], else: [])

      methods = if device?(ctx, args["request"]), do: methods ++ ["device"], else: methods

      with {:ok, confirmations} <-
             all_pending(rows, fn row ->
               with {:ok, record} <-
                      row
                      |> pending(
                        credentials,
                        offered(ctx, row, methods, latched?, restore?),
                        restore?
                      )
                      |> Map.put(:enroll, enroll?(row, latched?, restore?))
                      |> at_home(row, remote?),
                    do: device_challenge(ctx, row, args["request"], record)
             end),
           do: {:ok, %{confirmations: confirmations}}
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

  def handle(_ctx, %{"action" => action}) when action in ~w(confirm reauth cancel),
    do: {:error, {:invalid_argument, "Missing required argument: ref"}}

  def handle(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "confirmation.#{action}"}}

  def handle(_ctx, _args), do: {:error, :action_missing}

  # A protected device's proof over the `confirm` challenge it holds for
  # this record of its own person, then the record confirmed as the
  # device's, whose client and certificate the store reads again under
  # lock (`Arca.PendingConfirmations.confirm/3`).
  defp device_confirm(%Context{} = ctx, ref, proof) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx),
         {:ok, row} <- own(actor, ref, user_id),
         :ok <- Sanctum.DeviceUnlock.confirm_proof(ctx, row, proof) do
      case Arca.PendingConfirmations.confirm(actor, ref, %{
             proof: "device",
             client_id: ctx.client_id
           }) do
        {:ok, confirmed} ->
          Sanctum.Consent.Authz.announce(:confirmed, confirmed)
          {:ok, %{ref: confirmed.ref, state: confirmed.state, expires_at: confirmed.expires_at}}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, :not_owner} ->
          {:error, :unavailable}

        {:error, :not_found} ->
          {:error, {:not_found, "confirmation", ref}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A remote person's confirmation their own home certified, then the
  # record confirmed as `home`, attributed to nothing here.
  defp home_confirm(%Context{} = ctx, ref, assertion) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx),
         {:ok, row} <- own(actor, ref, user_id),
         :ok <-
           home_verified(Sanctum.RemoteCertification.verify_confirmation(ctx, row, assertion)) do
      case Arca.PendingConfirmations.confirm(actor, ref, %{proof: "home"}) do
        {:ok, confirmed} ->
          Sanctum.Consent.Authz.announce(:confirmed, confirmed)
          {:ok, %{ref: confirmed.ref, state: confirmed.state, expires_at: confirmed.expires_at}}

        {:error, :not_found} ->
          {:error, {:not_found, "confirmation", ref}}

        {:error, reason} when reason in [:database_error, :not_owner] ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp home_verified({:error, :proof_refused}), do: {:error, :home_refused}
  defp home_verified(verdict), do: verdict

  # A protected device's channel reading one record: the device offers its
  # own proof.
  defp device?(%Context{auth_method: :device}, request) when is_binary(request), do: true
  defp device?(%Context{}, _request), do: false

  defp all_pending(rows, fun) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case fun.(row) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The `confirm` challenge a protected device signs for the one record
  # its `pending` read names; none for any other read or client.
  defp device_challenge(%Context{auth_method: :device} = ctx, row, request, record)
       when is_binary(request) do
    case Sanctum.DeviceUnlock.confirm_challenge(ctx, row) do
      {:ok, nil} ->
        {:ok, %{record | methods: record.methods -- ["device"]}}

      {:ok, challenge} ->
        {:ok, Map.put(record, :challenge, Prima.DeviceCert.Challenge.encode(challenge))}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  defp device_challenge(_ctx, _row, _request, record), do: {:ok, record}

  defp answered({:ok, answer}), do: {:ok, answer}
  defp answered({:error, reason}), do: {:error, refusal(reason)}

  # A person, in an athanor, who could give a proof.
  defp person(%Context{} = ctx) do
    if Pairing.can_confirm?(ctx) and is_binary(ctx.athanor_id) and ctx.athanor_id != "",
      do: {:ok, ctx.user_id},
      else: {:error, :unauthenticated}
  end

  # Whether the person's keys are at another home: their identity row here
  # is `remote`, so their own home certifies their confirmations.
  defp remote(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "remote"}} -> {:ok, true}
      {:ok, _local} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # What a remote person's browser carries to their own home for one
  # record (`Prima.ConfirmationAssertion`): the bindings that home signs
  # over, and the preview it shows before it asks for its own proof.
  defp at_home(record, row, true = _remote?) do
    with {:ok, preview_digest} <- Sanctum.RemoteCertification.preview_digest(row) do
      {:ok,
       Map.put(record, :at_home, %{
         audience: Sanctum.Person.home(),
         athanor: row.athanor_id,
         ref: row.ref,
         digest: row.digest,
         expires_at: DateTime.to_unix(row.expires_at, :millisecond),
         preview: record.preview,
         preview_digest: preview_digest
       })}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp at_home(record, _row, false), do: {:ok, record}

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

  # Whether the person recovers from a declared restore: their restore row
  # is open, so no passkey proves anything for them.
  defp recovering(user_id) do
    case Arca.SecurityTransitions.restore_open(Prima.Actor.system(), user_id) do
      {:ok, nil} -> {:ok, false}
      {:ok, _restore_id} -> {:ok, true}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A passkey's assertion is taken only while the person is not recovering
  # from a declared restore. A context that names no person is left to the
  # assertion's own refusal.
  defp passkey_may_prove(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "" do
    case recovering(user_id) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, Pairing.restore_source_refusal()}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp passkey_may_prove(%Context{}), do: :ok

  # The person's active passkeys here, read as the context's own; none
  # while they recover from a declared restore.
  defp credentials(_ctx, _user_id, true = _restore?), do: {:ok, []}

  defp credentials(ctx, user_id, false = _restore?) do
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

  # The proofs this person can give here, the same for each of their
  # records: a passkey registered at this home, a fresh sign-in at their
  # linked door's identity provider, a code their verified email can
  # receive.
  defp methods(user_id, credentials) do
    [
      {"passkey", credentials != []},
      {"oidc", OIDC.reauth_available?(user_id)},
      {"email", EmailVerification.code_available?(user_id)}
    ]
    |> Enum.filter(fn {_method, available} -> available end)
    |> Enum.map(fn {method, _available} -> method end)
  end

  # Whether a passkey or a paired device ever existed for the person here:
  # the first-method latch, which nothing clears (`Arca.PersonIdentities`).
  # The row is minted with the person row, so a person without one is
  # damage; an id of another shape names no person and has latched nothing.
  defp latched(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{first_method_at: at}} ->
        {:ok, not is_nil(at)}

      {:error, :not_found} ->
        if Prima.PersonId.person?(user_id),
          do: {:error, {:corrupt, :person_identity}},
          else: {:ok, false}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The proofs a record offers, and whether they are restricted. A
  # sign-in method's re-authentication and an emailed code are offered only
  # inside their windows (`Sanctum.Pairing.sign_in_may_confirm/2`, which
  # their owners ask again): while the person recovers from a declared
  # restore, or, before their first passkey or device, for that first one.
  # An addition, once the latch is set, takes a passkey's, a protected
  # device's or the person's own home's proof (`Sanctum.Pairing`).
  defp offered(_ctx, row, methods, latched?, restore?) do
    methods =
      if sign_in_window?(row, latched?, restore?),
        do: methods,
        else: methods -- ["oidc", "email"]

    if latched? and Pairing.addition?(row.operation),
      do: {Enum.filter(methods, &(&1 in ["passkey", "home", "device"])), true},
      else: {methods, false}
  end

  defp sign_in_window?(_row, _latched?, true = _restore?), do: true
  defp sign_in_window?(row, false = _latched?, false), do: Pairing.first_method?(row.operation)
  defp sign_in_window?(_row, true, false), do: false

  # A person who never held a passkey or device, asked to confirm anything
  # but their first one, is offered that enrollment first: until then no
  # proof of theirs confirms it.
  defp enroll?(row, latched?, restore?),
    do: not latched? and not restore? and not Pairing.first_method?(row.operation)

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
  # would change, as the home stored it, which client asked, which proofs
  # the person can give and whether they are restricted, whether the person
  # recovers from a declared restore, and how a passkey proves it — the
  # challenge is the raw bytes of the record's digest.
  defp pending(row, credentials, {methods, restricted?}, restore?) do
    "sha256:" <> hex = row.digest

    %{
      ref: row.ref,
      operation: row.operation,
      action: row.action,
      preview: Jason.decode!(row.preview),
      asker: Jason.decode!(row.asker),
      state: row.state,
      expires_at: row.expires_at,
      methods: methods,
      restricted: restricted?,
      restore: restore?,
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

  defp refusal(:proof_refused),
    do:
      refused(
        :unauthenticated,
        :proof_refused,
        "This device's proof does not confirm this change: unlock and confirm again"
      )

  defp refusal(:home_refused),
    do:
      refused(
        :unauthenticated,
        :home_refused,
        "Your CYFR's answer does not confirm this change here: confirm it at your CYFR again"
      )

  defp refusal(:certification_ended),
    do:
      refused(
        :forbidden,
        :certification_ended,
        "Your keys changed at your CYFR since this device was certified: certify it there again"
      )

  defp refusal(:not_remote),
    do:
      refused(
        :forbidden,
        :not_remote,
        "Your keys are held here: confirm with your passkey or on one of your devices"
      )

  defp refusal(:no_holder),
    do:
      refused(
        :forbidden,
        :no_holder,
        "This device keeps no protected key, so it cannot confirm with its own proof"
      )

  defp refusal(:not_a_device),
    do:
      refused(
        :forbidden,
        :not_a_device,
        "Only a protected device's own screen confirms with a device proof"
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
