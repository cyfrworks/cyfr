# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Person do
  @moduledoc """
  The `person` tool: a person's identity at their own home — enrollment
  and the printed recovery kit, another kit added by an existing one, the
  live key's rotation, the doors they sign in through, a device
  certificate for another home, and the sign-in carry that begins and
  completes here. The carry stores no saved-home list.

  Every action but one is a person's, on the external plane, through an
  interactive session (`consent: :interactive`). The exception is
  `person.renew_certificate`, `auth: :anonymous` as `pairing.complete` is:
  a device at another home renews here holding no session of this home's,
  and the proof of its device key over this home's challenge is its only
  credential (`Sanctum.RemoteCertification`). Enrolling, the kit and
  adding a kit change recovery material; rotating changes the live key;
  linking and unlinking change the sign-in methods; certifying a device
  pairs it: each is a sensitive change Sanctum decides where it is made
  (`Sanctum.Pairing`). `person.assert` is declared with the tool by
  `Sanctum.Providers.Assertion`, which handles it.

  A recovery seed, in or out, is the field `recovery_secret` wherever it
  appears, nested kit structures included, so the redaction vocabulary
  (`Prima.Sanitizer`) keeps it out of every log.

  What each action answers:

    * `person.status` (`Sanctum.Recovery.status/1`) — the person's identity
      as their settings show it: `provenance`, `identifier`, the
      `directory_url` this home pins (or nil), `enrollment`, `key_epoch`,
      the `kits` and `rotation` still in progress, and the linked `doors`;
      never a seed, a sealed value or a staged key.
    * `person.enroll` (`Sanctum.Recovery.enroll/3`) — the attempt's
      `attempt_id`, `request_id`, `phase` and `identifier`, and once the
      directory accepted it the `kit`, `%{identifier, directory_url,
      recovery_secret}`, the three lines a restore takes, until the kit is
      acknowledged. A retry under the same `request_id` resumes the
      attempt and registers the same genesis.
    * `person.enroll_abandon` (`Sanctum.Recovery.abandon_enrollment/1`) —
      the abandoned enrollment's `request_id` and `phase: "superseded"`:
      an enrollment the directory has not accepted ends, and the person
      may enroll again under a new kit. It asks no confirmation: it
      discards an unfinished attempt and mints nothing.
    * `person.kit` (`Sanctum.Recovery.kit/2`) — the same `kit` again, under
      a fresh confirmation, until `person.kit_ack` erases its seed.
    * `person.kit_ack` (`Sanctum.Recovery.kit_ack/2`) — `attempt_id` and
      `phase: "completed"`.
    * `person.enroll_holder` (`Sanctum.Recovery.enroll_holder/3`) — as
      enroll, the `kit` being the added one's, and the new `key_epoch`.
    * `person.rotate` (`Sanctum.IdentityFreshness.rotate_live/3`) — the
      attempt's `request_id`, its `phase` and the new `key_epoch`.
    * `person.link_door` and `person.unlink_door`
      (`Sanctum.SignIn.link_door/3`, `unlink_door/2`) — the door linked or
      unlinked, by its key, provider, issuer and subject.
    * `person.carry_begin` and `person.carry_complete`
      (`Sanctum.Carry.begin/3`, `complete/3`) — the pending carry, its
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
        "A person's identity at their own home: read its status, enroll and print the recovery kit, abandon an unfinished enrollment, add another kit, rotate the live key, link or unlink a sign-in door, certify a device for another home and renew that certificate, and begin, list, cancel or complete a sign-in carry to another home.",
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
      Operation.new(
        "person",
        "enroll",
        "Enroll the person's identity",
        [
          recovery_secret("enroll: the new kit's recovery seed, drawn by the trusted form"),
          request_id()
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "enroll_abandon",
        "Abandon an unfinished enrollment",
        [],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new("person", "rotate", "Rotate the live key", [request_id()],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new("person", "kit", "Deliver a printed kit", [attempt_id()],
        kind: :read,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "kit_ack",
        "Acknowledge a printed kit is saved",
        [attempt_id()],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "link_door",
        "Link a sign-in door",
        [
          Arg.new("provider", :string,
            required: true,
            description: "link_door: the door to link, as its provider name"
          ),
          Arg.new("ticket", :string,
            required: true,
            description:
              "link_door: the single-use ticket a completed sign-in with that door answered, proving control of its subject"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "unlink_door",
        "Unlink a sign-in door",
        [
          Arg.new("door", :string,
            required: true,
            description: "unlink_door: the linked door's identity key (provider|issuer|subject)"
          )
        ],
        kind: :destructive,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "enroll_holder",
        "Add another printed kit",
        [
          recovery_secret(
            "enroll_holder: an existing kit's recovery seed, which signs the change"
          ),
          Arg.new(
            "holder",
            {:record,
             [
               Arg.new("kind", :string,
                 required: true,
                 enum: ["kit"],
                 description: "The kind of recovery holder added; a printed kit is the one kind"
               ),
               recovery_secret("The added kit's recovery seed, drawn by the trusted form")
             ]},
            required: true,
            description: "enroll_holder: the recovery holder to add"
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
        "Begin a sign-in carry to another home",
        [
          Arg.new("destination", :string,
            required: true,
            description: "carry_begin: the home to sign in at, as its origin"
          ),
          Arg.new("operation", :string,
            enum: ["join"],
            description: "carry_begin: what the carry is for; join is the one operation"
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
        "Certify a device for another home",
        [
          Arg.new("device_key", :string,
            required: true,
            description: "certify: the device's public key, unpadded base64url"
          ),
          Arg.new("audience", :string,
            required: true,
            description:
              "The other home, as its origin: the assertion's audience, or the home a certificate is presented to"
          ),
          Arg.new("athanor", :string,
            required: true,
            description: "certify: the athanor at that home the device joins"
          ),
          Arg.new("client_id", :string,
            required: true,
            description: "certify: the paired-client id that home reserved for the device (pcl_…)"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      ),
      Operation.new(
        "person",
        "renew_certificate",
        "Renew a device certificate this home issued for another home",
        [
          Arg.new("certificate", :json,
            required: true,
            description:
              "renew_certificate: a certificate this home issued for the device, which only locates its certification"
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
          "The attempt's request id: a retry under the same id resumes the same attempt (enroll, rotate, enroll_holder)"
      )

  defp attempt_id,
    do:
      Arg.new("attempt_id", :string,
        required: true,
        description: "The enrollment or added-kit attempt whose kit this is (kit, kit_ack)"
      )

  def handle(%Context{} = ctx, %{"action" => "assert"} = args), do: Assertion.handle(ctx, args)

  def handle(%Context{} = ctx, %{"action" => "status"}), do: answer(Recovery.status(ctx))

  def handle(%Context{} = ctx, %{"action" => "enroll"} = args),
    do: answer(Recovery.enroll(ctx, args))

  def handle(%Context{} = ctx, %{"action" => "enroll_abandon"}) do
    case Recovery.abandon_enrollment(ctx) do
      {:ok, abandoned} -> {:ok, abandoned}
      {:error, reason} -> {:error, abandon_refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "kit", "attempt_id" => id}) when is_binary(id),
    do: answer(Recovery.kit(ctx, id))

  def handle(%Context{} = ctx, %{"action" => "kit_ack", "attempt_id" => id}) when is_binary(id),
    do: answer(Recovery.kit_ack(ctx, id))

  def handle(%Context{}, %{"action" => action}) when action in ["kit", "kit_ack"],
    do: {:error, {:invalid_argument, "#{action} needs the kit's attempt_id"}}

  def handle(%Context{} = ctx, %{"action" => "enroll_holder"} = args),
    do: answer(Recovery.enroll_holder(ctx, args))

  def handle(%Context{} = ctx, %{"action" => "link_door", "provider" => provider, "ticket" => t})
      when is_binary(provider) and is_binary(t),
      do: answer(SignIn.link_door(ctx, provider, t))

  def handle(%Context{}, %{"action" => "link_door"}),
    do: {:error, {:invalid_argument, "link_door needs the door's provider and its ticket"}}

  def handle(%Context{} = ctx, %{"action" => "unlink_door", "door" => door}) when is_binary(door),
    do: answer(SignIn.unlink_door(ctx, door))

  def handle(%Context{}, %{"action" => "unlink_door"}),
    do: {:error, {:invalid_argument, "unlink_door needs the door's identity key"}}

  def handle(%Context{} = ctx, %{"action" => "carry_begin", "destination" => destination} = args)
      when is_binary(destination),
      do: answer(Carry.begin(ctx, destination, Map.get(args, "operation")))

  def handle(%Context{}, %{"action" => "carry_begin"}),
    do: {:error, {:invalid_argument, "carry_begin needs the destination home"}}

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

  defp refusal(:no_directory),
    do:
      refused(
        :setup_required,
        :no_directory,
        "This home names no identity directory; its operator sets CYFR_DIRECTORY_URL before " <>
          "anyone enrolls."
      )

  defp refusal(:already_enrolled),
    do: {:conflict, "Your identity is enrolled already; add another kit instead."}

  defp refusal(:not_enrolled),
    do: {:conflict, "This needs an enrolled identity; enroll first."}

  defp refusal(:not_found),
    do: {:conflict, "Your keys are held at another home; do this there."}

  defp refusal(:enrollment_refused),
    do: {:conflict, "The directory refused this identity, so you have none yet; enroll again."}

  defp refusal(:enrollment_abandoned),
    do:
      {:conflict,
       "This enrollment was abandoned, so it gives you no identity; enroll again with a new kit."}

  defp refusal(:holder_refused),
    do: {:conflict, "The directory refused this kit, so none was added."}

  defp refusal(:kit_acknowledged),
    do: {:conflict, "You acknowledged saving this kit, so its seed is gone and cannot be shown."}

  defp refusal(:not_accepted),
    do: {:conflict, "The directory has not accepted this yet; finish it under its request id."}

  defp refusal(:not_a_holder),
    do:
      refused(
        :forbidden,
        :not_a_holder,
        "The kit that signs this is not one of your identity's recovery kits now."
      )

  defp refusal(:already_a_holder),
    do: {:conflict, "That kit is already one of your identity's recovery kits."}

  defp refusal(:stale_head),
    do:
      {:conflict,
       "Your identity's log has moved past this home's head, so nothing changed. A recovery " <>
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
    do: {:invalid_argument, "A certificate for this home is a pairing's"}

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
        "This home holds no certification of that device; certify it again at your home."
      )

  defp renewal_refusal(:certification_ended),
    do:
      refused(
        :conflict,
        :certification_ended,
        "Your keys changed since this device was certified; certify it again at your home."
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

  # An abandonment's own refusals: the accepted enrollment stands, and
  # with none in progress there is nothing to abandon.
  defp abandon_refusal(:registered),
    do: {:conflict, "Your identity is registered; show its kit with person.kit."}

  defp abandon_refusal(:not_found),
    do: refused(:not_found, :not_found, "You have no unfinished enrollment to abandon.")

  defp abandon_refusal(reason), do: refusal(reason)

  # A rotation's own refusals, in the refusal table's words. Nothing
  # rotated in any of them; the retryable ones resume under the same
  # request id.
  defp rotation_refusal(:invalid_request),
    do: {:invalid_argument, "The request_id is not a valid request id"}

  defp rotation_refusal(:not_found),
    do: {:conflict, "Your keys are held at another home; rotate them there."}

  defp rotation_refusal(:not_enrolled),
    do: {:conflict, "Rotating the live key needs an enrolled identity; enroll first."}

  defp rotation_refusal(:stale_head),
    do:
      {:conflict,
       "Your identity's log has moved past this home's head, so nothing was rotated. A " <>
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
