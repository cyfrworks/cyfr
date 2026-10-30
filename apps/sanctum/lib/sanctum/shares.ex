# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Shares do
  @moduledoc """
  The rules of sharing a key: one attach-only entry of a person's own
  athanor offered to an audience, `everyone` or the active members of one
  group, with the owner's caps. The rows are `Arca.Shares`' and the day
  counts `Arca.ShareUsage`'s; who may share, who may bind, and every
  confirmation are decided here. A share holds no material: every reader
  reaches its source entry through it, and only while its owner stands.

  This is the one module that reads across athanors for a share. Each
  crossing is one of the store's named reads, by the key it is asked
  for: `Arca.Shares.offered_to/2` (the shares whose audience holds the
  person), `Arca.Shares.member?/3` (one group membership, read at use),
  `Arca.Shares.get_for_source/2` (one share and its source, by the id a
  binding names) and `Arca.Shares.administrator_shares/1` (a first
  sign-in's candidates). The use count and the unseal read the owner's
  rows under the owner's own internal context (`owner_context/1`, the
  one place that context is built for a share), every query scoped to
  the owner's athanor.

  ## The owner's verbs

  `create/2`, `set_audience/2`, `set_caps/2` and `revoke/2` are writes,
  made from the person's own athanor (`{:error, :not_own_athanor}`
  otherwise) on the interactive consent class
  (`Sanctum.Consent.Authz.authorize_interactive/1`). Creating a share and
  widening its audience, from a group to everyone or to another group,
  confirm `credential_sharing`; a creation spends its confirmation in the
  store's transaction (`Arca.Shares.create/3`), under the locks it takes,
  so the proof and the share commit together. A narrowing, an unchanged
  audience, the caps and a revoke need the session alone. `list/1` and
  `usage/3` are the owner's reads.

  Caps are the share's own, per person and in total per day: absent is
  no limit, `0` admits no use and `N` at most `N` that day
  (`Arca.Schemas.Share.max_cap/0`). There is no platform default, and no
  component policy: any component the recipient grants may use the key,
  and the entry's destination is the one bound on where it goes.

  ## A person's use

  `binding/2` answers one share as a consent binds it for the context's
  person, and `offered/1` every share offered to them, each with the
  owner's display name and the source entry's binding facts, never its
  name or material. A share answers only while it is active, its audience
  includes the person (everyone, or an active member of an active group,
  read now), the person is not its owner, the person and the owner stand
  (`Sanctum.Caller.stands?/1`), and the source is active and attach-only.
  `binding_facts/1` answers the source's facts for any active share to a
  boot's revision that has no person, and `administrator_shares/1` the
  shares to everyone of the platform administrator a first sign-in binds
  from.

  `resolve/5` is the attach path's read (`Sanctum.Attach`), in the order
  its doc gives, nothing counted or unsealed before a check that refuses.

  ## Announcements

  Every durable change announces `[:cyfr, :sanctum, :share, kind]` with
  the share id, the kind (`kinds/0`) and the acting person, never a value
  or an audience; a refused or unchanged write announces nothing.
  """

  alias Arca.ShareUsage, as: Usage
  alias Arca.Shares, as: Store
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.VaultReader

  @kinds [:created, :audience, :caps, :rebound, :rotated, :revoked]

  # What an audience change meets when the stored audience is not the one
  # its caller saw: `Prima.Refusal` keeps the sentence.
  @audience_conflict "The audience changed since it was shown, so nothing was saved."

  @typedoc "What a share announces happened to it."
  @type kind :: :created | :audience | :caps | :rebound | :rotated | :revoked

  @typedoc "A share as its owner sees it, with today's total use. It holds no material."
  @type share_view :: %{
          id: String.t(),
          entry_id: String.t(),
          audience: String.t(),
          group_id: String.t() | nil,
          person_daily: non_neg_integer() | nil,
          total_daily: non_neg_integer() | nil,
          status: String.t(),
          used_today: non_neg_integer(),
          created_at: DateTime.t() | nil
        }

  @typedoc """
  A share as a consent binds it for a person: the source entry's binding
  facts, the digest derived from them, and the owner's display name. No
  name of the entry and no material.
  """
  @type binding_view :: %{
          id: String.t(),
          owner: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          field_names: [String.t()],
          destination: %{String.t() => term()} | nil,
          binding_digest: String.t(),
          status: String.t(),
          attach_only: true
        }

  @typedoc "What a carried binding with no person is held to: the source's facts."
  @type binding_facts :: %{
          kind: String.t(),
          provider_hint: String.t(),
          field_names: [String.t()],
          status: String.t(),
          binding_digest: String.t(),
          attach_only: true
        }

  @typedoc "An audience as a write names it."
  @type audience :: %{audience: String.t(), group_id: String.t() | nil}

  @doc "The kinds a share announces, the one list the bus payload and the telemetry catalog read."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  # ---------------------------------------------------------------------------
  # The owner's verbs
  # ---------------------------------------------------------------------------

  @doc """
  Share the entry `params.entry_id` of the context's own athanor with
  `params.audience`, `"everyone"` or `"group"` with `params.group_id`, a
  group the person is an active member of, and the optional caps
  `params.person_daily` and `params.total_daily`, each absent for no
  limit. The entry is active, attach-only, of a kind in
  `Prima.CredentialKinds.shareable/0` and has a destination naming its
  methods and paths; the store's refusals are `Arca.Shares.create/3`'s,
  each with nothing written. Confirms `credential_sharing`.
  """
  @spec create(Context.t(), map()) :: {:ok, share_view()} | {:error, term()}
  def create(%Context{} = ctx, params) when is_map(params) do
    with :ok <- owner(ctx),
         {:ok, audience} <- audience_param(params),
         {:ok, caps} <- caps_param(params),
         {:ok, entry_id} <- entry_param(params),
         {:ok, entry} <- own_entry(ctx, entry_id) do
      change = %{
        operation: "share.create",
        arguments: Map.merge(%{entry_id: entry_id}, Map.merge(audience, caps)),
        resource: entry.name,
        details: sharing_details(audience, caps)
      }

      with :ok <- Authz.check(ctx, :credential_sharing, change),
           {:ok, share} <-
             Store.create(
               Context.actor(ctx),
               Map.merge(%{entry_id: entry_id}, Map.merge(audience, caps)),
               verify: fn -> Authz.consume(ctx, {:credential_sharing, change}) end
             ) do
        Authz.consumed(ctx)
        announce(ctx, :created, share.id)
        {:ok, owner_view(share, 0)}
      end
    end
  end

  @doc """
  The context's own athanor's shares, active and revoked, oldest first,
  each with today's total use (`used_today`).
  """
  @spec list(Context.t()) :: {:ok, [share_view()]} | {:error, term()}
  def list(%Context{} = ctx) do
    actor = Context.actor(ctx)

    with :ok <- owner_reader(ctx),
         {:ok, shares} <- Store.list(actor) do
      collect(shares, fn share ->
        with {:ok, %{totals: totals}} <- Usage.usage(actor, share.id, 1) do
          {:ok, owner_view(share, Enum.reduce(totals, 0, &(&1.count + &2)))}
        end
      end)
    end
  end

  @doc """
  A share's use over the last `days` days, today included, for its owner:
  each person who used it, by id and display name, with their count by
  day (`people`), and the share's day totals (`totals`). `days` is from 1
  to `Arca.ShareUsage.kept_days/0`; any other is
  `{:error, :invalid_days}` before any read. A share the context's
  athanor does not hold is `{:error, :not_found}`.
  """
  @spec usage(Context.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def usage(%Context{} = ctx, share_id, days) when is_binary(share_id) do
    actor = Context.actor(ctx)

    with :ok <- owner_reader(ctx),
         :ok <- usage_days(days),
         {:ok, _share} <- Store.get(actor, share_id),
         {:ok, %{people: people, totals: totals}} <- Usage.usage(actor, share_id, days) do
      names = people |> Enum.map(& &1.user_id) |> Enum.uniq() |> Map.new(&{&1, display_name(&1)})
      people = Enum.map(people, &Map.put(&1, :display_name, names[&1.user_id]))
      {:ok, %{people: people, totals: totals}}
    end
  end

  @doc """
  Move a share of the context's own athanor to another audience
  (`params`: `:share_id`, `:audience` and `:group_id` as `create/2` names
  them, and `:expected`, the `%{audience: _, group_id: _}` the caller
  saw). `expected` is compared with the stored audience before anything
  is decided: one that moved is `{:error, {:conflict, sentence}}`, with
  nothing written and no confirmation asked. Then a change to everyone,
  or from one group to another, confirms `credential_sharing`, its proof
  binding `expected`; a narrowing to a group needs the session; an
  unchanged audience writes and announces nothing. The write is the
  store's compare-and-set on `expected` (`Arca.Shares.set_audience/4`),
  never retried.
  """
  @spec set_audience(Context.t(), map()) :: {:ok, :changed | :unchanged} | {:error, term()}
  def set_audience(%Context{} = ctx, %{share_id: id} = params) when is_binary(id) do
    actor = Context.actor(ctx)

    with :ok <- owner(ctx),
         {:ok, audience} <- audience_param(params),
         {:ok, expected} <- expected_param(params),
         {:ok, share} <- Store.get(actor, id),
         :ok <- as_expected(share, expected) do
      cond do
        audience == expected ->
          {:ok, :unchanged}

        widens?(expected, audience) ->
          with :ok <-
                 Authz.confirm(ctx, :credential_sharing, %{
                   operation: "share.set_audience",
                   arguments: %{share_id: id, audience: audience, expected: expected},
                   resource: id,
                   details: sharing_details(audience, %{})
                 }),
               do: write_audience(ctx, id, expected, audience)

        true ->
          write_audience(ctx, id, expected, audience)
      end
    end
  end

  def set_audience(%Context{}, _params), do: {:error, :share_required}

  defp write_audience(ctx, id, expected, audience) do
    with {:ok, _moved} <- Store.set_audience(Context.actor(ctx), id, expected, audience) do
      announce(ctx, :audience, id)
      {:ok, :changed}
    end
  end

  @doc """
  Set a share's two daily caps (`params`: `:share_id`, `:person_daily`,
  `:total_daily`), both written together: each absent or nil is no limit,
  `0` admits no use, `N` at most `N` a day. Caps already as named write
  and announce nothing.
  """
  @spec set_caps(Context.t(), map()) :: {:ok, :changed | :unchanged} | {:error, term()}
  def set_caps(%Context{} = ctx, %{share_id: id} = params) when is_binary(id) do
    actor = Context.actor(ctx)

    with :ok <- owner(ctx),
         {:ok, caps} <- caps_param(params),
         {:ok, share} <- Store.get(actor, id) do
      if Map.take(share, [:person_daily, :total_daily]) == caps and share.status == "active" do
        {:ok, :unchanged}
      else
        with {:ok, _set} <- Store.set_caps(actor, id, caps.person_daily, caps.total_daily) do
          announce(ctx, :caps, id)
          {:ok, :changed}
        end
      end
    end
  end

  def set_caps(%Context{}, _params), do: {:error, :share_required}

  @doc """
  Revoke a share of the context's own athanor: the next use through it is
  refused, and every profile, in every athanor, whose head binds it is
  blocked in the same transaction (`Arca.Shares.revoke/3`). A share
  already revoked is revoked again, so a retry finishes the job. Answers
  the blocked `{athanor_id, profile_id}` pairs.
  """
  @spec revoke(Context.t(), String.t()) ::
          {:ok, %{affected: [{String.t(), String.t()}]}} | {:error, term()}
  def revoke(%Context{} = ctx, share_id) when is_binary(share_id) do
    with :ok <- owner(ctx),
         {:ok, %{blocked: blocked}} <-
           Store.revoke(Context.actor(ctx), share_id, Sanctum.Vault.blocked_profile_status()) do
      announce(ctx, :revoked, share_id)
      {:ok, %{affected: blocked}}
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  @doc """
  The share `share_id` as a consent binds it for the context's person
  (`t:binding_view/0`), or why not, in order: an anonymous caller
  (`{:error, :anonymous_denied}`), a person who does not stand
  (`{:error, :denied}`), a share that is absent, revoked, not to an
  audience holding the person or the person's own
  (`{:error, :not_offered}`), an owner who does not stand
  (`{:error, :owner_not_standing}`), a source no longer active
  (`{:error, {:entry_unavailable, status}}`) and a source that is not an
  attach-only entry of a shareable kind with a derivable digest
  (`{:error, :corrupt}`). A store that cannot answer is
  `{:error, :unavailable}`. Nothing is unsealed and no use is counted.
  """
  @spec binding(Context.t(), String.t()) :: {:ok, binding_view()} | {:error, term()}
  def binding(%Context{} = ctx, share_id) when is_binary(share_id) do
    with :ok <- person(ctx),
         :ok <- recipient_stands(ctx),
         {:ok, offered} <- source(share_id),
         :ok <- offered_to(ctx, offered),
         :ok <- owner_stands(offered) do
      view(offered)
    end
  end

  @doc """
  Every share offered to the context's person, as `binding/2` answers
  each, newest first: a share `binding/2` would refuse is left out. A
  store that cannot answer is `{:error, :unavailable}`, never a shorter
  list.
  """
  @spec offered(Context.t()) :: {:ok, [binding_view()]} | {:error, term()}
  def offered(%Context{} = ctx) do
    with {:ok, pairs} <- offered_pairs(ctx), do: {:ok, Enum.map(pairs, &elem(&1, 1))}
  end

  @doc """
  `offered/1`, each share with the context's person's own count of its
  use today (`used_today`), as a claim counts it, and no other person's.
  """
  @spec offered_with_use(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def offered_with_use(%Context{} = ctx) do
    with {:ok, pairs} <- offered_pairs(ctx) do
      collect(pairs, fn {offered, view} ->
        owner = Context.actor(owner_context(offered))

        with {:ok, count} <- unavailable(Usage.used_today(owner, view.id, ctx.user_id)),
             do: {:ok, Map.put(view, :used_today, count)}
      end)
    end
  end

  defp offered_pairs(ctx) do
    with :ok <- person(ctx),
         :ok <- recipient_stands(ctx),
         {:ok, rows} <- unavailable(Store.offered_to(Context.actor(ctx), [])) do
      admitted(rows, &offered_to(ctx, &1))
    end
  end

  @doc """
  The active shares to everyone whose owner holds the platform
  administrator's capability and stands, newest first, as `binding/2`
  answers each for the context's person: what a new person's first
  sign-in binds from (`Sanctum.Consent.Bootstrap`), which picks by fit.
  A share of the person's own is not among them.
  """
  @spec administrator_shares(Context.t()) :: {:ok, [binding_view()]} | {:error, term()}
  def administrator_shares(%Context{} = ctx) do
    with :ok <- person(ctx),
         {:ok, rows} <- unavailable(Store.administrator_shares(Context.actor(ctx))),
         {:ok, pairs} <- admitted(rows, &not_own(ctx, &1)) do
      {:ok, Enum.map(pairs, &elem(&1, 1))}
    end
  end

  @doc """
  The facts a boot's revision with no person holds a carried share
  binding to (`Sanctum.Consent.Bootstrap`): the source's `kind`,
  `provider_hint`, `field_names`, `status` and derived `binding_digest`,
  for any active share. A share absent or revoked is
  `{:error, :not_offered}`, and a damaged source `{:error, :corrupt}`.
  Nothing is unsealed and no person is named: whose use it is, the
  attach path decides.
  """
  @spec binding_facts(String.t()) :: {:ok, binding_facts()} | {:error, term()}
  def binding_facts(share_id) when is_binary(share_id) do
    with {:ok, offered} <- source(share_id),
         :ok <- active(offered),
         {:ok, view} <- view(offered) do
      {:ok, Map.drop(view, [:id, :owner, :destination])}
    end
  end

  # ---------------------------------------------------------------------------
  # The attach path
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the share `share_id` for one attached request: the value of
  the source entry's field `take` names (`{:field, need_field,
  entry_field}`), for `request` (`%{uri: %URI{}, method: _}`), held to
  `approved_digest`, the digest the person's consent approved.

  In order, nothing counted or unsealed before a check that refuses:

    1. the context's person stands (`{:error, :denied}`);
    2. the share is active and its audience includes them, read now, and
       it is not their own (`{:error, :not_offered}`);
    3. its owner stands (`{:error, :owner_not_standing}`);
    4. the source entry is active (`{:error, {:entry_unavailable,
       status}}`), attach-only and of a shareable kind
       (`{:error, :corrupt}`);
    5. the digest derived from the source's binding fields equals
       `approved_digest` (`{:error, :binding_went_stale}`);
    6. the request is inside the source's destination
       (`{:error, :destination_mismatch}`);
    7. one use is counted under the share's caps, read from its locked
       row (`Arca.ShareUsage.claim/3`), refused only under a set cap that
       is reached (`{:error, {:connection_cap, reset_at}}`);
    8. the material is unsealed under the owner's internal context
       through `Sanctum.VaultReader.load_and_unseal/2`, with a resource
       naming the source entry and `approved_digest`, so that read decides
       the digest once more (`{:error, :binding_mismatch}`,
       `{:error, :unseal_failed}`), and the one field is read
       (`{:error, {:missing_field, need_field}}`).

  A use counted stands whatever follows: the request was admitted. The
  value is answered alone; the rest of the material never leaves here.
  """
  @spec resolve(
          Context.t(),
          String.t(),
          String.t(),
          %{uri: URI.t(), method: String.t()},
          {:field, String.t(), String.t()}
        ) :: {:ok, String.t()} | {:error, term()}
  def resolve(
        %Context{} = ctx,
        share_id,
        approved_digest,
        %{uri: %URI{}, method: method} = request,
        {:field, _need_field, _entry_field} = take
      )
      when is_binary(share_id) and is_binary(approved_digest) and is_binary(method) do
    with :ok <- person(ctx),
         :ok <- recipient_stands(ctx),
         {:ok, offered} <- source(share_id),
         :ok <- offered_to(ctx, offered),
         :ok <- owner_stands(offered),
         {:ok, view} <- view(offered),
         :ok <- same_digest(view.binding_digest, approved_digest),
         :ok <- inside(offered.source.destination, request) do
      owner = owner_context(offered)

      with {:ok, _counted} <- claim(owner, share_id, ctx.user_id),
           {:ok, _entry, payload} <-
             VaultReader.load_and_unseal(owner, %{
               entry_id: offered.source.id,
               binding_digest: approved_digest
             }) do
        field_value(payload, take)
      end
    end
  end

  @doc """
  Delete the day counts older than `Arca.ShareUsage.kept_days/0`, in
  every athanor, under the platform's system actor, naming no share and
  no person, for `Cyfr.RetentionScheduler`. Answers how many went.
  """
  @spec sweep_usage() :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_usage, do: Usage.sweep(Prima.Actor.system())

  @doc false
  # Announce `kind` for each share in `share_ids`, a change another
  # module's transaction made to the share's source: an entry's rebind,
  # rotation, revoke or delete (`Sanctum.Vault`), or a standing transition.
  @spec announce_each(Context.t() | nil, kind(), [String.t()]) :: :ok
  def announce_each(ctx, kind, share_ids) when kind in @kinds and is_list(share_ids) do
    Enum.each(share_ids, &announce(ctx, kind, &1))
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # The owner's own internal context, in the share's athanor: the one
  # place it is built for a share. It projects a system actor of that
  # athanor alone, wider than a person's, and reads only the share's own
  # use rows and its source entry, for the person whose consent named it.
  defp owner_context(%{share: share}),
    do: Context.internal(athanor_id: share.athanor_id, scope: :athanor)

  # A revoke that landed after the share was read is waited for by the
  # claim's lock and refuses it: the share is no longer offered.
  defp claim(owner, share_id, user_id) do
    case Usage.claim(Context.actor(owner), share_id, user_id) do
      {:ok, counted} -> {:ok, counted}
      {:error, {:share_unavailable, _status}} -> {:error, :not_offered}
      {:error, :not_found} -> {:error, :not_offered}
      {:error, {:connection_cap, _reset_at}} = capped -> capped
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp person(%Context{anonymous: true}), do: {:error, :anonymous_denied}
  defp person(%Context{authenticated: false}), do: {:error, :anonymous_denied}
  defp person(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "", do: :ok
  defp person(%Context{}), do: {:error, :anonymous_denied}

  # A write is made in the person's own athanor, on the interactive class.
  defp owner(ctx) do
    with :ok <- owner_reader(ctx) do
      case Authz.authorize_interactive(ctx) do
        {:ok, :interactive} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp owner_reader(%Context{} = ctx) do
    with :ok <- person(ctx) do
      if Sanctum.Tenancy.Users.own_athanor?(ctx.user_id, ctx.athanor_id),
        do: :ok,
        else: {:error, :not_own_athanor}
    end
  end

  defp recipient_stands(ctx) do
    case Sanctum.Caller.stands?(ctx.user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :denied}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp owner_stands(%{owner_user_id: owner}) do
    case Sanctum.Caller.stands?(owner) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :owner_not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The share and its source by the id a binding names. An absent share is
  # not offered to anyone.
  defp source(share_id) do
    case Store.get_for_source(Prima.Actor.system(), share_id) do
      {:ok, offered} -> {:ok, offered}
      {:error, :not_found} -> {:error, :not_offered}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # Offered to the context's person: active, to an audience that holds
  # them, read now, and never their own.
  defp offered_to(ctx, %{share: share} = offered) do
    with :ok <- active(offered),
         :ok <- not_own(ctx, offered) do
      in_audience(ctx, share)
    end
  end

  defp active(%{share: %{status: "active"}}), do: :ok
  defp active(%{share: _revoked}), do: {:error, :not_offered}

  defp not_own(%Context{user_id: user_id}, %{owner_user_id: user_id}), do: {:error, :not_offered}
  defp not_own(%Context{}, _offered), do: :ok

  defp in_audience(_ctx, %{audience: "everyone"}), do: :ok

  defp in_audience(ctx, %{audience: "group", group_id: group_id}) when is_binary(group_id) do
    case Store.member?(Context.actor(ctx), group_id, ctx.user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :not_offered}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp in_audience(_ctx, _share), do: {:error, :not_offered}

  # The offered rows `admit` holds for the person, each through the owner's
  # standing and the source's checks as `binding/2` makes them, beside its
  # view. A refusal leaves the share out; an outage fails the whole read.
  defp admitted(rows, admit) do
    rows
    |> Enum.reduce_while({:ok, []}, fn offered, {:ok, acc} ->
      result =
        with :ok <- admit.(offered),
             :ok <- owner_stands(offered),
             do: view(offered)

      case result do
        {:ok, view} -> {:cont, {:ok, [{offered, view} | acc]}}
        {:error, :unavailable} -> {:halt, {:error, :unavailable}}
        {:error, _refused} -> {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, views} -> {:ok, Enum.reverse(views)}
      error -> error
    end
  end

  # The source's binding facts with the digest derived from its columns,
  # or why it binds nothing: a source no longer active, and a row no share
  # could have named (not attach-only, of a kind no share offers, or with
  # binding columns that derive no digest), which is damage.
  defp view(%{share: share, source: source, owner_user_id: owner}) do
    with :ok <- source_active(source),
         :ok <- source_held(source),
         {:ok, digest} <- derived_digest(source) do
      {:ok,
       %{
         id: share.id,
         owner: display_name(owner),
         kind: source.kind,
         provider_hint: source.provider_hint || "",
         field_names: decode_list(source.field_names),
         destination: decode_destination(source.destination),
         binding_digest: digest,
         status: source.status,
         attach_only: true
       }}
    end
  end

  defp source_active(%{status: "active"}), do: :ok
  defp source_active(%{status: status}), do: {:error, {:entry_unavailable, status}}

  defp source_held(%{attach_only: true, kind: kind}) do
    if kind in Prima.CredentialKinds.shareable(), do: :ok, else: corrupt()
  end

  defp source_held(_disclosed), do: corrupt()

  defp derived_digest(source) do
    case VaultReader.binding_digest(source) do
      {:ok, digest} -> {:ok, digest}
      {:error, _underivable} -> corrupt()
    end
  end

  defp corrupt, do: {:error, :corrupt}

  defp same_digest(derived, approved) do
    if Plug.Crypto.secure_compare(derived, approved),
      do: :ok,
      else: {:error, :binding_went_stale}
  end

  # The request inside the source's destination, its stored text read back
  # through the grammar: a row whose destination does not read admits
  # nothing.
  defp inside(text, %{uri: uri, method: method}) when is_binary(text) do
    with {:ok, %{} = map} <- Prima.Json.decode(text),
         {:ok, destination} <- Prima.Destination.from_map(map),
         true <- Prima.Destination.matches?(destination, uri, method) do
      :ok
    else
      _outside_or_unreadable -> {:error, :destination_mismatch}
    end
  end

  defp inside(_absent, _request), do: {:error, :destination_mismatch}

  defp field_value(%{"fields" => fields}, {:field, need_field, entry_field}) do
    case Map.fetch(fields, entry_field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, {:missing_field, need_field}}
    end
  end

  defp field_value(_payload, {:field, need_field, _entry_field}),
    do: {:error, {:missing_field, need_field}}

  # The entry of the person's own athanor a creation names, read for the
  # confirmation's preview; the store reads it again under its lock.
  defp own_entry(ctx, entry_id) do
    case Arca.VaultStorage.get(Context.actor(ctx), entry_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp entry_param(%{entry_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp entry_param(_params), do: {:error, :entry_required}

  defp audience_param(params) do
    audience = %{audience: Map.get(params, :audience), group_id: Map.get(params, :group_id)}

    if Store.audience_valid?(audience),
      do: {:ok, audience},
      else: {:error, :invalid_audience}
  end

  defp expected_param(%{expected: %{} = expected}) do
    audience = %{audience: Map.get(expected, :audience), group_id: Map.get(expected, :group_id)}

    if Store.audience_valid?(audience),
      do: {:ok, audience},
      else: {:error, :invalid_expected}
  end

  defp expected_param(_params), do: {:error, :invalid_expected}

  defp as_expected(share, expected) do
    if %{audience: share.audience, group_id: share.group_id} == expected,
      do: :ok,
      else: {:error, {:conflict, @audience_conflict}}
  end

  # Widening: the audience becomes everyone, or another group.
  defp widens?(%{audience: "everyone"}, _requested), do: false
  defp widens?(_held, %{audience: "everyone"}), do: true
  defp widens?(%{group_id: held}, %{group_id: requested}), do: held != requested

  # Each cap absent for no limit, else an integer from 0 to the share's
  # maximum; a text or a float is refused, never cast.
  defp caps_param(params) do
    caps = %{
      person_daily: Map.get(params, :person_daily),
      total_daily: Map.get(params, :total_daily)
    }

    if Enum.all?(Map.values(caps), &Store.cap?/1),
      do: {:ok, caps},
      else: {:error, :invalid_caps}
  end

  defp usage_days(days) when is_integer(days) and days >= 1 do
    if days <= Usage.kept_days(), do: :ok, else: {:error, :invalid_days}
  end

  defp usage_days(_days), do: {:error, :invalid_days}

  # What a person proving a share is shown: who it is offered to and its
  # caps, never a value.
  defp sharing_details(%{audience: audience}, caps) do
    %{"audience" => audience}
    |> Map.merge(cap_details(caps))
  end

  defp cap_details(caps) when map_size(caps) == 0, do: %{}

  defp cap_details(caps) do
    %{
      "person_daily" => cap_words(caps.person_daily),
      "total_daily" => cap_words(caps.total_daily)
    }
  end

  defp cap_words(nil), do: "no limit"
  defp cap_words(cap), do: Integer.to_string(cap)

  defp unavailable({:ok, _} = ok), do: ok
  defp unavailable({:error, _unanswered}), do: {:error, :unavailable}

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp owner_view(share, used_today) do
    %{
      id: share.id,
      entry_id: share.vault_entry_id,
      audience: share.audience,
      group_id: share.group_id,
      person_daily: share.person_daily,
      total_daily: share.total_daily,
      status: share.status,
      used_today: used_today,
      created_at: share.inserted_at
    }
  end

  defp display_name(user_id), do: Sanctum.Tenancy.Users.display_name(user_id)

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

  # One literal event per kind: the telemetry catalog's source scan reads
  # them from here, and holds them to `kinds/0`.
  defp announce(ctx, :created, id),
    do: emit([:cyfr, :sanctum, :share, :created], ctx, :created, id)

  defp announce(ctx, :audience, id),
    do: emit([:cyfr, :sanctum, :share, :audience], ctx, :audience, id)

  defp announce(ctx, :caps, id), do: emit([:cyfr, :sanctum, :share, :caps], ctx, :caps, id)

  defp announce(ctx, :rebound, id),
    do: emit([:cyfr, :sanctum, :share, :rebound], ctx, :rebound, id)

  defp announce(ctx, :rotated, id),
    do: emit([:cyfr, :sanctum, :share, :rotated], ctx, :rotated, id)

  defp announce(ctx, :revoked, id),
    do: emit([:cyfr, :sanctum, :share, :revoked], ctx, :revoked, id)

  # The share, the kind and who acted: never an entry, an audience or a value.
  defp emit(event, ctx, kind, id),
    do:
      :telemetry.execute(event, %{count: 1}, %{share_id: id, kind: kind, user_id: actor_id(ctx)})

  defp actor_id(%Context{user_id: user_id}), do: user_id
  defp actor_id(nil), do: nil
end
