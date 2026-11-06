# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Passkey do
  @moduledoc """
  The `passkey` tool: the passkeys of a person's account that signed in
  at this CYFR (`Sanctum.Passkeys`). This CYFR registers no passkey: a
  passkey is added to the account, and removed from it, at the account
  pages.

    * `list` answers the person's passkeys that signed in here and stand,
      each its `kid`, its paired client (`client_id`) and when it first
      signed in here (`signed_in_at`).
    * `revoke` signs one passkey out of this CYFR, by its `kid`: its
      client is revoked with every session it signed for, and it answers
      how many sessions ended. It takes authority away and asks no
      confirmation.

  Every action is the person's own, on the external plane, through an
  interactive surface (`consent: :interactive`).
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.{Context, Passkeys}

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new("passkey", "list", "List the passkeys that signed in here", [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "passkey",
          "revoke",
          "Sign a passkey out of this CYFR",
          [
            Arg.new("kid", :string,
              required: true,
              description: "revoke: the passkey, by the kid of its key in your account"
            )
          ],
          reduces_authority: true,
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "The passkeys of your account that signed in at this CYFR: list them, or sign one out here.",
      title: "Passkeys"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Passkeys.list(ctx) do
      {:ok, passkeys} -> {:ok, %{passkeys: passkeys}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "kid" => kid}) when is_binary(kid) do
    case Passkeys.revoke(ctx, kid) do
      {:ok, revoked} -> {:ok, revoked}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}),
    do: {:error, {:invalid_argument, "Missing required argument: kid"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "passkey.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  # The passkeys' own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`); the vocabulary's own reasons pass as they
  # are.
  defp refusal(:unauthenticated),
    do: %Prima.Refusal{
      class: :unauthenticated,
      reason: :unauthenticated,
      message: "Only a person signed in here sees their passkeys"
    }

  defp refusal(reason), do: reason
end
