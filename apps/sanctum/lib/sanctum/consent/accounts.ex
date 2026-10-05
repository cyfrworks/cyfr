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

  Answers the entry's id. A source with no profile to select by default,
  a selected profile that is not active, a profile with no head, a head
  with no ingress, and an ingress that binds no account by that name are
  each `{:error, :connection_not_granted}`: a grant to make. A store that
  cannot answer, a damaged row, a selection that is ambiguous or names no
  profile, and a head the loader refuses answer their own refusal, never
  `connection_not_granted`.
  """
  @spec resolve(Sanctum.Context.t(), RootSelect.selector(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :connection_not_granted | term()}
  def resolve(%Sanctum.Context{} = ctx, selector, source_ref, name)
      when is_binary(source_ref) and is_binary(name) do
    with {:ok, name_ref} <- name_level(source_ref),
         {:ok, entries} <- Sanctum.Consent.profiles(ctx, name_ref),
         {:ok, profile} <- select_profile(entries, selector),
         {:ok, consent} <- head(ctx, profile),
         {:ok, blob} <- Sanctum.Consent.Loader.admitted_blob(ctx, profile, consent),
         {:ok, ingress} <- ingress(blob, profile.source_ref) do
      case Blob.vault_for(ingress, name) do
        {:ok, %{entry_id: entry_id}} when is_binary(entry_id) -> {:ok, entry_id}
        _not_bound -> {:error, :connection_not_granted}
      end
    end
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

  defp head(ctx, profile) do
    case Sanctum.Consent.head_consent(ctx, profile.id) do
      {:ok, consent} -> {:ok, consent}
      {:error, :not_found} -> {:error, :connection_not_granted}
      {:error, _unreadable} = refused -> refused
    end
  end

  defp ingress(blob, source_ref) do
    case Blob.ingress(blob, source_ref) do
      {:ok, ingress} -> {:ok, ingress}
      {:error, :missing_ingress} -> {:error, :connection_not_granted}
    end
  end
end
