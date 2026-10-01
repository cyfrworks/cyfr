# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Person do
  @moduledoc """
  The `person` tool: a person's identity at their own home — enrollment
  and the printed recovery kit, another kit added by an existing one, the
  live key's rotation, the doors they sign in through, a device
  certificate for another home, and the sign-in carry that begins and
  completes here. The carry stores no saved-home list.

  Every action is a person's, on the external plane, through an
  interactive session (`consent: :interactive`). Enrolling, the kit and
  adding a kit change recovery material; rotating changes the live key;
  linking and unlinking change the sign-in methods; certifying a device
  pairs it: each is a sensitive change Sanctum decides where it is made
  (`Sanctum.Pairing`). `person.assert` is declared with the tool by
  `Sanctum.Providers.Assertion`, which handles it.

  A recovery seed, in or out, is the field `recovery_secret` wherever it
  appears, nested kit structures included, so the redaction vocabulary
  (`Prima.Sanitizer`) keeps it out of every log.

  `person.rotate` rotates an enrolled local person's live key
  (`Sanctum.IdentityFreshness.rotate_live/3`) under the `key_rotation`
  confirmation, through one durable attempt per `request_id`: a retry
  under the same id resumes it and generates no second key. It answers
  the attempt's `request_id`, its `phase` and the new `key_epoch`. Every
  other action answers `{:error, :not_built}`: none is built yet.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Context
  alias Sanctum.IdentityFreshness
  alias Sanctum.Providers.Assertion

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      operations() ++ Assertion.operations(),
      description:
        "A person's identity at their own home: enroll and print the recovery kit, add another kit, rotate the live key, link or unlink a sign-in door, certify a device for another home, and begin or complete a sign-in carry to another home.",
      title: "Person"
    )
  end

  defp operations do
    [
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
          Arg.new("action_id", :string,
            required: true,
            description: "The pending sign-in carry, by its action id"
          ),
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
      )
    ]
  end

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

  @actions ~w(enroll kit kit_ack link_door unlink_door enroll_holder carry_begin
              carry_complete certify)

  def handle(%Context{} = ctx, %{"action" => "assert"} = args), do: Assertion.handle(ctx, args)

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

  def handle(%Context{}, %{"action" => action}) when action in @actions, do: {:error, :not_built}
  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "person.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

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
