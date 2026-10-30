# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Invitation do
  @moduledoc """
  The `invitation` tool: invitations to become a person at this CYFR
  (`Sanctum.Invitations`) — create, revoke, list.

  `create` issues one naming a group athanor the caller holds a seat in,
  or, for the platform administrator, one naming none, optionally
  offering its newcomer a `name` their invitation page fills in, and
  answers its
  code once with the link that opens it, `invitation_url`:
  `<this CYFR's address>/invite#<code>` (`Sanctum.Person.home/0`). The
  code travels in the fragment, so no server log records it; both keys
  are ones the request log redacts (`Prima.Sanitizer`), and the code is
  never stored or shown again. `revoke` closes one still open, as its
  issuer or the administrator; `list` answers every invitation to the
  administrator and the caller's own to anyone else. Each is a person's
  act: an API-key context is refused. An answer carries no null: an
  invitation that names no athanor has no athanor keys.
  """

  alias Sanctum.Context
  alias Sanctum.Invitations

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "invitation",
          "create",
          "Create an invitation",
          [
            Arg.new("athanor_id", :string,
              description:
                "The group athanor the newcomer is seated in, which you hold a seat in. " <>
                  "Left out, the invitation seats them in no group: the platform administrator's alone (create)"
            ),
            Arg.new("name", :string,
              description:
                "The name offered to the newcomer, filled in on their invitation page; they may choose another (create)"
            )
          ],
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "invitation",
          "revoke",
          "Revoke an invitation",
          [
            Arg.new("invitation_id", :string,
              required: true,
              description: "The invitation's id, as list answers it (revoke)"
            )
          ],
          reduces_authority: true,
          kind: :write,
          planes: [:external]
        ),
        Operation.new("invitation", "list", "List invitations", [],
          kind: :read,
          planes: [:external]
        )
      ],
      description:
        "Invitations to become a person here. A member invites someone into a group they sit in; the platform administrator may invite someone into no group. The link is given once, expires after seven days and admits one person. The administrator lists and revokes every invitation; anyone else their own.",
      title: "Invitations"
    )
  end

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in ~w(create revoke list) do
    {:error,
     {:invalid_argument,
      "invitation.#{action} is a person's act — sign in; an API key cannot do it"}}
  end

  def handle(%Context{} = ctx, %{"action" => "create"} = args) do
    with {:ok, %{invitation: invitation, code: code}} <-
           Invitations.create(ctx, Map.get(args, "athanor_id"), Map.get(args, "name")) do
      {:ok,
       %{
         invitation: render(invitation),
         code: code,
         invitation_url: Sanctum.Person.home() <> "/invite#" <> code
       }}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "invitation_id" => id})
      when is_binary(id) do
    with {:ok, invitation} <- Invitations.revoke(ctx, id) do
      {:ok, %{invitation: render(invitation)}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    with {:ok, invitations} <- Invitations.list(ctx) do
      {:ok, %{invitations: Enum.map(invitations, &render/1), count: length(invitations)}}
    end
  end

  def handle(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "invitation.#{action}"}}

  def handle(_ctx, _args), do: {:error, :action_missing}

  defp render(invitation), do: Map.update!(invitation, :expires_at, &DateTime.to_iso8601/1)
end
