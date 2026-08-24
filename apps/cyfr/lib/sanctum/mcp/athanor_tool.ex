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

  @person_only ~w(create rename archive unarchive settings provision)

  # An `athanor` argument names the athanor an action works on: an id, a
  # group slug, or `@<namespace>`; absent, the caller's focused athanor.
  @athanor_arg %{
    "type" => "string",
    "description" =>
      "The athanor to act on — an id, a group slug, or @<namespace>. " <>
        "Defaults to the athanor in focus."
  }

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    %{
      name: "athanor",
      title: "Athanors",
      description:
        "The athanors you belong to — your own and your groups. Create a group " <>
          "(you are its first member), rename it, archive it, patch its settings. " <>
          "A person's own athanor is minted at sign-in; a group is archived, never deleted.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          "list" => %{kind: :read, planes: [:external]},
          "get" => %{kind: :read, planes: [:external]},
          "create" => %{kind: :write, planes: [:external]},
          "rename" => %{kind: :write, planes: [:external]},
          "archive" => %{kind: :destructive, planes: [:external]},
          "unarchive" => %{kind: :write, planes: [:external]},
          "settings" => %{kind: :write, planes: [:external]},
          "provision" => %{kind: :write, planes: [:external]}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "list",
              "get",
              "create",
              "rename",
              "archive",
              "unarchive",
              "settings",
              "provision"
            ],
            "description" =>
              "Action to perform (provision: retry a seeding that failed — idempotent)"
          },
          "athanor" => @athanor_arg,
          "name" => %{"type" => "string", "description" => "Group name (create, rename)"},
          "slug" => %{
            "type" => "string",
            "description" => "Optional slug for create; derived from the name when absent"
          },
          "settings" => %{
            "type" => "object",
            "description" => "For settings: keys to merge into the athanor's settings"
          }
        },
        "required" => ["action"]
      }
    }
  end

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_only do
    {:error, "athanor.#{action} is a person's act — sign in; an API key cannot do it"}
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    athanors = Sanctum.Tenancy.list_athanors(ctx)
    {:ok, %{athanors: Enum.map(athanors, &render/1), count: length(athanors)}}
  end

  def handle(%Context{} = ctx, %{"action" => "get"} = args) do
    with {:ok, athanor} <- resolve(ctx, args, include_archived: true) do
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
          # Keys, running work and the members' views are closed by
          # `Athanors.archive/2` itself; only the actor's own chat list is
          # this tool's to refresh.
          Members.broadcast_change(ctx.user_id, archived.id, :athanor_changed)
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

  # A person's own athanor is closed by the door (deny) and reopened by the
  # door (allow); restoring it here while its owner is still denied would
  # reopen a furnace nobody may enter. A retired Home never reopens at all.
  def handle(%Context{} = ctx, %{"action" => "unarchive"} = args) do
    with {:ok, athanor} <- resolve(ctx, args, include_archived: true),
         :ok <- owner_admitted(athanor) do
      case Athanors.unarchive(athanor) do
        {:ok, restored} ->
          broadcast_athanors_changed(ctx, restored)
          {:ok, render(restored)}

        {:error, :home_is_final} ->
          {:error,
           "That Home is archived for the record; the server has already started a new one"}

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

  # A seeding that failed (the registry was unreachable, a dependency not
  # public) is retried by any member — idempotent, so a provisioned athanor
  # answers at once. The outcome is on the row either way.
  def handle(%Context{} = ctx, %{"action" => "provision"} = args) do
    with {:ok, athanor} <- resolve(ctx, args) do
      case Sanctum.Provisioning.provision(athanor, %{ctx | athanor_id: athanor.id}) do
        {:ok, provisioned} ->
          {:ok, render(provisioned)}

        {:error, {:provisioning_failed, step, _detail}} ->
          {:error, "Provisioning failed at #{step} — the error is recorded on the athanor"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] athanor.provision failed: #{inspect(reason)}")
          {:error, "Provisioning failed"}
      end
    end
  end

  def handle(_ctx, %{"action" => "settings"}),
    do: {:error, "Missing required argument: settings (an object to merge)"}

  def handle(_ctx, %{"action" => action}), do: {:error, "Invalid athanor action: #{action}"}
  def handle(_ctx, _args), do: {:error, "Missing required argument: action"}

  # The athanor an action names — `athanor` (an id or route slug), else the
  # caller's focused one — as long as the caller may work in it. An archived
  # athanor is refused on every path unless the action asks for it
  # (`include_archived: true` — a read, or `unarchive` itself): archive is
  # a hard stop for members and Codex alike, not only for the browser.
  @doc false
  def resolve(%Context{} = ctx, args, opts \\ []) do
    with {:ok, athanor} <- lookup(ctx, Map.get(args, "athanor"), opts) do
      cond do
        Members.member?(ctx.user_id, athanor.id) ->
          {:ok, athanor}

        # An operator opening an athanor they do not belong to: the audited
        # act `Context.focus/2` records — or, for an archived one that only
        # `unarchive`/`get` may name, the same audit event written here,
        # since focus rightly refuses an archived athanor.
        ctx.platform_admin and athanor.status == "archived" ->
          Sanctum.Telemetry.platform_context_event(%{
            caller: :athanor_tool,
            user_id: ctx.user_id,
            athanor_id: athanor.id,
            auth_method: ctx.auth_method
          })

          {:ok, athanor}

        ctx.platform_admin ->
          case Context.focus(ctx, athanor) do
            {:ok, _} -> {:ok, athanor}
            {:error, _} -> {:error, "Not a member of that athanor"}
          end

        true ->
          {:error, "Not a member of that athanor"}
      end
    end
  end

  defp lookup(%Context{athanor_id: id}, nil, opts) when is_binary(id), do: get(id, opts)
  defp lookup(%Context{}, nil, _opts), do: {:error, "No athanor in focus — pass athanor"}

  defp lookup(%Context{}, "ath_" <> _ = id, opts), do: get(id, opts)

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

  defp get(id, opts) do
    case Athanors.get(id) do
      {:ok, %{status: "archived"} = athanor} ->
        if Keyword.get(opts, :include_archived, false),
          do: {:ok, athanor},
          else: {:error, "That athanor is archived"}

      other ->
        or_not_found(other)
    end
  end

  defp or_not_found({:ok, athanor}), do: {:ok, athanor}
  defp or_not_found(_), do: {:error, "Athanor not found"}

  defp owner_admitted(%{kind: "person", owner_user_id: owner}) when is_binary(owner) do
    case Sanctum.Tenancy.Users.get(owner) do
      {:ok, %{status: "denied"}} ->
        {:error,
         "That person is denied at the door — allow them first; that reopens their athanor"}

      _ ->
        :ok
    end
  end

  defp owner_admitted(_athanor), do: :ok

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
