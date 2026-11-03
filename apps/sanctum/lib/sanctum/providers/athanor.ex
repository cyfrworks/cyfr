# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Athanor do
  @moduledoc """
  The `athanor` tool: the caller's own athanor — read it, patch its
  settings, and retry its fill.

  A person's athanor is minted at their admission, never here, and nobody
  else sits in it. Mutations are a person's act — an API-key context is
  refused, since a key belongs to one athanor and is nobody's identity.

  Every verb acts in an athanor the caller holds a seat in, and anyone
  without a current seat is answered as if the athanor did not exist
  (`{:not_found, "Athanor", named}`), whether it is open, archived or
  absent: only its person hears that an athanor is archived.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  @person_only ~w(settings provision)

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "athanor",
          "get",
          "Get athanor",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id or @<namespace>. Defaults to the athanor in focus."
            )
          ],
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "athanor",
          "settings",
          "Settings athanor",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id or @<namespace>. Defaults to the athanor in focus."
            ),
            Arg.new("settings", {:map, Arg.new(nil, :json)},
              required: true,
              description: "For settings: keys to merge into the athanor's settings"
            )
          ],
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "athanor",
          "provision",
          "Provision athanor",
          [
            Arg.new("athanor", :string,
              description:
                "The athanor to act on — an id or @<namespace>. Defaults to the athanor in focus."
            )
          ],
          kind: :write,
          planes: [:external]
        )
      ],
      description:
        "Your own athanor — read it, patch its settings, and retry its fill. A person's athanor is minted when they are admitted.",
      title: "Athanors"
    )
  end

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_only do
    {:error,
     {:invalid_argument, "athanor.#{action} is a person's act — sign in; an API key cannot do it"}}
  end

  def handle(%Context{} = ctx, %{"action" => "get"} = args) do
    with {:ok, athanor, _focused} <- resolve(ctx, args, include_archived: true) do
      {:ok, render(athanor)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "settings", "settings" => patch} = args)
      when is_map(patch) do
    with {:ok, athanor, _focused} <- resolve(ctx, args) do
      case Athanors.put_settings(athanor, patch) do
        {:ok, updated} ->
          {:ok, render(updated)}

        {:error, reason} ->
          Logger.error("[Sanctum.Providers.Athanor] athanor.settings failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  # A seeding that failed (the registry was unreachable, a dependency not
  # public) is retried by its person — idempotent, so a provisioned athanor
  # answers at once. The outcome is on the row either way. An attempt
  # already running — a background fill, a seed sync, another
  # retry — is reported as in progress, the same typed answer a turn gives
  # while the athanor is unfilled, never as a failure.
  def handle(%Context{} = ctx, %{"action" => "provision"} = args) do
    with {:ok, athanor, focused} <- resolve(ctx, args) do
      case Sanctum.Provisioning.provision(athanor, focused) do
        {:ok, provisioned} ->
          {:ok, render(provisioned)}

        {:error, :provisioning_busy} ->
          {:error, :not_provisioned}

        {:error, {:provisioning_failed, step, _detail}} ->
          {:error, "Provisioning failed at #{step} — the error is recorded on the athanor"}

        {:error, reason} ->
          Logger.error("[Sanctum.Providers.Athanor] athanor.provision failed: #{inspect(reason)}")
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
  # (`include_archived: true` — a read): archive is a hard stop for Codex
  # as for the browser.
  #
  # Returns the resolved athanor AND a context focused on it (`scope:
  # :athanor`, its id bound) — the shape every downstream act must run
  # under. `Context.focus/2` is the narrowing: a seat, and nothing else —
  # an operator with none is refused here like anyone else, and a platform
  # context's wider scope stops here, not in the handler. A caller without
  # a seat is refused as a missing athanor is, naming what they named, and
  # only after the seat is found does an archived athanor say so.
  @doc false
  def resolve(%Context{} = ctx, args, opts \\ []) do
    named = Map.get(args, "athanor")

    with {:ok, athanor} <- lookup(ctx, named, opts) do
      case Context.focus(ctx, athanor) do
        {:ok, focused} -> {:ok, athanor, focused}
        {:error, :archived} -> open_archived(ctx, athanor, opts)
        {:error, :unavailable} -> {:error, {:unavailable, "Storage"}}
        {:error, :not_found} -> {:error, {:not_found, "Athanor", named || athanor.id}}
      end
    end
  end

  # `focus/2` answers `:archived` only once it has found the caller's
  # current seat, so this is the caller's archived athanor. It stays refused
  # unless the action asked for it (`get`); then the focused
  # shape is built by hand, under the one admission focus granted: a seat.
  # The operator capability admits nothing here.
  defp open_archived(ctx, athanor, opts) do
    if Keyword.get(opts, :include_archived, false),
      do: {:ok, athanor, %{ctx | athanor_id: athanor.id, scope: :athanor}},
      else: {:error, {:invalid_argument, "That athanor is archived"}}
  end

  defp lookup(%Context{athanor_id: id}, nil, _opts) when is_binary(id), do: get(id)

  defp lookup(%Context{}, nil, _opts),
    do: {:error, {:invalid_argument, "No athanor in focus — pass athanor"}}

  defp lookup(%Context{}, segment, opts) when is_binary(segment) do
    if Athanors.athanor_id?(segment) do
      get(segment)
    else
      segment
      |> Athanors.by_route_slug(include_archived: Keyword.get(opts, :include_archived, false))
      |> or_not_found(segment)
    end
  end

  # An archived row is found like any other: whether the caller may hear
  # that it is archived is `resolve/3`'s to decide once focus has read the
  # seat, so an outsider's refusal for it is the missing athanor's.
  defp get(id), do: or_not_found(Athanors.get(id), id)

  # The refusal names what the caller named — an id or a route slug — and
  # nothing else about the athanor. A store that cannot answer is
  # unavailable, never an absence.
  defp or_not_found({:ok, athanor}, _named), do: {:ok, athanor}
  defp or_not_found({:error, :not_found}, named), do: {:error, {:not_found, "Athanor", named}}
  defp or_not_found({:error, _unreadable}, _named), do: {:error, {:unavailable, "Storage"}}

  @doc false
  def render(athanor) do
    %{
      id: athanor.id,
      name: athanor.name,
      slug: athanor.slug,
      route: Athanors.route_slug(athanor),
      status: athanor.status,
      settings: Athanors.settings(athanor),
      provisioned: not is_nil(athanor.provisioned_at),
      provisioning_failure: Athanors.provisioning_failure(athanor),
      created_at: athanor.created_at
    }
  end
end
