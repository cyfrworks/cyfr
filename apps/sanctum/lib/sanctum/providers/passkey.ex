# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Passkey do
  @moduledoc """
  The `passkey` tool: a person's passkeys at this relying home —
  register one, list them, revoke one, and the platform administrator's
  authorization of one exact pending registration for a person who holds
  no fresh method here. Registering, revoking and that authorization are
  sensitive changes (`passkey_registration`), and the administrator's
  needs the administrator's own fresh confirmation.

  Every action is on the external plane, through an interactive surface
  (`consent: :interactive`); `recover_admin` is also `scope: :platform`,
  so no ordinary member can invoke it.

  The work is `Sanctum.Passkeys`'s; here each action is read off the wire
  and answered on it:

    * `register` answers the creation options and the registration token
      when it carries no credential; with one, the registered passkey
      (`status: "active"`), a pending one awaiting the platform
      administrator (`status: "awaiting_administrator"`, its id and
      registration digest), or the `confirmation_required` signal.
    * `list` answers the person's active and pending passkeys here.
    * `revoke` answers the revoked passkey.
    * `recover_admin` answers the activated passkey.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.{Context, Passkeys}

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new(
          "passkey",
          "register",
          "Register a passkey",
          [
            Arg.new("credential", :json,
              description:
                "register: the WebAuthn registration the browser's ceremony answered; absent, the answer is the options to begin one with"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("passkey", "list", "List passkeys", [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("passkey", "revoke", "Revoke a passkey", [passkey_id()],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "passkey",
          "recover_admin",
          "Authorize a person's pending passkey",
          [
            Arg.new("user_id", :string,
              required: true,
              description: "recover_admin: the person whose pending registration is authorized"
            ),
            passkey_id(),
            Arg.new("registration_digest", :string,
              required: true,
              description:
                "recover_admin: the digest (sha256:<hex>) of the exact pending registration authorized"
            )
          ],
          scope: :platform,
          kind: :write,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Your passkeys at this server: register, list and revoke them. A platform admin authorizes the exact pending passkey of a person who has no fresh way to confirm here.",
      title: "Passkeys"
    )
  end

  defp passkey_id,
    do:
      Arg.new("passkey_id", :string,
        required: true,
        description: "The passkey, or the pending registration (revoke, recover_admin)"
      )

  def handle(%Context{} = ctx, %{"action" => "register"} = args) do
    credential = args["credential"]

    if is_nil(credential) or is_map(credential) do
      ctx |> Passkeys.register(%{credential: credential}) |> answered()
    else
      {:error, {:invalid_argument, "credential is the browser's WebAuthn registration, as JSON"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Passkeys.list(ctx) do
      {:ok, passkeys} -> {:ok, %{passkeys: passkeys}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "passkey_id" => id}) when is_binary(id) do
    case Passkeys.revoke(ctx, id) do
      {:ok, passkey} -> {:ok, %{passkey: passkey}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "recover_admin",
          "user_id" => user_id,
          "passkey_id" => passkey_id,
          "registration_digest" => digest
        }
      )
      when is_binary(user_id) and is_binary(passkey_id) and is_binary(digest) do
    ctx
    |> Passkeys.recover_admin(%{
      user_id: user_id,
      passkey_id: passkey_id,
      registration_digest: digest
    })
    |> answered()
  end

  def handle(_ctx, %{"action" => "revoke"}),
    do: {:error, {:invalid_argument, "Missing required argument: passkey_id"}}

  def handle(_ctx, %{"action" => "recover_admin"}),
    do:
      {:error,
       {:invalid_argument, "Missing required arguments: user_id, passkey_id, registration_digest"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "passkey.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  defp answered({:ok, answer}), do: {:ok, answer}
  defp answered({:error, reason}), do: {:error, refusal(reason)}

  # The passkeys' own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`), each with the sentence its person reads; the
  # vocabulary's and the stores' own reasons, the consent signal among
  # them, pass as they are.
  defp refusal(:registration_refused),
    do:
      refused(
        :invalid_argument,
        :registration_refused,
        "The passkey's registration does not verify here, or its ceremony expired; begin again"
      )

  defp refusal(:unauthenticated),
    do:
      refused(
        :unauthenticated,
        :unauthenticated,
        "Only a person signed in here, or on a device of theirs, registers a passkey"
      )

  defp refusal(reason), do: reason

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}
end
