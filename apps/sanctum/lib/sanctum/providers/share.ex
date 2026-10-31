# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Share do
  @moduledoc """
  The `share` tool: one of a person's attach-only vault entries offered to
  a group they are in or to everyone on this CYFR, so the people it is
  offered to grant it to their own components, which use it with CYFR
  attaching the key to each request and never disclosing it. Thin
  argument mapping over `Sanctum.Shares`, which owns every rule.

  `list`, `usage` and `offered` are reads on both planes, so the assistant
  reads them in a chain. `create`, `set_audience`, `set_caps` and `revoke`
  are the owner's writes, on the interactive consent class and the
  external plane alone; `revoke` only takes authority away. Every answer
  names shares, entries and people by id, with audiences, caps and counts,
  and never a value of the entry.
  """

  require Logger
  require Prima.ConsentSignal

  alias Sanctum.Context
  alias Sanctum.Shares

  @doc false
  # The tool's wire definition: schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    share_id = Arg.new("share_id", :string, required: true, description: "Share id (shr_…)")

    audience =
      Arg.new("audience", :string,
        required: true,
        enum: Arca.Shares.audiences(),
        description:
          "Who it is offered to: everyone on this CYFR, or the active members of one group"
      )

    group_id =
      Arg.new("group_id", :string,
        description:
          "The group a group audience names, one you are an active member of; none for everyone"
      )

    # The audience the caller saw: a change is decided against it, and one
    # whose stored audience moved since is a conflict, with nothing saved.
    expected =
      Arg.new(
        "expected",
        {:record,
         [
           Arg.new("audience", :string,
             required: true,
             enum: Arca.Shares.audiences(),
             description: "The audience as the caller saw it: everyone, or a group"
           ),
           Arg.new("group_id", :string,
             description: "The group as the caller saw it; none for everyone"
           )
         ]},
        required: true,
        description:
          "The audience the change was decided against, as the caller saw it; a stored " <>
            "audience that differs is a conflict and nothing is saved"
      )

    cap = fn name, description ->
      Arg.new(name, :integer,
        nullable: true,
        min: 0,
        max: Arca.Shares.max_cap(),
        description: description
      )
    end

    person_daily =
      cap.(
        "person_daily",
        "Requests one person may make through it each day; 0 admits none; omitted or null " <>
          "is no limit"
      )

    total_daily =
      cap.(
        "total_daily",
        "Requests everyone together may make through it each day; 0 admits none; omitted " <>
          "or null is no limit"
      )

    owner = [planes: [:external], consent: :interactive]
    read = [kind: :read, planes: [:external, :in_chain]]

    Operation.tool(
      [
        Operation.new(
          "share",
          "create",
          "Share a key: one attach-only entry of your own athanor, an API key or a bundle " <>
            "whose destination names its methods and paths, offered to everyone or to a " <>
            "group you are in, with optional daily caps",
          [
            Arg.new("entry_id", :string,
              required: true,
              description: "Vault entry id (vlt_…) of your own athanor"
            ),
            audience,
            group_id,
            person_daily,
            total_daily
          ],
          [kind: :write] ++ owner
        ),
        Operation.new(
          "share",
          "list",
          "Your shares, active and revoked, oldest first: each names its entry, its " <>
            "audience and its caps, with today's total use (used_today)",
          [],
          [sources: []] ++ read
        ),
        Operation.new(
          "share",
          "set_audience",
          "Set a share's audience; widening it to everyone or another group asks a " <>
            "confirmation",
          [share_id, audience, group_id, expected],
          [kind: :write] ++ owner
        ),
        Operation.new(
          "share",
          "set_caps",
          "Set a share's two daily caps: both are written, and one omitted or null is no " <>
            "limit",
          [share_id, person_daily, total_daily],
          [kind: :write] ++ owner
        ),
        Operation.new(
          "share",
          "revoke",
          "Revoke a share: the next request through it is refused, and every grant that " <>
            "binds it must be given again",
          [share_id],
          [kind: :destructive, reduces_authority: true] ++ owner
        ),
        Operation.new(
          "share",
          "usage",
          "A share's use: each person who used it, by id and display name, with their " <>
            "count by day, and the share's day totals",
          [
            share_id,
            Arg.new("days", :integer,
              required: true,
              min: 1,
              max: Arca.ShareUsage.kept_days(),
              description: "Days of use to read, today included"
            )
          ],
          [sources: [:outside]] ++ read
        ),
        Operation.new(
          "share",
          "offered",
          "The shares offered to you: each with its owner, the entry's kind, provider, " <>
            "field names and destination, and how many requests you made through it today " <>
            "(used_today); never another person's use",
          [],
          [sources: [:outside]] ++ read
        )
      ],
      description:
        "Keys shared between people on this CYFR: one of your attach-only vault entries offered to a group you are in or to everyone, which the people it is offered to grant to their own components; CYFR attaches the key to each request and never discloses it. list, usage and offered are reads; create, set_audience, set_caps and revoke are the owner's.",
      title: "Shares"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "create"} = args) do
    params = %{
      entry_id: args["entry_id"],
      audience: args["audience"],
      group_id: args["group_id"],
      person_daily: args["person_daily"],
      total_daily: args["total_daily"]
    }

    case Shares.create(ctx, params) do
      {:ok, share} -> {:ok, %{share: share}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Shares.list(ctx) do
      {:ok, shares} -> {:ok, %{shares: shares}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "set_audience", "share_id" => id} = args)
      when is_binary(id) do
    with {:ok, expected} <- expected(args) do
      params = %{
        share_id: id,
        audience: args["audience"],
        group_id: args["group_id"],
        expected: expected
      }

      case Shares.set_audience(ctx, params) do
        {:ok, changed} -> {:ok, %{status: "updated", share_id: id, changed: changed == :changed}}
        {:error, reason} -> {:error, fmt(reason)}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "set_caps", "share_id" => id} = args)
      when is_binary(id) do
    params = %{
      share_id: id,
      person_daily: args["person_daily"],
      total_daily: args["total_daily"]
    }

    case Shares.set_caps(ctx, params) do
      {:ok, changed} -> {:ok, %{status: "updated", share_id: id, changed: changed == :changed}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  # The profiles the revoke blocked are other athanors' rows, so the answer
  # names the share alone.
  def handle(%Context{} = ctx, %{"action" => "revoke", "share_id" => id}) when is_binary(id) do
    case Shares.revoke(ctx, id) do
      {:ok, _blocked} -> {:ok, %{status: "revoked", share_id: id}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "usage", "share_id" => id, "days" => days})
      when is_binary(id) do
    case Shares.usage(ctx, id, days) do
      {:ok, usage} -> {:ok, Map.put(usage, :share_id, id)}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "offered"}) do
    case Shares.offered_with_use(ctx) do
      {:ok, shares} -> {:ok, %{shares: shares}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "usage"}),
    do: {:error, {:invalid_argument, "usage requires share_id and days"}}

  def handle(_ctx, %{"action" => action}) when action in ~w(set_audience set_caps revoke),
    do: {:error, {:invalid_argument, "#{action} requires share_id"}}

  def handle(_ctx, _args),
    do: {:error, Prima.Provider.invalid_action("share", action_enum())}

  # ---------------------------------------------------------------------------

  # The audience a set_audience call was decided against, held to its
  # shape before Sanctum is called: present and a record. Whether it is an
  # audience a share may hold is Sanctum's (`:invalid_expected`).
  defp expected(%{"expected" => %{} = expected}),
    do: {:ok, %{audience: expected["audience"], group_id: expected["group_id"]}}

  defp expected(%{"expected" => _not_a_record}),
    do:
      {:error,
       {:invalid_argument, "invalid_expected: expected is a record of audience and group_id"}}

  defp expected(_args),
    do:
      {:error,
       {:invalid_argument,
        "expected_required: set_audience names the audience it was decided against, " <>
          "as expected"}}

  # The confirmation signal, whose id the surface confirms, and the typed
  # refusals the gate's vocabulary renders pass as they are.
  defp fmt({tag, payload} = signal) when Prima.ConsentSignal.is_signal(tag, payload), do: signal

  defp fmt(reason) when reason in [:not_found, :unavailable, :denied], do: reason

  defp fmt({:conflict, message} = conflict) when is_binary(message), do: conflict

  defp fmt(:conflict),
    do:
      {:conflict, "conflict: the share changed since it was read; read it again and decide anew"}

  # The interactive class, refused as the gate refuses it.
  defp fmt({:surface_not_permitted, _method} = refusal), do: {:consent_class_required, refusal}

  defp fmt(refusal)
       when refusal in [:guest_plane, :not_authenticated, :anonymous, :not_standing],
       do: {:consent_class_required, refusal}

  defp fmt(reason) when reason in [:anonymous_denied, :no_person],
    do: {:consent_class_required, :anonymous}

  defp fmt(:not_own_athanor),
    do:
      {:invalid_argument,
       "not_own_athanor: a key is shared, and its shares read and managed, from your own " <>
         "athanor"}

  defp fmt(:entry_required),
    do: {:invalid_argument, "entry_required: name the entry to share by its id"}

  defp fmt(:share_required), do: {:invalid_argument, "share_required: name the share by its id"}

  defp fmt(:invalid_audience),
    do:
      {:invalid_argument,
       "invalid_audience: audience is everyone with no group_id, or group with the " <>
         "group_id of a group you are in"}

  defp fmt(:invalid_expected),
    do:
      {:invalid_argument,
       "invalid_expected: expected is the audience the change was decided against, " <>
         "everyone with no group_id or group with its group_id"}

  defp fmt(:not_member),
    do:
      {:invalid_argument,
       "not_member: a group audience names an active group you are an active member of"}

  defp fmt(:already_shared),
    do: {:conflict, "already_shared: the entry is already shared with that audience"}

  defp fmt(:invalid_caps),
    do:
      {:invalid_argument,
       "invalid_caps: a cap is a whole number from 0 to #{Arca.Shares.max_cap()}, or null " <>
         "for no limit"}

  defp fmt(:invalid_days),
    do: {:invalid_argument, "invalid_days: days is from 1 to #{Arca.ShareUsage.kept_days()}"}

  defp fmt(:disclosed_not_shareable),
    do:
      {:invalid_argument,
       "disclosed_not_shareable: only an attach-only entry is shared; a disclosed entry " <>
         "hands its value to components"}

  defp fmt(:kind_not_shareable),
    do:
      {:invalid_argument,
       "kind_not_shareable: a shared entry is one of " <>
         Enum.join(Prima.CredentialKinds.shareable(), ", ")}

  defp fmt(:destination_incomplete),
    do:
      {:invalid_argument,
       "destination_incomplete: a shared entry's destination names its methods and paths; " <>
         "rebind the entry first"}

  defp fmt({:entry_unavailable, status}) when is_binary(status),
    do: {:invalid_argument, "entry_unavailable: the entry is #{status}"}

  defp fmt({:share_unavailable, status}) when is_binary(status),
    do: {:invalid_argument, "share_unavailable: the share is #{status}"}

  # A row the vocabularies refuse, here or in the store: each field named
  # with its rule, never the value given.
  defp fmt({:invalid, %{} = errors}) when map_size(errors) > 0 do
    rules =
      errors
      |> Enum.sort()
      |> Enum.map_join("; ", fn {field, messages} ->
        "#{field} #{Enum.join(List.wrap(messages), ", ")}"
      end)

    {:invalid_argument, "invalid: " <> rules}
  end

  defp fmt(:invalid_request),
    do: {:invalid_argument, "invalid_request: the change cannot be confirmed as asked"}

  # A reason this tool has no sentence for is logged by its shape and
  # answered as one word: a reason on a credential's surface is never
  # rendered by inspecting it.
  defp fmt(reason) do
    Logger.warning(
      "[Sanctum.Providers.Share] unrenderable reason: " <> Prima.LoggerContext.shape(reason)
    )

    {:unavailable, "Shares"}
  end

  defp action_enum, do: Prima.Provider.action_enum(definition())
end
