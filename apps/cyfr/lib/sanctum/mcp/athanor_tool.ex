# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.AthanorTool do
  @moduledoc """
  The `athanor` tool: the athanors a person belongs to — list them, create a
  group, rename, archive, and patch settings.

  A person's own athanor is minted at sign-in, never here; `create` mints a
  group with the caller as its only member. There is no delete: a group is
  archived, and archived by its last member leaving. Mutations are a
  person's act — an API-key context is refused, since a key belongs to one
  athanor and is nobody's identity.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members}

  @person_only ~w(create rename archive unarchive settings)

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_only do
    {:error, "athanor.#{action} is a person's act — sign in; an API key cannot do it"}
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    athanors = Sanctum.Tenancy.list_athanors(ctx)
    {:ok, %{athanors: Enum.map(athanors, &render/1), count: length(athanors)}}
  end

  def handle(%Context{} = ctx, %{"action" => "get"} = args) do
    with {:ok, athanor} <- resolve(ctx, args) do
      {:ok, render(athanor)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args)
      when is_binary(name) do
    case Sanctum.Provisioning.ensure_group_athanor(ctx, name, slug: Map.get(args, "slug")) do
      {:ok, athanor} ->
        broadcast_athanors_changed(ctx, athanor)
        {:ok, render(athanor)}

      {:error, :invalid_name} ->
        {:error, "A group needs a name of 1–80 characters"}

      {:error, :slug_taken_or_invalid} ->
        {:error, "That slug is taken or not a valid slug (lowercase letters, digits, hyphens)"}

      {:error, {:limit_reached, key, cap}} ->
        {:error, "Limit reached: #{key} = #{cap}"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] athanor.create failed: #{inspect(reason)}")
        {:error, "Failed to create the group"}
    end
  end

  def handle(_ctx, %{"action" => "create"}), do: {:error, "Missing required argument: name"}

  def handle(%Context{} = ctx, %{"action" => "rename", "name" => name} = args)
      when is_binary(name) do
    with {:ok, athanor} <- resolve(ctx, args),
         {:ok, renamed} <- rename(athanor, name) do
      broadcast_athanors_changed(ctx, renamed)
      {:ok, render(renamed)}
    end
  end

  def handle(_ctx, %{"action" => "rename"}), do: {:error, "Missing required argument: name"}

  def handle(%Context{} = ctx, %{"action" => "archive"} = args) do
    with {:ok, athanor} <- resolve(ctx, args) do
      case Athanors.archive(athanor) do
        {:ok, archived} ->
          Sanctum.ApiKey.revoke_all_for_athanor(archived.id)
          broadcast_athanors_changed(ctx, archived)
          {:ok, render(archived)}

        {:error, :home_cannot_be_archived} ->
          {:error, "Home is the server's group and cannot be archived"}

        {:error, :person_athanor_cannot_be_archived} ->
          {:error, "A person's own athanor is not archived here"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] athanor.archive failed: #{inspect(reason)}")
          {:error, "Failed to archive the athanor"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "unarchive"} = args) do
    with {:ok, athanor} <- resolve(ctx, args, include_archived: true) do
      case Athanors.unarchive(athanor) do
        {:ok, restored} ->
          broadcast_athanors_changed(ctx, restored)
          {:ok, render(restored)}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] athanor.unarchive failed: #{inspect(reason)}")
          {:error, "Failed to restore the athanor"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "settings", "settings" => patch} = args)
      when is_map(patch) do
    with {:ok, athanor} <- resolve(ctx, args) do
      case Athanors.put_settings(athanor, patch) do
        {:ok, updated} ->
          {:ok, render(updated)}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] athanor.settings failed: #{inspect(reason)}")
          {:error, "Failed to update settings"}
      end
    end
  end

  def handle(_ctx, %{"action" => "settings"}),
    do: {:error, "Missing required argument: settings (an object to merge)"}

  def handle(_ctx, %{"action" => action}), do: {:error, "Invalid athanor action: #{action}"}
  def handle(_ctx, _args), do: {:error, "Missing required argument: action"}

  # The athanor an action names — `athanor` (an id or route slug), else the
  # caller's focused one — as long as the caller may work in it.
  @doc false
  def resolve(%Context{} = ctx, args, opts \\ []) do
    with {:ok, athanor} <- lookup(ctx, Map.get(args, "athanor"), opts) do
      cond do
        Members.member?(ctx.user_id, athanor.id) ->
          {:ok, athanor}

        # An operator opening an athanor they do not belong to: the audited
        # act `Context.focus/2` records.
        ctx.platform_admin ->
          case Context.focus(ctx, %{athanor | status: "active"}) do
            {:ok, _} -> {:ok, athanor}
            {:error, _} -> {:error, "Not a member of that athanor"}
          end

        true ->
          {:error, "Not a member of that athanor"}
      end
    end
  end

  defp lookup(%Context{athanor_id: id}, nil, _opts) when is_binary(id), do: get(id)
  defp lookup(%Context{}, nil, _opts), do: {:error, "No athanor in focus — pass athanor"}

  defp lookup(%Context{}, "ath_" <> _ = id, _opts), do: get(id)

  defp lookup(%Context{}, slug, opts) when is_binary(slug) do
    if Keyword.get(opts, :include_archived, false) do
      case slug do
        "@" <> ns -> Athanors.get_by_slug("person", ns) |> or_not_found()
        _ -> Athanors.get_by_slug("group", slug) |> or_not_found()
      end
    else
      Athanors.by_route_slug(slug) |> or_not_found()
    end
  end

  defp get(id), do: Athanors.get(id) |> or_not_found()

  defp or_not_found({:ok, athanor}), do: {:ok, athanor}
  defp or_not_found(_), do: {:error, "Athanor not found"}

  defp rename(athanor, name) do
    case Athanors.rename(athanor, name) do
      {:ok, renamed} -> {:ok, renamed}
      {:error, :invalid_name} -> {:error, "A name is 1–80 characters"}
      {:error, _} -> {:error, "Failed to rename"}
    end
  end

  @doc false
  def render(athanor) do
    %{
      id: athanor.id,
      kind: athanor.kind,
      name: athanor.name,
      slug: athanor.slug,
      route: Athanors.route_slug(athanor),
      home: athanor.home,
      status: athanor.status,
      member_count: Members.count_by_athanor(athanor.id),
      settings: Athanors.settings(athanor),
      provisioned: not is_nil(athanor.provisioned_at),
      provisioning_error: Athanors.settings(athanor)["provisioning_error"],
      created_at: athanor.created_at
    }
  end

  # The person's own chat list re-derives on their membership topic; the
  # athanor's members learn of a rename or archive on its notify topic.
  defp broadcast_athanors_changed(%Context{} = ctx, athanor) do
    Members.broadcast_change(ctx.user_id, athanor.id, :athanor_changed)
    Sanctum.Notify.broadcast(athanor.id, :athanor_changed, %{name: athanor.name})
  end
end
