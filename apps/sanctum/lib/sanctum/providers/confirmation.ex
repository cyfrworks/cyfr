# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Confirmation do
  @moduledoc """
  The `confirmation` tool: a person's pending confirmations of sensitive
  changes. `confirm` proves one with a passkey assertion over its digest,
  an emailed one-time code or the ticket of a completed OpenID Connect
  re-authentication; `reauth` begins that re-authentication, or sends the
  code; `pending` answers the person's open confirmations with the
  previews the home stored, so another of their devices shows the home's
  record rather than the asking client's; `cancel` ends one. A
  confirmation is never a permission for a similar change.

  Every action is the person's own, on the external plane, through an
  interactive surface (`consent: :interactive`).

  Every action answers `{:error, :not_built}`: none is built yet.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

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
            ),
            Arg.new("ticket", :string,
              description:
                "confirm: the single-use ticket a completed OpenID Connect re-authentication for it answered"
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

  @actions ~w(confirm reauth pending cancel)

  def handle(%Context{}, %{"action" => action}) when action in @actions, do: {:error, :not_built}

  def handle(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "confirmation.#{action}"}}

  def handle(_ctx, _args), do: {:error, :action_missing}
end
