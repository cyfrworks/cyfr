# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Accounts do
  @moduledoc """
  The accounts an app's own calls may name, read from its stored head:
  which named accounts its own profile's ingress binds (`list/1`), and
  which entry one name resolves to there (`resolve/4`).

  Both are reads, never writes, and answer metadata only: an entry's id
  and account names, never a value. They read through the consent
  facade (`Sanctum.Consent.profiles/2`, `Sanctum.Consent.head_consent/2`),
  the head as a run carries it (`Sanctum.Consent.Loader.admitted_blob/3`)
  and, for the list, the athanor's active heads
  (`Arca.ConsentStorage.active_heads/2`).
  """

  alias Prima.Authority.Blob
  alias Prima.Authority.RootSelect

  # The heads `list/1` reads: one page, the cap a read of what a grant
  # reaches takes, since the store keeps no cursor.
  @heads_cap 1_000

  @doc """
  The entry the account `name` resolves to on the ingress of the profile
  `selector` picks for `source_ref` (`Prima.Authority.RootSelect`; any
  version of the reference names its line): the profile's stored head,
  carried as a run carries it (`Sanctum.Consent.Loader.admitted_blob/3`,
  under the context's origin), its ingress (`Prima.Authority.Blob.ingress/2`)
  and the named binding there (`Prima.Authority.Blob.vault_for/2`). This
  is the one resolution of a launch's account: what an assistant's policy
  decides on, what its card binds and what its dispatch checks again.

  The name is matched as account names compare
  (`Prima.Authority.Blob.same_account_name?/2`), so another case of a
  bound name resolves. Answers the entry's id and the account's name as
  the binding stores it, which is the spelling everything recorded and
  shown of the account carries. A source with no profile to select by
  default, a selected profile that is not active, and an ingress that
  binds no account by that name are each
  `{:error, :connection_not_granted}`: a grant to make.

  The selected profile's own head reads as a run's root reads it: one the
  store could not answer is `{:error, {:head_unavailable, profile_id}}`,
  and an active profile with no head, a head stored outside the closed
  vocabulary, and a head the loader cannot trust, its grant holding no
  ingress for the source included, are damage in the loader's one reading
  of it (`Sanctum.Consent.Loader.damage_refusal/3`), here
  `{:error, {:head_corrupt, profile_id}}`, never a grant to make. A store
  that cannot answer the profiles, a damaged profile row, a selection
  that is ambiguous or names no profile, and a lender's refusal answer
  their own refusal, never `connection_not_granted`.
  """
  @spec resolve(Sanctum.Context.t(), RootSelect.selector(), String.t(), String.t()) ::
          {:ok, %{entry_id: String.t(), name: String.t()}}
          | {:error, :connection_not_granted | term()}
  def resolve(%Sanctum.Context{} = ctx, selector, source_ref, name)
      when is_binary(source_ref) and is_binary(name) do
    with {:ok, name_ref} <- name_level(source_ref),
         {:ok, entries} <- Sanctum.Consent.profiles(ctx, name_ref),
         {:ok, profile} <- select_profile(entries, selector) do
      case bound_account(ctx, profile, name) do
        {:error, reason} -> {:error, own_refusal(reason, profile, source_ref)}
        {:ok, _account} = resolved -> resolved
      end
    end
  end

  # The account `name` on the profile's own ingress, its head read as the
  # loader reads a root's: each answer the loader's own term for the
  # stored state it meets.
  defp bound_account(ctx, profile, name) do
    with {:ok, consent} <- head(ctx, profile),
         {:ok, blob} <- Sanctum.Consent.Loader.admitted_blob(ctx, profile, consent),
         {:ok, ingress} <- ingress(blob, profile.source_ref) do
      with {:ok, %{entry_id: entry_id, binding_key: key}} when is_binary(entry_id) <-
             Blob.vault_for(ingress, name),
           {:ok, {_node, _edge, stored}} when is_binary(stored) <- Blob.parse_binding_key(key) do
        {:ok, %{entry_id: entry_id, name: stored}}
      else
        _not_bound -> {:error, :connection_not_granted}
      end
    end
  end

  # The app's own head read damaged is the loader's one reading of that
  # damage, so a launch names it as the run's root would: the same stored
  # state reads the same wherever an app's own head is read.
  defp own_refusal(reason, profile, source_ref) do
    if Sanctum.Consent.Loader.damage?(reason),
      do: Sanctum.Consent.Loader.damage_refusal(reason, profile.id, source_ref),
      else: reason
  end

  @doc """
  The sources whose own calls may name an account, and the names: each
  source with exactly one active owner profile, the one a run selects by
  default, whose stored head's ingress, carried as a run carries it
  (`Sanctum.Consent.Loader.admitted_blob/3`), binds named accounts beside
  its default. Answers `{:ok, [{source_ref, names}], truncated?}`, sorted
  by reference, each source's names sorted.

  One page of the athanor's active heads is read, at most #{@heads_cap},
  since the store keeps no cursor; `truncated?` says more stand past it.
  A head that cannot be read, or that the loader refuses, is left out.
  `{:error, :unavailable}` is a store that could not answer the page, and
  `{:error, :no_athanor}` a context with no tenant.
  """
  @spec list(Sanctum.Context.t()) ::
          {:ok, [{String.t(), [String.t()]}], boolean()}
          | {:error, :unavailable | :no_athanor}
  def list(%Sanctum.Context{} = ctx) do
    case Arca.ConsentStorage.active_heads(Sanctum.Context.actor(ctx), limit: @heads_cap) do
      {:ok, heads, truncated?} ->
        accounts =
          heads
          |> Enum.filter(&(&1.profile.kind == :owner))
          |> Enum.group_by(& &1.profile.source_ref)
          |> Enum.flat_map(fn
            {source_ref, [head]} -> named_accounts(ctx, source_ref, head)
            {_source_ref, _several} -> []
          end)
          |> Enum.sort_by(&elem(&1, 0))

        {:ok, accounts, truncated?}

      {:error, :no_athanor} ->
        {:error, :no_athanor}

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end

  # One source's names, when the profile a run selects by default is this
  # head's and its ingress binds any; none otherwise, or when it cannot be
  # read.
  defp named_accounts(ctx, source_ref, %{profile: profile, consent: consent}) do
    with {:ok, entries} <- Sanctum.Consent.profiles(ctx, source_ref),
         {:ok, %{id: id}} <- select_profile(entries, :default),
         true <- id == profile.id,
         {:ok, blob} <- Sanctum.Consent.Loader.admitted_blob(ctx, profile, consent),
         {:ok, %Blob.Edge{vault: %{named: %{} = named}}} <- Blob.ingress(blob, source_ref),
         [_ | _] = names <- named |> Map.keys() |> Enum.sort() do
      [{source_ref, names}]
    else
      _none_or_unreadable -> []
    end
  end

  defp name_level(source_ref) do
    case Prima.ComponentRef.to_name_ref(source_ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, reason} -> {:error, {:invalid_reference, reason}}
    end
  end

  # The profile a run of the source would root at, read as admission reads
  # it: a damaged row refuses every selection but a pinned id naming
  # another, and no profile to select, or one that is not active, holds no
  # account.
  defp select_profile(entries, selector) do
    case Enum.filter(entries, &(&1.status == :corrupt)) do
      [] ->
        select(entries, selector)

      damaged ->
        bearing =
          case selector do
            {:id, pinned} -> Enum.find(damaged, &(&1.id == pinned))
            _by_kind_or_label -> hd(damaged)
          end

        case bearing do
          nil -> select(entries -- damaged, selector)
          %{id: id} -> {:error, {:corrupt, {:profile, id}}}
        end
    end
  end

  defp select(entries, selector) do
    case RootSelect.select(entries, selector) do
      {:ok, profile} -> {:ok, profile}
      {:error, :no_profile} -> {:error, :connection_not_granted}
      {:error, {:profile_unavailable, _status}} -> {:error, :connection_not_granted}
      {:error, _ambiguous_or_not_found} = refused -> refused
    end
  end

  # The selected profile is active, so a head it does not have is a head
  # it lost, read as the loader reads it (`{:no_head_consent, id}`), never
  # a grant to make; one stored outside the closed vocabulary, or that the
  # store could not answer, is the loader's damaged or unanswered head.
  defp head(ctx, profile) do
    case Sanctum.Consent.head_consent(ctx, profile.id) do
      {:ok, consent} -> {:ok, consent}
      {:error, :not_found} -> {:error, {:no_head_consent, profile.id}}
      {:error, :corrupt} -> {:error, {:head_corrupt, profile.id}}
      {:error, :unavailable} -> {:error, {:head_unavailable, profile.id}}
      {:error, :no_athanor} = refused -> refused
    end
  end

  # A grant holding no ingress for its own source, its node absent or
  # without one, is the loader's `missing_ingress`: damage, since every
  # grant a commit writes holds its source's ingress.
  defp ingress(blob, source_ref) do
    case Blob.ingress(blob, source_ref) do
      {:ok, ingress} -> {:ok, ingress}
      {:error, :missing_ingress} -> {:error, {:missing_ingress, source_ref}}
    end
  end
end
