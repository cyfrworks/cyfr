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

  # `pair` is not here although it is a person's act: its
  # `consent: :interactive` annotation makes the registry's dispatch gate
  # refuse an API key before this handler runs, with the typed
  # consent_class_required code — a second arm here would only answer in a
  # second vocabulary for a call that can never arrive.
  @person_only ~w(create rename archive unarchive settings provision purge destroy)

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
          "(you are its first member), rename it, archive it, patch its settings — " <>
          "or pair: open a DM with someone you already share an estate with, a " <>
          "frozen two-person athanor that ends when either of you leaves. " <>
          "A person's own athanor is minted at sign-in; a group is archived, never deleted.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          "list" => %{kind: :read, planes: [:external]},
          "get" => %{kind: :read, planes: [:external]},
          "create" => %{kind: :write, planes: [:external]},
          # A pair is minted BY a person, WITH a person — interactive on
          # the annotation so dispatch, discovery and the typed refusal all
          # read one declaration; no standing credential mints a DM.
          "pair" => %{kind: :write, planes: [:external], consent: :interactive},
          "rename" => %{kind: :write, planes: [:external]},
          "archive" => %{kind: :destructive, planes: [:external]},
          "unarchive" => %{kind: :write, planes: [:external]},
          "settings" => %{kind: :write, planes: [:external]},
          "provision" => %{kind: :write, planes: [:external]},
          "purge" => %{kind: :destructive, planes: [:external]},
          "destroy" => %{kind: :destructive, planes: [:external]}
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
              "pair",
              "rename",
              "archive",
              "unarchive",
              "settings",
              "provision",
              "purge",
              "destroy"
            ],
            "description" =>
              "Action to perform (provision: retry a seeding that failed — idempotent; " <>
                "purge: platform admin deletes an archived athanor's storage tree; " <>
                "destroy: platform admin ERASES an archived athanor — storage AND every " <>
                "row it owns, irreversibly, leaving only the archived tombstone)"
          },
          "athanor" => @athanor_arg,
          "name" => %{"type" => "string", "description" => "Group name (create, rename)"},
          "user" => %{
            "type" => "string",
            "description" =>
              "pair: the other person's user id — someone you already share an active " <>
                "estate with"
          },
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
    {:error,
     {:invalid_argument, "athanor.#{action} is a person's act — sign in; an API key cannot do it"}}
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    athanors = Sanctum.Tenancy.list_athanors(ctx)
    {:ok, %{athanors: Enum.map(athanors, &render/1), count: length(athanors)}}
  end

  def handle(%Context{} = ctx, %{"action" => "get"} = args) do
    with {:ok, athanor, _focused} <- resolve(ctx, args, include_archived: true) do
      {:ok, render(athanor)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args)
      when is_binary(name) do
    # The row and the creator's seat only — the estate is filled at first
    # need (`Sanctum.Provisioning.ensure_provisioned/1`), so creating a
    # group never waits on a registry round trip.
    case Athanors.create_group(ctx.user_id, name, slug: Map.get(args, "slug")) do
      {:ok, athanor} ->
        broadcast_athanors_changed(ctx, athanor)
        {:ok, render(athanor)}

      {:error, :invalid_name} ->
        {:error, {:invalid_argument, "A group needs a name of 1–80 characters"}}

      {:error, :slug_taken_or_invalid} ->
        {:error,
         {:invalid_argument,
          "That slug is taken or not a valid slug (lowercase letters, digits, hyphens)"}}

      {:error, {:limit_reached, key, cap}} ->
        {:error, {:invalid_argument, "Limit reached: #{key} = #{cap}"}}

      {:error, reason} ->
        Logger.error("[AthanorTool] athanor.create failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  def handle(_ctx, %{"action" => "create"}),
    do: {:error, {:invalid_argument, "Missing required argument: name"}}

  # The DM verb: find-or-mint the frozen pair of the caller and `user`.
  # Reachability is "we already share an active estate" — checked here, not
  # only drawn in the UI, so the wire cannot be a directory: a user id you
  # cannot see on any members list answers exactly like one that does not
  # exist. The row is minted lazily (no provisioning) and the caller opens
  # its chat by focusing it, like any estate.
  def handle(%Context{} = ctx, %{"action" => "pair", "user" => other} = _args)
      when is_binary(other) and other != "" do
    cond do
      other == ctx.user_id ->
        {:error, {:invalid_argument, "A pair is two people — you are already with yourself"}}

      not Members.shared_estate?(ctx.user_id, other) ->
        {:error,
         {:invalid_argument,
          "You can only open a DM with someone you already share an estate with"}}

      true ->
        case Athanors.create_pair(ctx.user_id, other) do
          {:ok, athanor} ->
            broadcast_athanors_changed(ctx, athanor)
            {:ok, render(athanor)}

          {:error, {:limit_reached, key, cap}} ->
            {:error, {:invalid_argument, "Limit reached: #{key} = #{cap}"}}

          {:error, reason} ->
            Logger.error("[AthanorTool] athanor.pair failed: #{inspect(reason)}")
            {:error, {:unavailable, "Storage"}}
        end
    end
  end

  def handle(_ctx, %{"action" => "pair"}),
    do: {:error, {:invalid_argument, "Missing required argument: user"}}

  def handle(%Context{} = ctx, %{"action" => "rename", "name" => name} = args)
      when is_binary(name) do
    with {:ok, athanor, _focused} <- resolve(ctx, args),
         {:ok, renamed} <- rename(athanor, name) do
      broadcast_athanors_changed(ctx, renamed)
      {:ok, render(renamed)}
    end
  end

  def handle(_ctx, %{"action" => "rename"}),
    do: {:error, {:invalid_argument, "Missing required argument: name"}}

  def handle(%Context{} = ctx, %{"action" => "archive"} = args) do
    with {:ok, athanor, _focused} <- resolve(ctx, args) do
      case Athanors.archive(athanor) do
        {:ok, archived} ->
          # Keys, running work and the members' views are closed by
          # `Athanors.archive/2` itself; only the actor's own chat list is
          # this tool's to refresh.
          Members.broadcast_change(ctx.user_id, archived.id, :athanor_changed)
          {:ok, render(archived)}

        {:error, :home_cannot_be_archived} ->
          {:error, {:invalid_argument, "Home is the server's group and cannot be archived"}}

        {:error, :person_athanor_cannot_be_archived} ->
          {:error, {:invalid_argument, "A person's own athanor is not archived here"}}

        {:error, reason} ->
          Logger.error("[AthanorTool] athanor.archive failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  # A person's own athanor is closed by the door (deny) and reopened by the
  # door (allow); restoring it here while its owner is still denied would
  # reopen a furnace nobody may enter. A retired Home never reopens at all,
  # and neither does a DM that ended — its husk holds one member.
  def handle(%Context{} = ctx, %{"action" => "unarchive"} = args) do
    with {:ok, athanor, _focused} <- resolve(ctx, args, include_archived: true),
         :ok <- owner_admitted(athanor) do
      case Athanors.unarchive(athanor) do
        {:ok, restored} ->
          broadcast_athanors_changed(ctx, restored)
          {:ok, render(restored)}

        {:error, :home_is_final} ->
          {:error,
           {:invalid_argument,
            "That Home is archived for the record; the server has already started a new one"}}

        {:error, :frozen_is_final} ->
          {:error,
           {:invalid_argument,
            "A DM that ended is final — click the name again to start a new one"}}

        {:error, reason} ->
          Logger.error("[AthanorTool] athanor.unarchive failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  # Purging is the operator's act: it deletes an archived athanor's whole
  # storage tree — the one thing archive deliberately leaves in place so
  # unarchive reopens a furnace intact. Blobs only; the rows remain, and a
  # purged athanor that reopens comes back with empty storage. `destroy`
  # below is the verb that also deletes the rows.
  def handle(%Context{} = ctx, %{"action" => "purge"} = args) do
    if ctx.platform_admin do
      with {:ok, athanor, _focused} <- resolve(ctx, args, include_archived: true) do
        case Athanors.purge_storage(athanor) do
          :ok ->
            {:ok, Map.put(render(athanor), "purged", true)}

          {:error, :not_archived} ->
            {:error,
             {:invalid_argument,
              "Only an archived athanor's storage can be purged — archive it first"}}

          {:error, reason} ->
            Logger.error("[AthanorTool] athanor.purge failed: #{inspect(reason)}")
            {:error, {:unavailable, "Storage"}}
        end
      end
    else
      # The same refusal the dispatcher mints for a `scope: :platform` action,
      # so the operator gate reads identically wherever it is applied.
      #
      # Note this is a different WIRE shape from the sentence it replaced:
      # `Sanctum.Unauthorized` recognises the reason, so the router answers
      # a JSON-RPC error (`insufficient_permissions`) rather than an
      # `isError` content result. A client that branches on `result.isError`
      # sees the refusal on the transport instead — which is the correct
      # place for an authorization failure, and is why the gate was moved
      # onto the shared vocabulary.
      {:error, :platform_admin_required}
    end
  end

  # The erasure verb. `purge` reclaims the volume and leaves every row;
  # this deletes both, and only the archived tombstone survives. It refuses
  # a personal athanor — `users.personal_athanor_id` would go on naming a
  # row whose data is gone, and erasing a person is a different act.
  def handle(%Context{} = ctx, %{"action" => "destroy"} = args) do
    if ctx.platform_admin do
      with {:ok, athanor, _focused} <- resolve(ctx, args, include_archived: true) do
        case Athanors.destroy(athanor) do
          {:ok, counts} ->
            {:ok,
             render(athanor)
             |> Map.put("destroyed", true)
             |> Map.put("rows_deleted", Enum.sum(Map.values(counts)))}

          {:error, :not_archived} ->
            {:error,
             {:invalid_argument, "Only an archived athanor can be destroyed — archive it first"}}

          {:error, :personal_athanor} ->
            {:error,
             {:invalid_argument,
              "A person's own athanor is not destroyed here — deny them at the door instead"}}

          {:error, reason} ->
            Logger.error("[AthanorTool] athanor.destroy failed: #{inspect(reason)}")
            {:error, {:unavailable, "Storage"}}
        end
      end
    else
      {:error, :platform_admin_required}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "settings", "settings" => patch} = args)
      when is_map(patch) do
    with {:ok, athanor, _focused} <- resolve(ctx, args) do
      case Athanors.put_settings(athanor, patch) do
        {:ok, updated} ->
          {:ok, render(updated)}

        {:error, reason} ->
          Logger.error("[AthanorTool] athanor.settings failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  # A seeding that failed (the registry was unreachable, a dependency not
  # public) is retried by any member — idempotent, so a provisioned athanor
  # answers at once. The outcome is on the row either way.
  def handle(%Context{} = ctx, %{"action" => "provision"} = args) do
    with {:ok, athanor, focused} <- resolve(ctx, args) do
      case Sanctum.Provisioning.provision(athanor, focused) do
        {:ok, provisioned} ->
          {:ok, render(provisioned)}

        {:error, {:provisioning_failed, step, _detail}} ->
          {:error, "Provisioning failed at #{step} — the error is recorded on the athanor"}

        {:error, reason} ->
          Logger.error("[AthanorTool] athanor.provision failed: #{inspect(reason)}")
          {:error, {:unavailable, "Provisioning"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "settings"}),
    do: {:error, {:invalid_argument, "Missing required argument: settings (an object to merge)"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "athanor.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  # The athanor an action names — `athanor` (an id or route slug), else the
  # caller's focused one — as long as the caller may work in it. An archived
  # athanor is refused on every path unless the action asks for it
  # (`include_archived: true` — a read, or `unarchive` itself): archive is
  # a hard stop for members and Codex alike, not only for the browser.
  #
  # Returns the resolved athanor AND a context focused on it (`scope:
  # :athanor`, its id bound) — the shape every downstream act must run
  # under. `Context.focus/2` is the narrowing: membership, or the operator's
  # audited open. A platform admin's wider scope stops here, not in the
  # handler.
  @doc false
  def resolve(%Context{} = ctx, args, opts \\ []) do
    with {:ok, athanor} <- lookup(ctx, Map.get(args, "athanor"), opts) do
      case Context.focus(ctx, athanor) do
        {:ok, focused} -> {:ok, athanor, focused}
        {:error, :archived} -> open_archived(ctx, athanor)
        {:error, _} -> not_a_member()
      end
    end
  end

  # `focus/2` rightly refuses an archived athanor, and `lookup/3` only
  # admitted one because the action asked for it (`get`, `unarchive`) — so
  # the focused shape is built by hand here, under the same two admissions
  # focus grants: membership, or the operator's audited open.
  defp open_archived(ctx, athanor) do
    admitted? =
      cond do
        Members.member?(ctx.user_id, athanor.id) ->
          true

        ctx.platform_admin ->
          Sanctum.Telemetry.platform_context_event(%{
            caller: :athanor_tool,
            user_id: ctx.user_id,
            athanor_id: athanor.id,
            auth_method: ctx.auth_method
          })

          true

        true ->
          false
      end

    if admitted?,
      do: {:ok, athanor, %{ctx | athanor_id: athanor.id, scope: :athanor}},
      else: not_a_member()
  end

  defp not_a_member, do: {:error, {:invalid_argument, "Not a member of that athanor"}}

  defp lookup(%Context{athanor_id: id}, nil, opts) when is_binary(id), do: get(id, opts)

  defp lookup(%Context{}, nil, _opts),
    do: {:error, {:invalid_argument, "No athanor in focus — pass athanor"}}

  defp lookup(%Context{}, segment, opts) when is_binary(segment) do
    if Athanors.athanor_id?(segment) do
      get(segment, opts)
    else
      segment
      |> Athanors.by_route_slug(include_archived: Keyword.get(opts, :include_archived, false))
      |> or_not_found(segment)
    end
  end

  defp get(id, opts) do
    case Athanors.get(id) do
      {:ok, %{status: "archived"} = athanor} ->
        if Keyword.get(opts, :include_archived, false),
          do: {:ok, athanor},
          else: {:error, {:invalid_argument, "That athanor is archived"}}

      other ->
        or_not_found(other, id)
    end
  end

  # The refusal names what the caller named — an id or a route slug — and
  # nothing else about the athanor.
  defp or_not_found({:ok, athanor}, _named), do: {:ok, athanor}
  defp or_not_found(_, named), do: {:error, {:not_found, "Athanor", named}}

  defp owner_admitted(%{kind: "person", owner_user_id: owner}) when is_binary(owner) do
    case Sanctum.Tenancy.Users.get(owner) do
      {:ok, %{status: "denied"}} ->
        {:error,
         {:invalid_argument,
          "That person is denied at the door — allow them first; that reopens their athanor"}}

      _ ->
        :ok
    end
  end

  defp owner_admitted(_athanor), do: :ok

  defp rename(athanor, name) do
    case Athanors.rename(athanor, name) do
      {:ok, renamed} -> {:ok, renamed}
      {:error, :invalid_name} -> {:error, {:invalid_argument, "A name is 1–80 characters"}}
      {:error, _} -> {:error, {:unavailable, "Storage"}}
    end
  end

  @doc false
  def render(athanor) do
    %{
      id: athanor.id,
      kind: athanor.kind,
      # "open" or "frozen" — a frozen two-person group is a DM, and a
      # client renders it as one.
      roster: athanor.roster,
      name: athanor.name,
      slug: athanor.slug,
      route: Athanors.route_slug(athanor),
      home: athanor.home,
      status: athanor.status,
      member_count:
        case Members.count_by_athanor(athanor.id) do
          {:ok, n} -> n
          {:error, _} -> nil
        end,
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
