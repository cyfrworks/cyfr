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

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    alias Cyfr.Ops.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "member",
          "list",
          "List member",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id, a group slug, or @<namespace>. Defaults to the athanor in focus."
            ),
            Arg.new("limit", :integer,
              description: "Page size for list (default and ceiling 500)"
            ),
            Arg.new("offset", :integer, description: "Rows to skip for list (default 0)")
          ],
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "member",
          "add",
          "Add member",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id, a group slug, or @<namespace>. Defaults to the athanor in focus."
            ),
            Arg.new("email", :string, description: "The person's email (add, remove)"),
            Arg.new("user_id", :string,
              description: "The person's user id, when already on this server (add, remove)"
            )
          ],
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "member",
          "remove",
          "Remove member",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id, a group slug, or @<namespace>. Defaults to the athanor in focus."
            ),
            Arg.new("email", :string, description: "The person's email (add, remove)"),
            Arg.new("user_id", :string,
              description: "The person's user id, when already on this server (add, remove)"
            )
          ],
          kind: :destructive,
          planes: [:external]
        ),
        Operation.new(
          "member",
          "leave",
          "Leave member",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id, a group slug, or @<namespace>. Defaults to the athanor in focus."
            )
          ],
          kind: :write,
          planes: [:external]
        )
      ],
      description:
        "Who is in an athanor. Any member may add (by email or user id), remove, or leave — there are no roles. Adding an email the server has not seen leaves an invitation that activates on that person's first sign-in.",
      title: "Members"
    )
  end

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_only do
    {:error,
     {:invalid_argument, "member.#{action} is a person's act — sign in; an API key cannot do it"}}
  end

  def handle(%Context{} = ctx, %{"action" => "list"} = args) do
    with {:ok, athanor, _focused} <- AthanorTool.resolve(ctx, args, include_archived: true),
         {:ok, members} <-
           Members.list_by_athanor(athanor.id,
             limit: int_arg(args, "limit", 500),
             offset: int_arg(args, "offset", 0)
           ) do
      {:ok, %{athanor: athanor.id, members: Enum.map(members, &render/1), count: length(members)}}
    else
      {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
      other -> other
    end
  end

  def handle(%Context{} = ctx, %{"action" => "add"} = args) do
    with {:ok, athanor, _focused} <- AthanorTool.resolve(ctx, args),
         {:ok, target} <- target(args) do
      case Members.add(athanor, target, ctx.user_id) do
        {:ok, _added_or_invited} ->
          # Uniform: whether the person is already here or arrives later,
          # the row is in place and the caller learns nothing else.
          {:ok, %{athanor: athanor.id, member: shown(target), state: "added"}}

        {:error, :invalid_email} ->
          {:error, {:invalid_argument, "That is not an email address"}}

        {:error, :person_athanor} ->
          {:error,
           {:invalid_argument,
            "A person's own athanor has one member — its owner; add people to a group"}}

        {:error, :ambiguous_email} ->
          {:error,
           {:invalid_argument,
            "More than one person here signs in with that email — add them by user id"}}

        {:error, :email_unverified} ->
          {:error,
           {:invalid_argument,
            "That address can't be seated by email — their sign-in provider has not verified it; " <>
              "add them by user id"}}

        {:error, :athanor_archived} ->
          {:error, {:invalid_argument, "That athanor is archived"}}

        {:error, {:limit_reached, key, cap}} ->
          {:error, {:invalid_argument, "Limit reached: #{key} = #{cap}"}}

        {:error, reason} ->
          Logger.error("[MemberTool] member.add failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "remove"} = args) do
    with {:ok, athanor, _focused} <- AthanorTool.resolve(ctx, args),
         {:ok, target} <- target(args) do
      case Members.remove_member(athanor, target) do
        :ok ->
          {:ok, %{athanor: athanor.id, member: shown(target), state: "removed"}}

        {:error, :person_athanor} ->
          {:error, {:invalid_argument, "You cannot remove the owner of a person's athanor"}}

        {:error, :not_found} ->
          {:error, {:not_found, "Member", named(target)}}

        {:error, reason} ->
          Logger.error("[MemberTool] member.remove failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "leave"} = args) do
    with {:ok, athanor, _focused} <- AthanorTool.resolve(ctx, args) do
      cond do
        athanor.kind == "person" ->
          {:error, {:invalid_argument, "You cannot leave your own athanor"}}

        true ->
          case Members.remove_member(athanor, user_id: ctx.user_id) do
            :ok -> {:ok, %{athanor: athanor.id, state: "left"}}
            {:error, :not_found} -> {:error, {:invalid_argument, "Not a member"}}
            {:error, _} -> {:error, {:unavailable, "Storage"}}
          end
      end
    end
  end

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "member.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  defp target(%{"email" => email}) when is_binary(email) and email != "",
    do: {:ok, [email: email]}

  defp target(%{"user_id" => user_id}) when is_binary(user_id) and user_id != "",
    do: {:ok, [user_id: user_id]}

  defp target(_),
    do: {:error, {:invalid_argument, "Missing required argument: email or user_id"}}

  defp shown(email: email), do: %{email: String.downcase(email)}
  defp shown(user_id: user_id), do: %{user_id: user_id}

  # The person the caller named, for a refusal that has to say which one.
  # Only ever what the caller already sent back to them.
  defp named(email: email), do: String.downcase(email)
  defp named(user_id: user_id), do: user_id

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
