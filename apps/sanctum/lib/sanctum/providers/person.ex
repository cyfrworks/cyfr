# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Person do
  @moduledoc """
  The `person` tool: a person's identity at their own home — the recovery
  code their admission enrolled them with, another recovery code added by
  one the person holds, the live key's rotation, the doors they sign in through, a device
  certificate for another home, and the sign-in carry that begins and
  completes here. The carry stores no saved-home list.

  Every action but one is on the external plane, through an interactive
  session (`consent: :interactive`): a person's own, or, for
  `person.close_recovery`, the platform administrator's (`scope:
  :platform`). The exception is
  `person.renew_certificate`, `auth: :anonymous` as `pairing.complete` is:
  a device at another home renews here holding no session of this home's,
  and the proof of its device key over this home's challenge is its only
  credential (`Sanctum.RemoteCertification`). Showing the recovery code
  and adding one touch recovery material; rotating changes
  the live key; linking and unlinking change the sign-in methods;
  certifying a device pairs it: each is a sensitive change Sanctum decides
  where it is made (`Sanctum.Pairing`). `person.assert` is declared with
  the tool by `Sanctum.Providers.Assertion`, which handles it.

  A recovery secret the trusted form draws is the field `recovery_secret`
  wherever it appears, the added code's `holder` included; a recovery code
  given is `recovery_code` and one answered is `code`. The redaction
  vocabulary (`Prima.Sanitizer`) keeps each out of every log.

  What each action answers:

    * `person.status` (`Sanctum.Recovery.status/1`) — the person's identity
      as their settings show it: `provenance`, `identifier`, their recorded
      `name`, the `directory_url` this home pins (or nil), `enrollment`,
      `key_epoch`, the `kits` and `rotation` still in progress, and the
      linked `doors`; never a secret, a sealed value or a staged key.
    * `person.recovery_code` (`Sanctum.Recovery.recovery_code/2`) — the
      attempt's `attempt_id` and its recovery `code`, the one a restore
      takes, under a fresh confirmation, until
      `person.recovery_code_saved` erases its secret.
    * `person.recovery_code_saved` (`Sanctum.Recovery.recovery_code_saved/2`)
      — `attempt_id` and `phase: "completed"`; an enrollment's only once
      the person's name is recorded.
    * `person.recovery_code_add` (`Sanctum.Recovery.recovery_code_add/3`) —
      the added code's attempt (`attempt_id`, `request_id`, `phase`,
      `identifier`), its `code` until it is saved, and the new
      `key_epoch`. A recovery code the person holds signs it.
    * `person.rotate` (`Sanctum.IdentityFreshness.rotate_live/3`) — the
      attempt's `request_id`, its `phase` and the new `key_epoch`.
    * `person.link_door` and `person.unlink_door`
      (`Sanctum.SignIn.link_door/3`, `unlink_door/2`) — the door linked or
      unlinked, by its key, provider, issuer and subject.
    * `person.carry_begin` and `person.carry_complete`
      (`Sanctum.Carry.begin/2`, `complete/3`) — the pending carry, its
      envelope, payload and fragment; then its recorded outcome and the
      destination this home's row names.
    * `person.carry_list` (`Sanctum.Carry.pending/1`) — `%{actions: [...]}`,
      the person's unexpired pending carries, each its `action_id`,
      `destination`, `phase`, `expires_at`, `began_at` and `key_epoch`;
      never a challenge, assertion, envelope or payload.
    * `person.carry_cancel` (`Sanctum.Carry.cancel/2`) — the carry's
      `action_id` and `phase: "cancelled"`.
    * `person.certify` (`Sanctum.RemoteCertification.certify/2`) —
      `%{certificate: _}`, a device certificate with an identity subject
      for another home, after the `device_pairing` confirmation, recorded
      as a certification here; this home pairs its own devices through
      `pairing`.
    * `person.close_recovery` (`Sanctum.Recovery.close_recovery/2`) — the
      platform administrator's end of a person's recovery from a declared
      restore (`scope: :platform`, under the administrator's fresh
      confirmation): `%{user_id, closed_restore_ids}`. What the restore
      suspended stays suspended.
    * `person.renew_certificate` (`Sanctum.RemoteCertification.renew/2`) —
      `%{challenge: _}` for a certificate this home issued, then
      `%{certificate: _}`, its replacement, for the device key's proof
      over that challenge, while the certification stands.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.{Carry, Context, IdentityFreshness, Recovery, RemoteCertification, SignIn}
  alias Sanctum.Providers.Assertion

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      operations() ++ Assertion.operations(),
      description:
        "A person's identity at their own CYFR: read its status, show the recovery code and say it is saved, add another recovery code, rotate the live key, link or unlink a sign-in method, certify a device for another CYFR and renew that certificate, and begin, list, cancel or complete a sign-in carry to another CYFR.",
      title: "Person"
    )
  end

  defp operations do
    [
      Operation.new("person", "status", "Read the person's identity", [],
        kind: :read,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new("person", "rotate", "Rotate the live key", [request_id()],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new("person", "recovery_code", "Show your recovery code", [attempt_id()],
        kind: :read,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "recovery_code_saved",
        "Say your recovery code is saved",
        [attempt_id()],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "link_door",
        "Link a sign-in method",
        [
          Arg.new("provider", :string,
            required: true,
            description: "link_door: the sign-in method to link, as its provider name"
          ),
          Arg.new("ticket", :string,
            required: true,
            description:
              "link_door: the single-use ticket a completed sign-in with that sign-in method answered, proving control of its subject"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "unlink_door",
        "Unlink a sign-in method",
        [
          Arg.new("door", :string,
            required: true,
            description:
              "unlink_door: the linked sign-in method's identity key (provider|issuer|subject)"
          )
        ],
        reduces_authority: true,
        kind: :destructive,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "recovery_code_add",
        "Add another recovery code",
        [
          Arg.new("recovery_code", :string,
            required: true,
            description: "recovery_code_add: a recovery code you hold, which signs the change"
          ),
          Arg.new(
            "holder",
            {:record, [recovery_secret("The new code's secret, drawn by the trusted form")]},
            required: true,
            description: "recovery_code_add: the new code's secret"
          ),
          request_id()
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "carry_begin",
        "Begin a sign-in carry to another CYFR",
        [
          Arg.new("destination", :string,
            required: true,
            description: "carry_begin: the CYFR to sign in at, as its origin"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "carry_complete",
        "Record a sign-in carry's outcome",
        [
          carry_action_id(),
          Arg.new("outcome", :string,
            required: true,
            enum: ["admitted", "refused"],
            description: "carry_complete: the navigation outcome the destination returned"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "carry_cancel",
        "Cancel a pending sign-in carry",
        [carry_action_id()],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new("person", "carry_list", "List the pending sign-in carries", [],
        kind: :read,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "certify",
        "Certify a device for another CYFR",
        [
          Arg.new("device_key", :string,
            required: true,
            description: "certify: the device's public key, unpadded base64url"
          ),
          Arg.new("audience", :string,
            required: true,
            description:
              "The other CYFR, as its origin: the assertion's audience, or the CYFR a certificate is presented to"
          ),
          Arg.new("athanor", :string,
            required: true,
            description: "certify: the athanor at that CYFR the device joins"
          ),
          Arg.new("client_id", :string,
            required: true,
            description: "certify: the paired-client id that CYFR reserved for the device (pcl_…)"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "close_recovery",
        "End a person's recovery from a declared restore",
        [
          Arg.new("user_id", :string,
            required: true,
            description:
              "close_recovery: the person whose recovery from the restore ends; what it suspended stays suspended"
          )
        ],
        scope: :platform,
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "renew_certificate",
        "Renew a device certificate this CYFR issued for another CYFR",
        [
          Arg.new("certificate", :json,
            required: true,
            description:
              "renew_certificate: a certificate this CYFR issued for the device, which only locates its certification"
          ),
          Arg.new("proof", :json,
            description:
              "renew_certificate: the device key's signature over the renew challenge; absent, the answer is the challenge to sign"
          )
        ],
        auth: :anonymous,
        kind: :write,
        planes: [:external]
      )
    ]
  end

  # The same argument as `person.assert`'s, in the same words: one tool,
  # one schema for a name.
  defp carry_action_id,
    do:
      Arg.new("action_id", :string,
        required: true,
        description: "The pending sign-in carry, by its action id"
      )

  defp recovery_secret(description),
    do:
      Arg.new("recovery_secret", :string,
        required: true,
        description: description <> " (32 bytes, unpadded base64url)"
      )

  defp request_id,
    do:
      Arg.new("request_id", :string,
        required: true,
        description:
          "The attempt's request id: a retry under the same id resumes the same attempt (rotate, recovery_code_add)"
      )

  defp attempt_id,
    do:
      Arg.new("attempt_id", :string,
        required: true,
        description:
          "The enrollment or added-code attempt whose code this is (recovery_code, recovery_code_saved)"
      )

  def handle(%Context{} = ctx, %{"action" => "assert"} = args), do: Assertion.handle(ctx, args)

  def handle(%Context{} = ctx, %{"action" => "status"}), do: answer(Recovery.status(ctx))

  def handle(%Context{} = ctx, %{"action" => "recovery_code", "attempt_id" => id})
      when is_binary(id),
      do: answer(Recovery.recovery_code(ctx, id))

  def handle(%Context{} = ctx, %{"action" => "recovery_code_saved", "attempt_id" => id})
      when is_binary(id),
      do: answer(Recovery.recovery_code_saved(ctx, id))

  def handle(%Context{}, %{"action" => action})
      when action in ["recovery_code", "recovery_code_saved"],
      do: {:error, {:invalid_argument, "#{action} needs the code's attempt_id"}}

  def handle(%Context{} = ctx, %{"action" => "recovery_code_add"} = args),
    do: answer(Recovery.recovery_code_add(ctx, args))

  def handle(%Context{} = ctx, %{"action" => "link_door", "provider" => provider, "ticket" => t})
      when is_binary(provider) and is_binary(t),
      do: answer(SignIn.link_door(ctx, provider, t))

  def handle(%Context{}, %{"action" => "link_door"}),
    do:
      {:error,
       {:invalid_argument, "link_door needs the sign-in method's provider and its ticket"}}

  def handle(%Context{} = ctx, %{"action" => "unlink_door", "door" => door}) when is_binary(door),
    do: answer(SignIn.unlink_door(ctx, door))

  def handle(%Context{}, %{"action" => "unlink_door"}),
    do: {:error, {:invalid_argument, "unlink_door needs the sign-in method's identity key"}}

  def handle(%Context{} = ctx, %{"action" => "carry_begin", "destination" => destination})
      when is_binary(destination),
      do: answer(Carry.begin(ctx, destination))

  def handle(%Context{}, %{"action" => "carry_begin"}),
    do: {:error, {:invalid_argument, "carry_begin needs the destination CYFR"}}

  def handle(
        %Context{} = ctx,
        %{"action" => "carry_complete", "action_id" => action_id, "outcome" => outcome}
      )
      when is_binary(action_id) and is_binary(outcome),
      do: answer(Carry.complete(ctx, action_id, outcome))

  def handle(%Context{}, %{"action" => "carry_complete"}),
    do: {:error, {:invalid_argument, "carry_complete needs the action_id and its outcome"}}

  def handle(%Context{} = ctx, %{"action" => "carry_list"}) do
    case Carry.pending(ctx) do
      {:ok, actions} -> {:ok, %{actions: actions}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "carry_cancel", "action_id" => action_id})
      when is_binary(action_id),
      do: answer(Carry.cancel(ctx, action_id))

  def handle(%Context{}, %{"action" => "carry_cancel"}),
    do: {:error, {:invalid_argument, "carry_cancel needs the action_id"}}

  def handle(%Context{} = ctx, %{"action" => "close_recovery"} = args),
    do: answer(Recovery.close_recovery(ctx, Map.get(args, "user_id")))

  def handle(%Context{} = ctx, %{"action" => "certify"} = args),
    do: answer(RemoteCertification.certify(ctx, args))

  def handle(%Context{} = ctx, %{"action" => "renew_certificate"} = args),
    do: renewal(RemoteCertification.renew(ctx, Map.take(args, ["certificate", "proof"])))

  # The live key's rotation (`Sanctum.IdentityFreshness.rotate_live/3`):
  # the `key_rotation` confirmation, one durable attempt per request id,
  # and a retry under the same id resuming it.
  def handle(%Context{} = ctx, %{"action" => "rotate", "request_id" => request_id})
      when is_binary(request_id) do
    case IdentityFreshness.rotate_live(ctx, request_id) do
      {:ok, rotation} ->
        {:ok,
         %{request_id: rotation.request_id, phase: rotation.phase, key_epoch: rotation.key_epoch}}

      {:error, reason} ->
        {:error, rotation_refusal(reason)}
    end
  end

  def handle(%Context{}, %{"action" => "rotate"}),
    do: {:error, {:invalid_argument, "rotate needs the attempt's request_id"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "person.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  # ---- answers -----------------------------------------------------------------

  # Each action's own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`), each with the sentence its person reads; the
  # vocabulary's own reasons (a confirmation signal, a standing refusal, a
  # rate limit) pass as they are.
  defp answer({:ok, value}), do: {:ok, value}
  defp answer({:error, reason}), do: {:error, refusal(reason)}

  defp refusal(:not_a_code),
    do:
      refused(
        :invalid_argument,
        :not_a_code,
        "That is not a recovery code. A recovery code starts with CYFR-."
      )

  defp refusal(:typo),
    do:
      refused(
        :invalid_argument,
        :typo,
        "That recovery code has a typo. Check it against the one you saved."
      )

  defp refusal(:not_enrolled),
    do: {:conflict, "This needs an enrolled identity; enroll first."}

  defp refusal(:not_found),
    do: {:conflict, "Your keys are held at another CYFR; do this there."}

  defp refusal(:holder_refused),
    do: {:conflict, "cyfr.run refused this recovery code, so none was added."}

  defp refusal(:kit_acknowledged),
    do: {:conflict, "You said your recovery code is saved, so it is gone and cannot be shown."}

  defp refusal(:not_accepted),
    do: {:conflict, "The directory has not accepted this yet; finish it under its request id."}

  defp refusal(:not_a_holder),
    do:
      refused(
        :forbidden,
        :not_a_holder,
        "The recovery code that signs this is not one of your identity's codes now."
      )

  defp refusal(:already_a_holder),
    do: {:conflict, "That is already one of your identity's recovery codes."}

  defp refusal(:stale_head),
    do:
      {:conflict,
       "Your identity's log has moved past this CYFR's head, so nothing changed. A recovery " <>
         "may have replaced your keys."}

  defp refusal({:attempt_in_progress, request_id}) when is_binary(request_id),
    do:
      {:conflict,
       "Another change of your identity is in progress; finish it under its request id " <>
         request_id <> "."}

  defp refusal({:attempt_in_progress, _unknown}),
    do: {:conflict, "Another change of your identity is in progress; finish it first."}

  defp refusal(:request_id_reused),
    do: {:conflict, "This request id names another request; use a new one."}

  defp refusal(:directory_unavailable), do: {:unavailable, "Your identity's directory"}

  defp refusal(:wrong_audience),
    do: {:invalid_argument, "A certificate for this CYFR is a pairing's"}

  defp refusal(:stale_key_epoch),
    do:
      {:conflict,
       "Your identity's keys changed while this was confirmed, so nothing was certified; " <>
         "certify again."}

  defp refusal(:unauthenticated),
    do: refused(:unauthenticated, :unauthenticated, "Sign in to change your identity.")

  defp refusal(:guest_plane),
    do:
      refused(:forbidden, :guest_plane, "A running component cannot change a person's identity.")

  defp refusal({:door, _reason}),
    do: refused(:forbidden, :door, Sanctum.Door.refusal_message())

  defp refusal({:invalid, _errors}),
    do: {:invalid_argument, "The change could not be recorded as given"}

  defp refusal({:invalid_field, field}) when is_binary(field),
    do: {:invalid_argument, "The #{field} is not valid"}

  defp refusal(reason), do: reason

  # A renewal's own refusals: the glass reads the class, and is certified
  # again at its person's home for the ones that end a certification.
  defp renewal({:ok, value}), do: {:ok, value}
  defp renewal({:error, reason}), do: {:error, renewal_refusal(reason)}

  defp renewal_refusal(:not_found),
    do:
      refused(
        :not_found,
        :not_found,
        "This CYFR holds no certification of that device; certify it again at your CYFR."
      )

  defp renewal_refusal(:certification_ended),
    do:
      refused(
        :conflict,
        :certification_ended,
        "Your keys changed since this device was certified; certify it again at your CYFR."
      )

  defp renewal_refusal(:binding_changed),
    do:
      refused(
        :conflict,
        :binding_changed,
        "This device was certified again since, for another key or athanor; certify it again."
      )

  defp renewal_refusal(:revoked),
    do: refused(:conflict, :revoked, "This device's certification was withdrawn.")

  defp renewal_refusal(:not_standing),
    do: refused(:forbidden, :not_standing, "The person behind this device cannot sign here now.")

  defp renewal_refusal(reason) when reason in [:proof_refused, :replayed],
    do: refused(:unauthenticated, reason, "The device's proof of its key was refused.")

  # The verification bounds answer their retry in milliseconds; the
  # refusal reads whole seconds, rounded up, as the pairing provider's
  # does.
  defp renewal_refusal({:rate_limited, retry_after_ms}) when is_integer(retry_after_ms),
    do: {:rate_limited, div(retry_after_ms + 999, 1_000)}

  defp renewal_refusal(reason), do: refusal(reason)

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}

  # A rotation's own refusals, in the refusal table's words. Nothing
  # rotated in any of them; the retryable ones resume under the same
  # request id.
  defp rotation_refusal(:invalid_request),
    do: {:invalid_argument, "The request_id is not a valid request id"}

  defp rotation_refusal(:not_found),
    do: {:conflict, "Your keys are held at another CYFR; rotate them there."}

  defp rotation_refusal(:not_enrolled),
    do: {:conflict, "Rotating the live key needs an enrolled identity; enroll first."}

  defp rotation_refusal(:stale_head),
    do:
      {:conflict,
       "Your identity's log has moved past this CYFR's head, so nothing was rotated. A " <>
         "recovery or another rotation may have replaced your keys."}

  defp rotation_refusal(:superseded),
    do:
      {:conflict,
       "A recovery or another rotation replaced this rotation before it took effect, so " <>
         "nothing was rotated here."}

  defp rotation_refusal(:rotation_refused),
    do: {:conflict, "Your identity's directory refused this rotation; nothing was rotated."}

  defp rotation_refusal({:attempt_in_progress, request_id}) when is_binary(request_id),
    do:
      {:conflict,
       "Another rotation of your live key is in progress; finish it under its request id " <>
         request_id <> "."}

  defp rotation_refusal({:attempt_in_progress, _unknown}),
    do: {:conflict, "Another rotation of your live key is in progress; finish it first."}

  defp rotation_refusal(:request_id_reused),
    do: {:conflict, "This request id names another request; use a new one."}

  defp rotation_refusal(:directory_unavailable), do: {:unavailable, "Your identity's directory"}
  defp rotation_refusal(reason), do: reason
end
