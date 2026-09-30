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

  @actions ~w(register list revoke recover_admin)

  def handle(%Context{}, %{"action" => action}) when action in @actions, do: {:error, :not_built}
  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "passkey.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}
end
