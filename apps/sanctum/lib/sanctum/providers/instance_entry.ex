# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.InstanceEntry do
  @moduledoc """
  The `instance_entry` tool: the instance's own credentials, entered once
  by the platform administrator and offered to the people on it. Thin
  argument mapping over `Sanctum.InstanceEntries`, which owns every rule.

  Every action but `offered` is the operator's (`scope: :platform`, the
  interactive consent class, checked at admission), and the verbs check
  both again. `offered` is a read any signed-in person makes: the active
  entries offered to them, metadata only, each with their own count of
  its use today. `people` is the operator's read of whom an audience may
  list. Material flows one way: `create` and `rotate` take field values,
  and nothing returns them.
  """

  require Logger
  require Prima.ConsentSignal

  alias Sanctum.Context
  alias Sanctum.InstanceEntries

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    entry_id =
      Arg.new("entry_id", :string, required: true, description: "Instance entry id (ine_…)")

    # An instance entry's destination names its methods and paths: the
    # account is reached only where the administrator said.
    destination = fn description ->
      Arg.new(
        "destination",
        {:record,
         [
           Arg.new("hosts", {:array, Arg.new(nil, :string)},
             required: true,
             min: 1,
             max: Prima.Destination.max_entries(),
             description: "Hosts the material may go to: exact names, or *. and a name"
           ),
           Arg.new("scheme", :string,
             enum: ["http", "https"],
             description: "https unless http is stated"
           ),
           Arg.new("port", :integer,
             min: 1,
             max: 65_535,
             description: "The port; the scheme's default when absent"
           ),
           Arg.new("methods", {:array, Arg.new(nil, :string, enum: Prima.Destination.methods())},
             required: true,
             min: 1,
             description: "HTTP methods admitted"
           ),
           Arg.new("paths", {:array, Arg.new(nil, :string)},
             required: true,
             min: 1,
             max: Prima.Destination.max_entries(),
             description: "Path prefixes admitted, each beginning with /"
           )
         ]},
        required: true,
        description: description
      )
    end

    audience = fn ->
      Arg.new("audience", :string,
        required: true,
        enum: ["everyone", "listed"],
        description: "Who it is offered to: everyone on the instance, or the listed people"
      )
    end

    members =
      Arg.new("members", {:array, Arg.new(nil, :string)},
        description: "The listed people, by person id; an everyone audience keeps none"
      )

    policy = fn opts ->
      Arg.new(
        "component_policy",
        :string,
        [
          enum: ["any", "shipped"],
          description:
            "Which components may use it: any a person consents to (any), or only an " <>
              "unmodified shipped component (shipped)"
        ] ++ opts
      )
    end

    cap = fn name, description ->
      Arg.new(name, :integer,
        nullable: true,
        min: 0,
        max: Arca.InstanceEntries.max_cap(),
        description: description
      )
    end

    person_daily =
      cap.(
        "person_daily",
        "Requests one person may make through it each day; 0 admits none, null takes " <>
          "instance_entry_person_daily"
      )

    total_daily =
      cap.(
        "total_daily",
        "Requests everyone together may make through it each day; 0 admits none, null " <>
          "takes instance_entry_total_daily"
      )

    platform = [scope: :platform, planes: [:external], consent: :interactive]

    Operation.tool(
      [
        Operation.new(
          "instance_entry",
          "create",
          "Create instance entry",
          [
            Arg.new("name", :string,
              required: true,
              description: "Entry label — unique among living instance entries"
            ),
            Arg.new("kind", :string,
              required: true,
              description:
                "What the entry holds: an API key or a bundle of fields; an OAuth account " <>
                  "is an athanor's own entry",
              enum: ["api_key", "bundle"]
            ),
            Arg.new("provider_hint", :string,
              description: "Immutable provider tag (e.g. 'openai.com'); set at create only"
            ),
            Arg.new("fields", {:map, Arg.new(nil, :string)},
              description: "Secret material as name → value"
            ),
            destination.("Where the material may go, its methods and paths included"),
            audience.(),
            members,
            policy.(default: "any"),
            person_daily,
            total_daily
          ],
          [kind: :write] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "rotate",
          "Rotate instance entry",
          [
            entry_id,
            Arg.new("fields", {:map, Arg.new(nil, :string)},
              required: true,
              description: "Secret material as name → value; names mirror field_names"
            ),
            Arg.new("expected_payload_rev", :integer,
              required: true,
              description: "CAS token for rotate — the revision the caller last saw"
            )
          ],
          [kind: :write] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "rebind",
          "Rebind instance entry",
          [entry_id, destination.("Where the material may go from now on")],
          [kind: :write] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "set_audience",
          "Set instance entry audience",
          [entry_id, audience.(), members],
          [kind: :write] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "set_component_policy",
          "Set instance entry component policy",
          [entry_id, policy.(required: true)],
          [kind: :write] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "set_caps",
          "Set instance entry caps",
          [entry_id, person_daily, total_daily],
          [kind: :write] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "revoke",
          "Revoke instance entry",
          [entry_id],
          [kind: :destructive] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "delete",
          "Delete instance entry",
          [entry_id],
          [kind: :destructive] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "list",
          "List instance entries",
          [],
          [kind: :read] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "usage",
          "Instance entry usage",
          [
            entry_id,
            Arg.new("days", :integer,
              required: true,
              min: 1,
              max: Arca.InstanceEntryUsage.kept_days(),
              description: "Days of use to read, today included"
            )
          ],
          [kind: :read] ++ platform
        ),
        Operation.new(
          "instance_entry",
          "offered",
          "Offered instance entries: each active entry offered to you, with its provider, " <>
            "destination and component policy, and how many requests you made through it " <>
            "today (used_today); never another person's use",
          [],
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "instance_entry",
          "people",
          "People an audience may list: everyone who has signed in to this instance and " <>
            "stands active, each as an id and a display name; someone who has not signed in " <>
            "yet cannot be listed",
          [],
          [kind: :read] ++ platform
        )
      ],
      description:
        "The instance's own credentials: entered once by the platform administrator and offered to the people on it, attached to their components' requests and never disclosed. offered lists what you may use and your use of it today; every other action is the platform administrator's.",
      title: "Instance Entries"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "create"} = args) do
    params =
      %{
        name: args["name"],
        kind: args["kind"],
        fields: Map.get(args, "fields", %{}),
        audience: args["audience"],
        members: Map.get(args, "members", [])
      }
      |> Prima.MapUtil.put_present(:provider_hint, args["provider_hint"])
      |> Prima.MapUtil.put_present(:destination, args["destination"])
      |> put_given(args, "component_policy", :component_policy)
      |> put_given(args, "person_daily", :person_daily)
      |> put_given(args, "total_daily", :total_daily)

    case InstanceEntries.create(ctx, params) do
      {:ok, entry} -> {:ok, %{entry: entry}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{
        "action" => "rotate",
        "entry_id" => id,
        "fields" => fields,
        "expected_payload_rev" => expected
      })
      when is_binary(id) and is_map(fields) and is_integer(expected) do
    case InstanceEntries.rotate(ctx, %{
           entry_id: id,
           fields: fields,
           expected_payload_rev: expected
         }) do
      {:ok, rev} -> {:ok, %{status: "rotated", entry_id: id, payload_rev: rev}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "rotate"}),
    do: {:error, {:invalid_argument, "rotate requires entry_id, fields and expected_payload_rev"}}

  def handle(%Context{} = ctx, %{"action" => "rebind", "entry_id" => id} = args)
      when is_binary(id) do
    params = Prima.MapUtil.put_present(%{entry_id: id}, :destination, args["destination"])

    case InstanceEntries.rebind(ctx, params) do
      {:ok, result} -> {:ok, Map.merge(%{status: "rebound", entry_id: id}, pairs(result))}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "set_audience", "entry_id" => id} = args)
      when is_binary(id) do
    params = %{entry_id: id, audience: args["audience"], members: Map.get(args, "members", [])}

    case InstanceEntries.set_audience(ctx, params) do
      {:ok, changed} -> {:ok, %{status: "updated", entry_id: id, changed: changed == :changed}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{
        "action" => "set_component_policy",
        "entry_id" => id,
        "component_policy" => policy
      })
      when is_binary(id) do
    case InstanceEntries.set_component_policy(ctx, %{entry_id: id, component_policy: policy}) do
      {:ok, changed} -> {:ok, %{status: "updated", entry_id: id, changed: changed == :changed}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "set_component_policy"}),
    do:
      {:error, {:invalid_argument, "set_component_policy requires entry_id and component_policy"}}

  def handle(%Context{} = ctx, %{"action" => "set_caps", "entry_id" => id} = args)
      when is_binary(id) do
    params =
      %{entry_id: id}
      |> put_given(args, "person_daily", :person_daily)
      |> put_given(args, "total_daily", :total_daily)

    # A call naming neither cap asks for no change: it is refused, so a
    # missing argument is never answered as a write that held.
    if map_size(params) == 1 do
      {:error, {:invalid_argument, "set_caps requires person_daily, total_daily or both"}}
    else
      case InstanceEntries.set_caps(ctx, params) do
        {:ok, changed} -> {:ok, %{status: "updated", entry_id: id, changed: changed == :changed}}
        {:error, reason} -> {:error, fmt(reason)}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "entry_id" => id}) when is_binary(id) do
    case InstanceEntries.revoke(ctx, id) do
      {:ok, result} -> {:ok, Map.merge(%{status: "revoked", entry_id: id}, pairs(result))}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "delete", "entry_id" => id}) when is_binary(id) do
    case InstanceEntries.delete(ctx, id) do
      {:ok, result} -> {:ok, Map.merge(%{status: "deleted", entry_id: id}, pairs(result))}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case InstanceEntries.list(ctx) do
      {:ok, entries} -> {:ok, %{entries: entries}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "usage", "entry_id" => id, "days" => days})
      when is_binary(id) do
    case InstanceEntries.usage(ctx, id, days) do
      {:ok, usage} -> {:ok, Map.put(usage, :entry_id, id)}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "offered"}) do
    case InstanceEntries.offered_with_use(ctx) do
      {:ok, entries} -> {:ok, %{entries: entries}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "people"}) do
    case InstanceEntries.people(ctx) do
      {:ok, people} -> {:ok, %{people: people}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => action})
      when action in ~w(rebind set_audience set_caps revoke delete usage),
      do: {:error, {:invalid_argument, "#{action} requires entry_id"}}

  def handle(_ctx, _args),
    do: {:error, Prima.Provider.invalid_action("instance_entry", action_enum())}

  # ---------------------------------------------------------------------------

  # An argument the caller named, null included: a policy's null is
  # refused rather than read as omitted, and a cap's null takes the
  # platform default rather than keeping the stored value.
  defp put_given(params, args, name, key) do
    case Map.fetch(args, name) do
      {:ok, value} -> Map.put(params, key, value)
      :error -> params
    end
  end

  defp pairs(%{affected: affected} = result) do
    Map.put(
      result,
      :affected,
      for(
        {athanor_id, profile_id} <- affected,
        do: %{athanor_id: athanor_id, profile_id: profile_id}
      )
    )
  end

  # The confirmation signal, whose id the surface confirms, and the typed
  # refusals the gate's vocabulary renders pass as they are.
  defp fmt({tag, payload} = signal) when Prima.ConsentSignal.is_signal(tag, payload), do: signal

  defp fmt(reason)
       when reason in [
              :platform_admin_required,
              :identity_stale,
              :missing_tenant,
              :not_offered,
              :component_not_admitted,
              :destination_mismatch,
              :endpoints_immutable,
              :unavailable
            ],
       do: reason

  defp fmt({:conflict, message} = conflict) when is_binary(message), do: conflict

  defp fmt(:conflict),
    do:
      {:conflict, "conflict: the entry changed since it was read; read it again and decide anew"}

  defp fmt({:connection_cap, _reset_at} = cap), do: cap
  defp fmt(:not_found), do: :not_found

  # The interactive class, refused as the gate refuses it.
  defp fmt({:surface_not_permitted, _method} = refusal), do: {:consent_class_required, refusal}

  defp fmt(refusal)
       when refusal in [:guest_plane, :not_authenticated, :anonymous, :not_standing],
       do: {:consent_class_required, refusal}

  defp fmt(:anonymous_denied), do: {:consent_class_required, :anonymous}

  defp fmt(:name_taken),
    do: {:invalid_argument, "name_taken: a living instance entry holds that name"}

  defp fmt(:name_required), do: {:invalid_argument, "name_required: an entry needs a name"}

  defp fmt({:invalid_kind, kinds}),
    do: {:invalid_argument, "invalid_kind: kind is one of #{Enum.join(kinds, ", ")}"}

  defp fmt(:destination_required),
    do:
      {:invalid_argument,
       "destination_required: an instance entry names where its material may go, " <>
         "its hosts, methods and paths"}

  defp fmt({:invalid_destination, reason}),
    do: {:invalid_argument, "invalid_destination: " <> destination_refusal(reason)}

  defp fmt(:invalid_component_policy),
    do: {:invalid_argument, "invalid_component_policy: component_policy is any or shipped"}

  defp fmt(:invalid_audience),
    do: {:invalid_argument, "invalid_audience: audience is everyone or listed"}

  defp fmt(:invalid_members),
    do: {:invalid_argument, "invalid_members: members are person ids"}

  defp fmt(:invalid_caps),
    do:
      {:invalid_argument,
       "invalid_caps: a cap is a whole number from 0 to #{Arca.InstanceEntries.max_cap()}, " <>
         "or null for the platform default"}

  defp fmt(:invalid_days),
    do:
      {:invalid_argument,
       "invalid_days: days is from 1 to #{Arca.InstanceEntryUsage.kept_days()}"}

  defp fmt(:no_binding_changes),
    do: {:invalid_argument, "no_binding_changes: the destination is the entry's already"}

  defp fmt(:binding_moved),
    do: {:conflict, "binding_moved: the entry was rebound since it was read; retry"}

  defp fmt(:payload_conflict),
    do: {:conflict, "payload_conflict: re-read the entry and retry with its revision"}

  defp fmt(:schema_change_requires_rebind),
    do: {:invalid_argument, "schema_change_requires_rebind: rotate keeps the entry's field names"}

  defp fmt({:kind_unavailable, "oauth"}),
    do:
      {:invalid_argument,
       "kind_unavailable: an instance entry is an API key or a bundle of fields; an OAuth " <>
         "account is entered in an athanor's own vault, since nothing can yet dispense an " <>
         "instance entry's token"}

  defp fmt({:entry_unavailable, status}) when is_binary(status),
    do: {:invalid_argument, "entry_unavailable: the entry is #{status}"}

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

  # An id that names no one is the caller's own input, perhaps any text
  # at all, and is not repeated back: the sentence names the argument.
  defp fmt({:person_unknown, user_id}) when is_binary(user_id),
    do:
      {:invalid_argument,
       "person_unknown: members names someone who has not signed in to this instance; " <>
         "members are the person ids of people who have"}

  defp fmt({:person_denied, user_id}) when is_binary(user_id),
    do:
      {:invalid_argument,
       "person_denied: #{user_id} is denied on this server and cannot be listed; " <>
         "remove them from members"}

  defp fmt(:invalid_provider_hint),
    do: {:invalid_argument, "invalid_provider_hint: provider_hint is a provider tag"}

  defp fmt(reason) when reason in [:entry_required, :invalid_rotation],
    do: {:invalid_argument, "#{reason}: name the entry, and for rotate its fields and revision"}

  defp fmt(:invalid_request),
    do: {:invalid_argument, "invalid_request: the change cannot be confirmed as asked"}

  defp fmt({:invalid_payload, _shape}),
    do: {:invalid_argument, "invalid_fields: fields map names to string values"}

  # A reason this tool has no sentence for is logged by its shape and
  # answered as one word: an internal reason on this surface can carry
  # credential material, and a renderer that inspected it would spell it.
  defp fmt(reason) do
    Logger.warning(
      "[Sanctum.Providers.InstanceEntry] unrenderable reason: " <>
        Prima.LoggerContext.shape(reason)
    )

    {:unavailable, "Instance entries"}
  end

  # The destination grammar's refusal, in fixed words: the offending value
  # is the caller's own input and is not repeated back.
  defp destination_refusal(:not_a_map), do: "it is an object"
  defp destination_refusal(:hosts_required), do: "it names at least one host"
  defp destination_refusal({:unknown_key, _key}), do: "it names an unknown member"
  defp destination_refusal({:invalid_host, _host}), do: "a host is outside the domain grammar"
  defp destination_refusal({:invalid_scheme, _}), do: "the scheme is http or https"
  defp destination_refusal({:invalid_port, _}), do: "the port is 1 to 65535"
  defp destination_refusal({:invalid_method, _}), do: "a method is outside the HTTP vocabulary"
  defp destination_refusal({:invalid_path, _}), do: "a path is outside the path grammar"
  defp destination_refusal({:invalid_list, field}), do: "#{field} is a list"
  defp destination_refusal({:empty, field}), do: "#{field}, when present, is not empty"
  defp destination_refusal({:too_many, field}), do: "#{field} names too many entries"
  defp destination_refusal({:required, field}), do: "#{field} is required"
  defp destination_refusal(_other), do: "it is outside the destination grammar"

  defp action_enum, do: Prima.Provider.action_enum(definition())
end
