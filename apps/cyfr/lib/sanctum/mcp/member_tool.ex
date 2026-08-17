# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.MemberTool do
  @moduledoc """
  The `member` tool: who is in an athanor — list, add (by email or by
  user id), remove, leave.

  Any member may add or remove; there are no roles. Adding an email the
  server does not know leaves an invited row that activates on that
  person's first sign-in, and — when the door would not admit them — a
  request for the platform admin. `add` answers the same way whether or not
  the address is already known here, so it cannot be used to enumerate the
  server's people. Mutations are a person's act; an API-key context is
  refused.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.MCP.AthanorTool
  alias Sanctum.Tenancy.Members

  @person_only ~w(add remove leave)

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_only do
    {:error, "member.#{action} is a person's act — sign in; an API key cannot do it"}
  end

  def handle(%Context{} = ctx, %{"action" => "list"} = args) do
    with {:ok, athanor} <- AthanorTool.resolve(ctx, args, include_archived: true) do
      members =
        Members.list_by_athanor(athanor.id,
          limit: int_arg(args, "limit", 500),
          offset: int_arg(args, "offset", 0)
        )

      {:ok, %{athanor: athanor.id, members: Enum.map(members, &render/1), count: length(members)}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "add"} = args) do
    with {:ok, athanor} <- AthanorTool.resolve(ctx, args),
         {:ok, target} <- target(args) do
      case Members.add(athanor, target, ctx.user_id) do
        {:ok, _added_or_invited} ->
          # Uniform: whether the person is already here or arrives later,
          # the row is in place and the caller learns nothing else.
          {:ok, %{athanor: athanor.id, member: shown(target), state: "added"}}

        {:error, :invalid_email} ->
          {:error, "That is not an email address"}

        {:error, :person_athanor} ->
          {:error, "A person's own athanor has one member — its owner; add people to a group"}

        {:error, :ambiguous_email} ->
          {:error, "More than one person here signs in with that email — add them by user id"}

        {:error, :email_unverified} ->
          {:error,
           "That address can't be seated by email — their sign-in provider has not verified it; " <>
             "add them by user id"}

        {:error, :athanor_archived} ->
          {:error, "That athanor is archived"}

        {:error, {:limit_reached, key, cap}} ->
          {:error, "Limit reached: #{key} = #{cap}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] member.add failed: #{inspect(reason)}")
          {:error, "Failed to add the member"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "remove"} = args) do
    with {:ok, athanor} <- AthanorTool.resolve(ctx, args),
         {:ok, target} <- target(args) do
      case Members.remove_member(athanor, target) do
        :ok ->
          {:ok, %{athanor: athanor.id, member: shown(target), state: "removed"}}

        {:error, :person_athanor} ->
          {:error, "You cannot remove the owner of a person's athanor"}

        {:error, :not_found} ->
          {:error, "Not a member"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] member.remove failed: #{inspect(reason)}")
          {:error, "Failed to remove the member"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "leave"} = args) do
    with {:ok, athanor} <- AthanorTool.resolve(ctx, args) do
      cond do
        athanor.kind == "person" ->
          {:error, "You cannot leave your own athanor"}

        true ->
          case Members.remove_member(athanor, user_id: ctx.user_id) do
            :ok -> {:ok, %{athanor: athanor.id, state: "left"}}
            {:error, :not_found} -> {:error, "Not a member"}
            {:error, _} -> {:error, "Failed to leave"}
          end
      end
    end
  end

  def handle(_ctx, %{"action" => action}), do: {:error, "Invalid member action: #{action}"}
  def handle(_ctx, _args), do: {:error, "Missing required argument: action"}

  defp target(%{"email" => email}) when is_binary(email) and email != "",
    do: {:ok, [email: email]}

  defp target(%{"user_id" => user_id}) when is_binary(user_id) and user_id != "",
    do: {:ok, [user_id: user_id]}

  defp target(_), do: {:error, "Missing required argument: email or user_id"}

  defp shown(email: email), do: %{email: String.downcase(email)}
  defp shown(user_id: user_id), do: %{user_id: user_id}

  defp int_arg(args, key, default) do
    case Map.get(args, key) do
      n when is_integer(n) ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp render(row) do
    %{
      user_id: row.user_id,
      email: row.email,
      display_name: row.display_name,
      namespace: row.namespace,
      status: row.status,
      since: row.since
    }
  end
end
