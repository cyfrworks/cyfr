# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.InstanceEntries do
  @moduledoc """
  The instance's own credentials: entries the platform administrator
  enters once and offers to the people on the instance, owned by no
  athanor. The rows are `Arca.InstanceEntries`' and the day counts
  `Arca.InstanceEntryUsage`'s; sealing, the audience, the component
  policy, the caps and every confirmation are decided here.

  ## The administrator's verbs

  `create/2`, `rotate/2`, `rebind/2`, `set_audience/2`,
  `set_component_policy/2`, `set_caps/2`, `revoke/2`, `delete/2`,
  `list/1`, `usage/3` and `people/1` each require the operator capability
  (`ctx.platform_admin`, the platform scope the gate already checked;
  `{:error, :platform_admin_required}` otherwise) and the interactive
  consent class (`Sanctum.Consent.Authz.authorize_interactive/1`). The
  rows are written under the platform's system actor; the administrator
  is recorded in `created_by` and in each announcement's `user_id`.

  Entering and rotating material confirm `credential_entry`
  (`Sanctum.Consent.Authz.confirm/3`). Widening who or what may use an
  entry confirms `credential_sharing`: an audience that becomes
  `everyone` or adds a person, and a component policy that moves from
  `shipped` to `any`. Whether a request widens is decided against the
  entry as read, and the write is a compare-and-set on that read
  (`Arca.InstanceEntries.set_audience/4`, `set_component_policy/4`): a
  stored state that moved in between answers `{:error, :conflict}` with
  nothing written and is never retried. An audience's confirmation also
  binds the audience it was decided against, so a proof given over one
  stored audience is asked afresh over another. A widening is therefore
  only ever written over the state it was confirmed against. The confirmation's
  preview names the widening and no value: the audience it becomes or
  how many people it adds, or the policy it moves from and to. Narrowing
  either, an unchanged setting, a rebind, the caps, a revoke and a delete
  need the session alone. A listed id no person has (a typed email
  among them) is refused `{:error, {:person_unknown, user_id}}`, and a
  listed person who is denied on this server
  `{:error, {:person_denied, user_id}}`, each under the listed people's
  locks (`Arca.InstanceEntries`), with nothing written.

  An entry is always attach-only, and its destination
  (`Prima.Destination`) names its methods and paths. Its component
  policy is exactly `any` or `shipped`: omitted at creation it is `any`,
  and null, empty, unknown or collection-valued input is refused.

  A revoke or a delete blocks every profile, in every athanor, whose head
  consent binds the entry, in the store's own transaction
  (`Arca.InstanceEntries.revoke/3`, `tombstone/3`), and answers those
  `{athanor_id, profile_id}` pairs.

  Every durable change announces `[:cyfr, :sanctum, :instance_entry,
  kind]` with the entry id, the kind (`created`, `rotated`, `rebound`,
  `audience`, `policy`, `caps`, `revoked`, `deleted`) and the acting
  person, never a value; a refused or unchanged update announces nothing.

  ## A person's use

  `offered/1` answers the active entries offered to the context's
  person, metadata only, and `offered_with_use/1` the same with the
  person's own count of each one's use today and no other person's.
  `binding/2` answers one of them as a consent binds
  it, with the digest it stands at and nothing unsealed or claimed.
  `binding_facts/1` answers an entry's kind, provider, status and digest
  to a boot's revision that has no person, so it carries a binding only
  while those still hold.
  `resolve/4` is the attach path's read
  (`Sanctum.Attach`): in order, the context's person is active (their own
  row, read first: the audience is a filter), the entry is offered to them
  and active, the running node is admitted by the stored component
  policy (`admits?/3`), the request stays inside the destination, and
  one use is claimed under the day's caps (`Arca.InstanceEntryUsage.claim/4`);
  only then is the material unsealed. Every refusal before the claim
  takes none and unseals nothing. A claim taken stands whatever follows:
  the request was admitted and counted, as a rate window counts a refused
  request.

  An entry's caps are its own (`0` admits no use) or, unset, the platform
  settings `instance_entry_person_daily` and `instance_entry_total_daily`,
  read through `Arca.PlatformSettings.effective/1` at each claim; a
  setting of `0` also admits no use, and no claim is uncapped.

  `sweep_usage/0` deletes the day counts older than
  `Arca.InstanceEntryUsage.kept_days/0`, for `Cyfr.RetentionScheduler`.
  """

  alias Arca.InstanceEntries, as: Store
  alias Arca.InstanceEntryUsage, as: Usage
  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.Components
  alias Sanctum.Context
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  require Logger

  @kinds ~w(api_key bundle)
  @policies ~w(any shipped)
  @audiences ~w(everyone listed)
  @rebind_attempts 3

  # The longest name, provider hint or person id a row holds: the columns
  # are 255 characters on PostgreSQL, so a longer one is refused here, on
  # both adapters, naming its field rather than failing in one driver.
  @max_text 255

  @typedoc "An instance entry as the administrator sees it: metadata, never material."
  @type entry_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          status: String.t(),
          provenance: String.t(),
          field_names: [String.t()],
          oauth_scopes: [String.t()],
          destination: %{String.t() => term()} | nil,
          attach_only: true,
          binding_digest: String.t() | nil,
          payload_rev: non_neg_integer(),
          last_used_at: DateTime.t() | nil,
          audience: String.t(),
          person_daily: non_neg_integer() | nil,
          total_daily: non_neg_integer() | nil,
          component_policy: String.t(),
          created_by: String.t(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc """
  An entry offered to a person: what it reaches and for whom, never
  material. `oauth_scopes` are the scopes an OAuth entry was authorized
  for, `[]` for any other kind.
  """
  @type offer_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          oauth_scopes: [String.t()],
          destination: %{String.t() => term()} | nil,
          component_policy: String.t()
        }

  @typedoc """
  An entry offered to a person, as that person's vault page shows it: its
  offer view and how many times the person used it today
  (`used_today`), never anyone else's count.
  """
  @type offer_use_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          oauth_scopes: [String.t()],
          destination: %{String.t() => term()} | nil,
          component_policy: String.t(),
          used_today: non_neg_integer()
        }

  @typedoc "A person an administrator may list in an audience: an id and a display name."
  @type person_view :: %{id: String.t(), display_name: String.t()}

  @typedoc "An offered entry as a consent binds it: its offer view and the digest it is bound at."
  @type binding_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          oauth_scopes: [String.t()],
          destination: %{String.t() => term()} | nil,
          component_policy: String.t(),
          binding_digest: String.t() | nil
        }

  @typedoc """
  What a carried binding is held to: the entry's kind, provider, status,
  digest and the scopes an OAuth entry was authorized for (`[]` for
  another kind).
  """
  @type binding_facts :: %{
          kind: String.t(),
          provider_hint: String.t(),
          status: String.t(),
          binding_digest: String.t() | nil,
          oauth_scopes: [String.t()]
        }

  @typedoc "The running node's facts, taken from the attempt and never from a request."
  @type execution_facts :: %{node_ref: String.t(), activation_digest: String.t()}

  # ---------------------------------------------------------------------------
  # Read
  # ---------------------------------------------------------------------------

  @doc "Every living instance entry, by name, with its listed members."
  @spec list(Context.t()) :: {:ok, [entry_view()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with :ok <- administer(ctx),
         {:ok, entries} <- Store.list(actor()) do
      {:ok, Enum.map(entries, &Map.put(view(&1), :members, &1.members))}
    end
  end

  @doc """
  An entry's use over the last `days` days, today included: each person's
  count by day and the entry's day totals (`Arca.InstanceEntryUsage.usage/3`).
  `days` is from 1 to `Arca.InstanceEntryUsage.kept_days/0`, the days the
  sweep keeps; any other is `{:error, :invalid_days}` before any read.
  """
  @spec usage(Context.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def usage(%Context{} = ctx, entry_id, days) when is_binary(entry_id) do
    with :ok <- administer(ctx),
         :ok <- usage_days(days) do
      Usage.usage(actor(), entry_id, days)
    end
  end

  @doc """
  The active entries offered to the context's person: those offered to
  `everyone`, and those `listed` with the person among their members.
  Metadata only (`t:offer_view/0`). An anonymous caller is
  `{:error, :anonymous_denied}`.
  """
  @spec offered(Context.t()) :: {:ok, [offer_view()]} | {:error, term()}
  def offered(%Context{} = ctx) do
    with :ok <- person(ctx),
         {:ok, entries} <- Store.offered(Context.actor(ctx), []) do
      {:ok, Enum.map(entries, &offer_view/1)}
    end
  end

  @doc """
  `offered/1`, each entry with the context's person's own count of its
  use today (`used_today`, `Arca.InstanceEntryUsage.used_today/3`, on the
  database's date as a claim counts it): what that person's vault page
  shows. No other person's count and no entry total is read. A count the
  store cannot answer is the read's refusal, never a zero.
  """
  @spec offered_with_use(Context.t()) :: {:ok, [offer_use_view()]} | {:error, term()}
  def offered_with_use(%Context{} = ctx) do
    with {:ok, offers} <- offered(ctx) do
      offers
      |> Enum.reduce_while({:ok, []}, fn offer, {:ok, acc} ->
        case Usage.used_today(actor(), offer.id, ctx.user_id) do
          {:ok, count} -> {:cont, {:ok, [Map.put(offer, :used_today, count) | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, used} -> {:ok, Enum.reverse(used)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  The people who have signed in to this instance and stand `active` on
  it, each as an `id` and a `display_name`
  (`Sanctum.Tenancy.Users.display_name/1`) and nothing more: whom an
  administrator may list in an entry's audience, which can name no one
  else. Someone who has not signed in yet has no person id here and
  cannot be listed. Read under the operator capability, as `usage/3` is,
  and confirms nothing. The people are read in id order, a page at a
  time, each page after the last id of the one before: no one is read
  twice, and everyone with a row before the read began is read. A person
  whose row appears during the read is read when their id sorts after
  the last page already read (a new person's time-ordered id does), and
  otherwise on the next read; an administrator's save never drops anyone
  it did not read, since it sends only its own edit. A page the store
  cannot read is `{:error, :unavailable}`, never a shorter list.
  """
  @spec people(Context.t()) :: {:ok, [person_view()]} | {:error, term()}
  def people(%Context{} = ctx) do
    with :ok <- administer(ctx) do
      people_after(nil, [])
    end
  end

  # Every page of `Sanctum.Tenancy.Users.list_by_id/1`, in id order, each
  # after the last id of the one before, so no one is read twice and no
  # one whose row predates the read is skipped; a page short of the limit
  # is the last one. A person not active is left out. A page the store
  # cannot read fails the whole read: an audience is never offered a
  # partial or empty list for an outage.
  defp people_after(after_id, acc) do
    page = Arca.Users.max_page()

    case Sanctum.Tenancy.Users.list_by_id(limit: page, after: after_id) do
      {:ok, users} ->
        acc =
          acc ++
            for %{status: "active"} = user <- users,
                do: %{id: user.id, display_name: Sanctum.Tenancy.Users.display_name(user.id)}

        if length(users) < page,
          do: {:ok, acc},
          else: people_after(List.last(users).id, acc)

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.InstanceEntries] people could not be read: " <>
            Prima.LoggerContext.shape(reason)
        )

        {:error, :unavailable}
    end
  end

  @doc """
  The entry `entry_id` as a consent binds it for the context's person:
  its offer view (`t:offer_view/0`) with the binding digest it stands at
  (`t:binding_view/0`). The refusals are `resolve/4`'s, in its order, up
  to the status: an anonymous caller (`{:error, :anonymous_denied}`), a
  person not active on this server (`{:error, :denied}`), an entry not
  offered to them (`{:error, :not_offered}`) and one offered but not
  active (`{:error, {:entry_unavailable, status}}`). Nothing is unsealed
  and no use is claimed: whether a node may use the entry is the
  component policy's (`admits?/3`), and a request's is the attach path's.
  """
  @spec binding(Context.t(), String.t()) :: {:ok, binding_view()} | {:error, term()}
  def binding(%Context{} = ctx, entry_id) when is_binary(entry_id) do
    with :ok <- person(ctx),
         :ok <- standing(ctx.user_id),
         {:ok, entry} <- Store.get_offered(Context.actor(ctx), entry_id, active_only: false),
         :ok <- active(entry) do
      {:ok, Map.put(offer_view(entry), :binding_digest, entry.binding_digest)}
    end
  end

  @doc """
  The facts a boot's revision with no person holds a carried instance
  binding to (`Sanctum.Consent.Bootstrap`, its only caller): the entry's
  `kind`, `provider_hint`, `status`, stored `binding_digest` and
  `oauth_scopes`, read under the platform's actor, or
  `{:error, :not_found}`. Metadata only:
  it unseals nothing, offers nothing and names no person, so it decides
  no one's use; the attach path (`resolve/4`) holds each request to the
  audience, the policy and the caps.
  """
  @spec binding_facts(String.t()) :: {:ok, binding_facts()} | {:error, term()}
  def binding_facts(entry_id) when is_binary(entry_id) do
    with {:ok, entry} <- Store.get(actor(), entry_id) do
      {:ok,
       entry
       |> Map.take([:kind, :provider_hint, :status, :binding_digest])
       |> Map.put(
         :oauth_scopes,
         if(entry.kind == "oauth", do: decode_list(entry.oauth_scopes), else: [])
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Create, rotate, rebind
  # ---------------------------------------------------------------------------

  @doc """
  Create an instance entry. `params`:

    * `:name` (required) — unique among living instance entries
    * `:kind` (required) — `"api_key" | "bundle"`. An `oauth` entry is
      refused `{:kind_unavailable, "oauth"}`: nothing can dispense an
      instance entry's token, since an OAuth dispense refreshes under an
      athanor's actor and storage
    * `:fields` — `%{name => value}` material (default empty)
    * `:provider_hint` — immutable; defaults `""`
    * `:destination` (required) — a `Prima.Destination` map naming its
      `methods` and `paths`
    * `:audience` (required) — `"everyone"` or `"listed"`; `:members`, the
      listed person ids (an `everyone` audience keeps none)
    * `:component_policy` — `"any"` or `"shipped"`; omitted is `"any"`
    * `:person_daily` / `:total_daily` — the entry's own caps, integers
      from 0 to `Arca.InstanceEntries.max_cap/0`, or nil (unset,
      taking the platform setting's default)

  Every argument is held to its rule before the confirmation is asked;
  the entry is then sealed under `Sanctum.CipherAAD.instance_entry/2`
  and written. Confirms `credential_entry`.
  """
  @spec create(Context.t(), map()) :: {:ok, entry_view()} | {:error, term()}
  def create(%Context{} = ctx, params) when is_map(params) do
    fields = Map.get(params, :fields, %{})

    with :ok <- administer(ctx),
         {:ok, name} <- required_name(params),
         {:ok, kind} <- required_kind(params),
         {:ok, hint} <- provider_hint(params),
         {:ok, destination} <- required_destination(params),
         {:ok, policy} <- create_policy(params),
         {:ok, audience, members} <- audience_change(params),
         {:ok, caps} <- create_caps(params),
         {:ok, json} <- Payload.encode_material(fields, nil),
         :ok <-
           Authz.confirm(ctx, :credential_entry, %{
             operation: "instance_entry.create",
             arguments: params,
             resource: name
           }),
         id = Prima.UUID7.generate_id("ine"),
         {:ok, sealed} <- seal(json, CipherAAD.instance_entry(id, hint)) do
      binding = %{
        provider_hint: hint,
        field_names: Jason.encode!(Enum.sort(Map.keys(fields))),
        oauth_endpoints: nil,
        oauth_scopes: nil,
        destination: destination,
        attach_only: true
      }

      with {:ok, digest} <- VaultReader.binding_digest(binding),
           {:ok, entry} <-
             Store.put(
               actor(),
               Map.merge(binding, %{
                 id: id,
                 name: name,
                 kind: kind,
                 provenance: "user",
                 status: "active",
                 sealed_payload: sealed,
                 binding_digest: digest,
                 audience: audience,
                 component_policy: policy,
                 person_daily: caps.person_daily,
                 total_daily: caps.total_daily,
                 created_by: ctx.user_id
               }),
               members
             ) do
        announce(ctx, :created, entry.id)
        {:ok, view(entry)}
      end
    end
  end

  @doc """
  Replace an entry's material under the `payload_rev` the caller read
  (`params`: `:entry_id`, `:fields`, `:expected_payload_rev`). The field
  schema must be the entry's; changing it is not a rotation. An entry
  awaiting re-authorization is reactivated with its new material; a
  revoked or tombstoned one is never brought back. Confirms
  `credential_entry`.
  """
  @spec rotate(Context.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rotate(
        %Context{} = ctx,
        %{entry_id: id, fields: fields, expected_payload_rev: expected} = params
      )
      when is_binary(id) and is_map(fields) and is_integer(expected) do
    with :ok <- administer(ctx),
         {:ok, entry} <- rotatable(id),
         :ok <- expected_revision(entry, expected),
         :ok <- check_schema(entry, fields),
         :ok <-
           Authz.confirm(ctx, :credential_entry, %{
             operation: "instance_entry.rotate",
             arguments: params,
             resource: entry.name
           }),
         {:ok, current} <- unseal(entry),
         {:ok, json} <- Payload.encode_material(fields, current["oauth"]),
         {:ok, sealed} <- seal(json, CipherAAD.instance_entry(entry.id, entry.provider_hint)),
         {:ok, %{payload_rev: rev}} <-
           Store.commit_payload(actor(), id, %{
             expected_rev: expected,
             sealed_payload: sealed,
             status: if(entry.status == "needs_reauth", do: "active")
           }) do
      announce(ctx, :rotated, id)
      {:ok, rev}
    end
  end

  def rotate(%Context{}, _params), do: {:error, :invalid_rotation}

  # A rotation is decided against the revision its caller read: the stored
  # OAuth block is merged only into that revision, and a moved one is a
  # conflict before anything is confirmed, unsealed or merged.
  defp expected_revision(%{payload_rev: rev}, rev), do: :ok
  defp expected_revision(_entry, _expected), do: {:error, :payload_conflict}

  @doc """
  Move an entry's destination (`params`: `:entry_id`, `:destination`, a
  `Prima.Destination` map naming its methods and paths). The binding
  digest moves with it and every profile whose head binds the entry is
  blocked until its person consents again, in the store's transaction.
  An unchanged destination is `{:error, :no_binding_changes}`. Answers
  the new digest and the blocked `{athanor_id, profile_id}` pairs.
  """
  @spec rebind(Context.t(), map()) ::
          {:ok, %{binding_digest: String.t(), affected: [{String.t(), String.t()}]}}
          | {:error, term()}
  def rebind(%Context{} = ctx, %{entry_id: id} = params) when is_binary(id) do
    with :ok <- administer(ctx),
         {:ok, destination} <- required_destination(params),
         {:ok, entry} <- living(id) do
      if destination == entry.destination do
        {:error, :no_binding_changes}
      else
        with {:ok, rebound} <- move(entry, destination, @rebind_attempts) do
          announce(ctx, :rebound, id)
          {:ok, rebound}
        end
      end
    end
  end

  def rebind(%Context{}, _params), do: {:error, :entry_required}

  # A rebind that lost the race recomputes against what landed.
  defp move(entry, destination, attempts) do
    with {:ok, digest} <-
           VaultReader.binding_digest(%{entry | destination: destination}) do
      case Store.move_binding(
             actor(),
             entry.id,
             entry.binding_digest,
             %{destination: destination, binding_digest: digest},
             Sanctum.Vault.blocked_profile_status()
           ) do
        {:ok, affected} ->
          {:ok, %{binding_digest: digest, affected: affected}}

        {:error, :binding_moved} when attempts > 1 ->
          with {:ok, fresh} <- living(entry.id), do: move(fresh, destination, attempts - 1)

        {:error, _} = error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Audience, policy, caps
  # ---------------------------------------------------------------------------

  @doc """
  Set who an entry is offered to (`params`: `:entry_id`, `:audience`
  `everyone` or `listed`, and for `listed` the `:members`, person ids).
  Read against the stored audience: a change that makes it `everyone` or
  adds a person confirms `credential_sharing`; a narrowing needs the
  session. An unchanged audience writes and announces nothing. The write
  is conditional on the audience read, and a moved one is
  `{:error, :conflict}`, never retried.

  The confirmation binds the audience it was decided against (`read`,
  its `audience` and sorted `members`) beside the change, so a proof
  given over one stored audience never writes over another: when the
  stored audience moved between the proof and its repeat, the repeat is
  asked afresh.
  """
  @spec set_audience(Context.t(), map()) ::
          {:ok, :changed | :unchanged} | {:error, term()}
  def set_audience(%Context{} = ctx, %{entry_id: id} = params) when is_binary(id) do
    with :ok <- administer(ctx),
         {:ok, audience, members} <- audience_change(params),
         {:ok, entry, held} <- with_members(id) do
      requested = %{audience: audience, members: members}

      cond do
        same_audience?(held, requested) ->
          {:ok, :unchanged}

        widens?(held, requested) ->
          with :ok <-
                 Authz.confirm(ctx, :credential_sharing, %{
                   operation: "instance_entry.set_audience",
                   arguments: %{
                     entry_id: id,
                     audience: audience,
                     members: members,
                     read: %{audience: held.audience, members: Enum.sort(held.members)}
                   },
                   resource: entry.name,
                   details: widening(held, requested)
                 }),
               do: write_audience(ctx, id, held, requested)

        true ->
          write_audience(ctx, id, held, requested)
      end
    end
  end

  def set_audience(%Context{}, _params), do: {:error, :entry_required}

  defp write_audience(ctx, id, held, requested) do
    with :ok <- Store.set_audience(actor(), id, held, requested) do
      announce(ctx, :audience, id)
      {:ok, :changed}
    end
  end

  @doc """
  Set an entry's component policy (`params`: `:entry_id`,
  `:component_policy`, exactly `any` or `shipped`). Read against the
  stored policy: `shipped` → `any` confirms `credential_sharing`;
  `any` → `shipped` and an unchanged policy need the session, and an
  unchanged one announces nothing. The write is the store's
  compare-and-set on the policy read, and a moved one is
  `{:error, :conflict}`, never retried.
  """
  @spec set_component_policy(Context.t(), map()) ::
          {:ok, :changed | :unchanged} | {:error, term()}
  def set_component_policy(%Context{} = ctx, %{entry_id: id} = params) when is_binary(id) do
    with :ok <- administer(ctx),
         {:ok, policy} <- policy_value(Map.fetch(params, :component_policy)),
         {:ok, entry} <- living(id) do
      stored = entry.component_policy

      cond do
        stored == policy ->
          with :ok <- Store.set_component_policy(actor(), id, stored, policy),
               do: {:ok, :unchanged}

        policy == "any" ->
          with :ok <-
                 Authz.confirm(ctx, :credential_sharing, %{
                   operation: "instance_entry.set_component_policy",
                   arguments: %{entry_id: id, component_policy: policy},
                   resource: entry.name,
                   details: %{"component_policy" => "#{stored} → #{policy}"}
                 }),
               do: write_policy(ctx, id, stored, policy)

        true ->
          write_policy(ctx, id, stored, policy)
      end
    end
  end

  def set_component_policy(%Context{}, _params), do: {:error, :entry_required}

  defp write_policy(ctx, id, stored, policy) do
    with :ok <- Store.set_component_policy(actor(), id, stored, policy) do
      announce(ctx, :policy, id)
      {:ok, :changed}
    end
  end

  @doc """
  Set an entry's daily caps (`params`: `:entry_id`, and either of
  `:person_daily` and `:total_daily`): an integer from 0 to
  `Arca.InstanceEntries.max_cap/0`, `0` admitting no use, or nil
  for unset, taking the platform setting's default. Only the caps the
  params name are written, so a cap they do not name keeps whatever is
  stored when the write lands. Caps that are already as named write and
  announce nothing.
  """
  @spec set_caps(Context.t(), map()) :: {:ok, :changed | :unchanged} | {:error, term()}
  def set_caps(%Context{} = ctx, %{entry_id: id} = params) when is_binary(id) do
    named = Map.take(params, [:person_daily, :total_daily])

    with :ok <- administer(ctx),
         :ok <- caps_valid(named),
         {:ok, entry} <- living(id) do
      stored = %{person_daily: entry.person_daily, total_daily: entry.total_daily}

      # Only the named caps are written, in one statement: a concurrent
      # write to the other cap stands.
      if Map.take(stored, Map.keys(named)) == named do
        {:ok, :unchanged}
      else
        with :ok <- Store.set_caps(actor(), id, named) do
          announce(ctx, :caps, id)
          {:ok, :changed}
        end
      end
    end
  end

  def set_caps(%Context{}, _params), do: {:error, :entry_required}

  # ---------------------------------------------------------------------------
  # Revoke, delete
  # ---------------------------------------------------------------------------

  @doc """
  Revoke an entry: the next attach through it is refused, and every
  profile, in every athanor, whose head binds it is blocked in the same
  transaction. A revoke of an entry already revoked blocks again, so a
  retry finishes the job. Answers the blocked `{athanor_id, profile_id}`
  pairs.
  """
  @spec revoke(Context.t(), String.t()) ::
          {:ok, %{affected: [{String.t(), String.t()}]}} | {:error, term()}
  def revoke(%Context{} = ctx, id) when is_binary(id) do
    with :ok <- administer(ctx),
         {:ok, affected} <- Store.revoke(actor(), id, Sanctum.Vault.blocked_profile_status()) do
      announce(ctx, :revoked, id)
      {:ok, %{affected: affected}}
    end
  end

  @doc """
  Delete an entry: its material is erased, every athanor's default naming
  it removed and every profile whose head binds it blocked, in one
  transaction. The name is free again. A delete of an entry already
  deleted blocks again. Answers the blocked `{athanor_id, profile_id}`
  pairs.
  """
  @spec delete(Context.t(), String.t()) ::
          {:ok, %{affected: [{String.t(), String.t()}]}} | {:error, term()}
  def delete(%Context{} = ctx, id) when is_binary(id) do
    with :ok <- administer(ctx),
         {:ok, affected} <-
           Store.tombstone(actor(), id, Sanctum.Vault.blocked_profile_status()) do
      announce(ctx, :deleted, id)
      {:ok, %{affected: affected}}
    end
  end

  # ---------------------------------------------------------------------------
  # The attach path
  # ---------------------------------------------------------------------------

  @doc """
  Whether the stored component policy of `entry` admits the running node
  `facts` names, read under `ctx` (`t:execution_facts/0`). `any` admits
  every node: it imposes no provenance restriction. `shipped` admits a
  node only when its component, read through `Sanctum.Consent.Components`
  at the version `node_ref` names, is one the install media ships at
  exactly `activation_digest` (`Components.shipped_nodes/2`). Missing or
  unreadable facts, an uninstalled component port, a mismatched digest
  and a stored policy that is neither word admit nothing.
  """
  @spec admits?(Context.t(), map(), execution_facts() | term()) :: boolean()
  def admits?(%Context{}, %{component_policy: "any"}, _facts), do: true

  def admits?(
        %Context{} = ctx,
        %{component_policy: "shipped"},
        %{node_ref: node_ref, activation_digest: digest}
      )
      when is_binary(node_ref) and is_binary(digest) and digest != "" do
    with {:ok, ref} <- Prima.ComponentRef.parse(node_ref),
         {:ok, row} <-
           Components.get_component(ctx, ref.name, ref.version, ref.namespace, ref.type),
         {:ok, shipped} <- Components.shipped_nodes(ctx, [row]) do
      Map.get(shipped, Prima.ComponentRow.node_key(row)) == digest
    else
      _missing_or_unreadable -> false
    end
  end

  def admits?(%Context{}, _entry, _facts), do: false

  @doc """
  Resolve the instance entry `entry_id` for one attached request:
  `request` names its `uri` (`%URI{}`) and `method`, and `facts` the
  running node (`t:execution_facts/0`), taken from the attempt.

  In order: the context's person is active on this server, read from
  their own row before any audience (`{:error, :denied}` for one denied
  or with no row); the entry is offered to them (`{:error, :not_offered}`)
  and active (`{:error, {:entry_unavailable, status}}`); the stored component policy admits the node (`admits?/3`,
  `{:error, :component_not_admitted}`); the request stays inside the
  entry's destination (`{:error, :destination_mismatch}`); and one use is
  claimed under the entry's caps or, unset, the settings' defaults
  (`{:error, {:connection_cap, reset_at}}`). Each refusal before the
  claim takes none and unseals nothing. Then the material is unsealed
  (`{:error, :unseal_failed}` when it does not open, with the claim
  standing).

  Answers the entry's metadata and its decoded payload
  (`Sanctum.Vault.Payload`), as `Sanctum.VaultReader` answers an
  athanor's entry.
  """
  @spec resolve(Context.t(), String.t(), %{uri: URI.t(), method: term()}, term()) ::
          {:ok, entry_view(), Payload.t()} | {:error, term()}
  def resolve(%Context{} = ctx, entry_id, %{uri: %URI{} = uri, method: method}, facts)
      when is_binary(entry_id) do
    with :ok <- person(ctx),
         :ok <- standing(ctx.user_id),
         {:ok, entry} <- Store.get_offered(Context.actor(ctx), entry_id, active_only: false),
         :ok <- active(entry),
         :ok <- admitted(ctx, entry, facts),
         :ok <- inside(entry, uri, method),
         {:ok, caps} <- caps(entry),
         {:ok, _claimed} <- Usage.claim(actor(), entry.id, ctx.user_id, caps),
         {:ok, payload} <- unseal(entry) do
      _ = Store.touch_last_used(actor(), entry.id)
      {:ok, view(entry), payload}
    end
  end

  @doc """
  Delete the day counts older than `Arca.InstanceEntryUsage.kept_days/0`
  under the platform's system actor, naming no entry and no person.
  Answers how many went.
  """
  @spec sweep_usage() :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_usage, do: Usage.sweep(actor())

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # The store's writes run under the platform's system actor: an instance
  # entry is no athanor's, and the operator capability was checked above.
  defp actor, do: Prima.Actor.system()

  defp administer(%Context{platform_admin: true} = ctx) do
    case Authz.authorize_interactive(ctx) do
      {:ok, :interactive} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp administer(%Context{}), do: {:error, :platform_admin_required}

  defp person(%Context{anonymous: true}), do: {:error, :anonymous_denied}
  defp person(%Context{authenticated: false}), do: {:error, :anonymous_denied}
  defp person(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "", do: :ok
  defp person(%Context{}), do: {:error, :not_offered}

  # The person's own standing, read before the audience: the audience is
  # a filter, and a member row a denial raced past must admit no one. A
  # person not active, or with no person row, is refused; a store that
  # cannot answer refuses too.
  defp standing(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{status: "active"}} -> :ok
      {:ok, _not_active} -> {:error, :denied}
      {:error, :not_found} -> {:error, :denied}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp active(%{status: "active"}), do: :ok
  defp active(%{status: status}), do: {:error, {:entry_unavailable, status}}

  defp admitted(ctx, entry, facts) do
    if admits?(ctx, entry, facts), do: :ok, else: {:error, :component_not_admitted}
  end

  defp inside(entry, uri, method) do
    with text when is_binary(text) <- entry.destination,
         {:ok, %{} = map} <- Prima.Json.decode(text),
         {:ok, destination} <- Prima.Destination.new(map, true),
         true <- Prima.Destination.matches?(destination, uri, method) do
      :ok
    else
      _outside_or_unreadable -> {:error, :destination_mismatch}
    end
  end

  # Each cap the entry's own, or unset, its platform setting's default. A
  # setting the store cannot answer refuses the claim rather than reading
  # as no cap.
  defp caps(entry) do
    with {:ok, person} <- cap(entry.person_daily, "instance_entry_person_daily"),
         {:ok, total} <- cap(entry.total_daily, "instance_entry_total_daily") do
      {:ok, %{person_daily: person, total_daily: total}}
    end
  end

  defp cap(own, _setting) when is_integer(own), do: {:ok, own}

  defp cap(nil, setting) do
    case Arca.PlatformSettings.effective(setting) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      other ->
        Logger.warning(
          "[Sanctum.InstanceEntries] #{setting} could not be read " <>
            Prima.LoggerContext.shape(other) <> "; refusing the claim"
        )

        {:error, :unavailable}
    end
  end

  defp living(id) do
    case Store.get(actor(), id) do
      {:ok, %{status: "tombstoned"}} -> {:error, :not_found}
      other -> other
    end
  end

  # The entry with its listed members, as the audience a compare-and-set
  # is decided against.
  defp with_members(id) do
    with {:ok, entries} <- Store.list(actor()) do
      case Enum.find(entries, &(&1.id == id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry, %{audience: entry.audience, members: entry.members}}
      end
    end
  end

  defp rotatable(id) do
    case Store.get(actor(), id) do
      {:ok, %{status: status} = entry} when status in ["active", "needs_reauth"] ->
        {:ok, entry}

      {:ok, %{status: "tombstoned"}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:entry_unavailable, status}}

      other ->
        other
    end
  end

  defp check_schema(entry, fields) do
    if Enum.sort(Map.keys(fields)) == decode_list(entry.field_names),
      do: :ok,
      else: {:error, :schema_change_requires_rebind}
  end

  defp required_name(%{name: name}) when is_binary(name) and name != "",
    do: bounded(:name, name)

  defp required_name(_params), do: {:error, :name_required}

  defp bounded(field, text) do
    if code_points(text) <= @max_text,
      do: {:ok, text},
      else: {:error, {:invalid, %{field => ["is at most #{@max_text} characters"]}}}
  end

  # The columns' bound is PostgreSQL's `varchar(255)`, which counts code
  # points: a grapheme of a letter and a combining mark is two.
  defp code_points(text), do: text |> String.codepoints() |> length()

  defp required_kind(%{kind: "oauth"}), do: {:error, {:kind_unavailable, "oauth"}}
  defp required_kind(%{kind: kind}) when kind in @kinds, do: {:ok, kind}
  defp required_kind(_params), do: {:error, {:invalid_kind, @kinds}}

  # The provider an entry is for, immutable once created: it is in the
  # AAD. None is the empty hint.
  defp provider_hint(params) do
    case Map.get(params, :provider_hint) do
      nil -> {:ok, ""}
      hint when is_binary(hint) -> bounded(:provider_hint, hint)
      _other -> {:error, :invalid_provider_hint}
    end
  end

  # An instance entry's destination names its methods and paths, and is
  # stored as the destination's canonical text, the bytes its binding
  # digest covers.
  defp required_destination(params) do
    case Map.fetch(params, :destination) do
      {:ok, %{} = destination} when not is_struct(destination) ->
        with {:ok, parsed} <- Prima.Destination.new(string_keys(destination), true) do
          {:ok, Prima.Destination.canonical(parsed)}
        end

      {:ok, nil} ->
        {:error, :destination_required}

      {:ok, _other} ->
        {:error, {:invalid_destination, :not_a_map}}

      :error ->
        {:error, :destination_required}
    end
  end

  # Only omission takes `any`; anything present is one of the two words.
  defp create_policy(params) do
    case Map.fetch(params, :component_policy) do
      :error -> {:ok, "any"}
      present -> policy_value(present)
    end
  end

  defp policy_value({:ok, policy}) when is_binary(policy) and policy in @policies,
    do: {:ok, policy}

  defp policy_value(_absent_or_other), do: {:error, :invalid_component_policy}

  # The audience a request names, its members de-duplicated and sorted:
  # the form the confirmation binds and the store compares. An `everyone`
  # audience keeps no list.
  defp audience_change(params) do
    audience = Map.get(params, :audience)
    members = Map.get(params, :members, [])

    cond do
      audience not in @audiences ->
        {:error, :invalid_audience}

      not (is_list(members) and Enum.all?(members, &(is_binary(&1) and &1 != ""))) ->
        {:error, :invalid_members}

      Enum.any?(members, &(code_points(&1) > @max_text)) ->
        {:error, {:invalid, %{members: ["are person ids of at most #{@max_text} characters"]}}}

      audience == "everyone" ->
        {:ok, "everyone", []}

      true ->
        {:ok, "listed", members |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp same_audience?(held, requested) do
    held.audience == requested.audience and
      MapSet.new(held.members) == MapSet.new(requested.members)
  end

  # What a person proving a widening is shown: the audience it becomes,
  # or how many people it adds. Never who, and never a value.
  defp widening(_held, %{audience: "everyone"}), do: %{"audience" => "everyone"}

  defp widening(%{members: held}, %{audience: "listed", members: requested}) do
    added = MapSet.size(MapSet.difference(MapSet.new(requested), MapSet.new(held)))
    %{"audience" => "listed", "people_added" => Integer.to_string(added)}
  end

  # Widening: the audience becomes everyone, or a person is added.
  defp widens?(%{audience: "everyone"}, _requested), do: false
  defp widens?(_held, %{audience: "everyone"}), do: true

  defp widens?(%{members: held}, %{members: requested}),
    do: not MapSet.subset?(MapSet.new(requested), MapSet.new(held))

  defp create_caps(params) do
    caps = Map.take(params, [:person_daily, :total_daily])

    with :ok <- caps_valid(caps) do
      {:ok,
       %{person_daily: Map.get(caps, :person_daily), total_daily: Map.get(caps, :total_daily)}}
    end
  end

  defp caps_valid(caps) do
    max = Store.max_cap()

    if Enum.all?(caps, fn {_key, cap} -> is_nil(cap) or (is_integer(cap) and cap in 0..max) end),
      do: :ok,
      else: {:error, :invalid_caps}
  end

  defp usage_days(days) when is_integer(days) and days >= 1 do
    if days <= Usage.kept_days(), do: :ok, else: {:error, :invalid_days}
  end

  defp usage_days(_days), do: {:error, :invalid_days}

  # `Sanctum.Cipher.encrypt/2` raises on a keyring that went wrong under a
  # running node; the request answers a typed refusal instead.
  defp seal(json, aad) do
    Sanctum.Cipher.encrypt(json, aad)
  rescue
    e ->
      Logger.error("[Sanctum.InstanceEntries] sealing failed: #{Exception.message(e)}")
      {:error, :seal_failed}
  end

  # The AAD is the entry's id and provider hint: a row that reached here
  # carrying another entry's ciphertext fails to open.
  defp unseal(entry) do
    aad = CipherAAD.instance_entry(entry.id, entry.provider_hint)

    with sealed when is_binary(sealed) <- entry.sealed_payload,
         {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad),
         {:ok, payload} <- Payload.decode(plaintext) do
      {:ok, payload}
    else
      _ -> {:error, :unseal_failed}
    end
  end

  # One literal event per kind: the telemetry catalog reads them from here.
  defp announce(ctx, :created, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :created], ctx, :created, id)

  defp announce(ctx, :rotated, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :rotated], ctx, :rotated, id)

  defp announce(ctx, :rebound, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :rebound], ctx, :rebound, id)

  defp announce(ctx, :audience, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :audience], ctx, :audience, id)

  defp announce(ctx, :policy, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :policy], ctx, :policy, id)

  defp announce(ctx, :caps, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :caps], ctx, :caps, id)

  defp announce(ctx, :revoked, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :revoked], ctx, :revoked, id)

  defp announce(ctx, :deleted, id),
    do: emit([:cyfr, :sanctum, :instance_entry, :deleted], ctx, :deleted, id)

  # The entry, the kind and who acted: never a name, a field or a value.
  defp emit(event, ctx, kind, id),
    do: :telemetry.execute(event, %{count: 1}, %{entry_id: id, kind: kind, user_id: ctx.user_id})

  defp view(entry) do
    %{
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      provider_hint: entry.provider_hint,
      status: entry.status,
      provenance: entry.provenance,
      field_names: decode_list(entry.field_names),
      oauth_scopes: decode_list(entry.oauth_scopes),
      destination: decode_destination(entry.destination),
      attach_only: true,
      binding_digest: entry.binding_digest,
      payload_rev: entry.payload_rev,
      last_used_at: entry.last_used_at,
      audience: entry.audience,
      person_daily: entry.person_daily,
      total_daily: entry.total_daily,
      component_policy: entry.component_policy,
      created_by: entry.created_by,
      created_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  defp offer_view(entry) do
    %{
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      provider_hint: entry.provider_hint,
      oauth_scopes: if(entry.kind == "oauth", do: decode_list(entry.oauth_scopes), else: []),
      destination: decode_destination(entry.destination),
      component_policy: entry.component_policy
    }
  end

  defp decode_destination(text) when is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, %{} = destination} -> destination
      _ -> nil
    end
  end

  defp decode_destination(_absent), do: nil

  defp decode_list(json) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, list} when is_list(list) -> list |> Enum.filter(&is_binary/1) |> Enum.sort()
      _ -> []
    end
  end

  defp decode_list(_absent), do: []

  defp string_keys(map),
    do:
      Map.new(map, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)
end
