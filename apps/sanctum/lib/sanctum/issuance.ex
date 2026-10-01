# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Issuance do
  @moduledoc false
  # The policy a session or an API key is issued under, shared by
  # `Sanctum.Session.create/2` and `Sanctum.ApiKey`'s create and rotate.
  #
  # An issuing context must say what standing it read: its
  # `credential_binding` (an admitted sign-in's `:identity`, a session's,
  # a key's, or a paired device's), or — for the few fixtures that build a
  # context by hand, and only in a build compiled with
  # `:issuance_snapshot_permitted` — a `:generation_snapshot` read from the
  # rows (`Sanctum.Tenancy.generation_snapshot/2`). Neither is
  # `{:error, :missing_generation}`, and so is a key with no person behind
  # it and a person focused on an athanor through no membership. The rows it names are then locked and reread inside the issuing
  # transaction (`Arca.SecurityTransitions.Issuance`): the person must be
  # active at the generation read, the focused athanor active at its
  # generation read, the membership that authorized the focus still an
  # active seat, and the credential the context holds still live. A
  # generation that moved is `{:error, :stale_generation}`; a row that no
  # longer stands is `{:error, :unauthenticated}` — the credential the
  # issuing context presents opens nothing any more.
  #
  # A paired device's context (`auth_method: :device`) issues only under
  # its own binding, which names its paired client (`source_kind:
  # :device`), never under a snapshot, an `:identity` binding or a
  # session's: anything else is `{:error, :missing_generation}`, so a
  # device is never taken for a sign-in or a session. Its client is locked
  # after the person, the athanor and the seat, and the issuance stands
  # only while that client is active and the person's own in the athanor
  # the context works in, the context's credential deadline (its
  # certificate's expiry, of which a renewal exchange's context has none)
  # is still ahead on the database's clock, and the certificate still
  # stands. A certificate this home signed stands on its row: the client's
  # certificate expiring at that deadline, neither revoked nor expired. A
  # person whose keys are at another home holds no row here for a
  # certificate their own home issued them again, so theirs stands on what
  # it was verified against: the identity row they were resolved by still
  # names them, remote, under the same identifier, and their cached head
  # still names the `key_epoch` the binding carries. Any of those no
  # longer holding is `{:error, :not_standing}`: a revocation, or a head
  # that moved, landing after the device's request was verified and before
  # the issuance reached the client wins over it.

  alias Sanctum.Context

  # config:compile-runtime-ok — the permission is compiled in on purpose: a
  # release is built without it, so no runtime setting can hand an issuance
  # a snapshot in place of its context's own binding.
  @snapshot_permitted Application.compile_env(:sanctum, :issuance_snapshot_permitted, false)

  # The words an issuance, or a write held as one (`device_hold/1`),
  # refuses its caller's standing with: no standing read
  # (`:missing_generation`), a generation that moved (`:stale_generation`),
  # a row that no longer stands (`:unauthenticated`), and a paired device
  # whose client or certificate no longer stands (`:not_standing`).
  @standing_refusals [:missing_generation, :stale_generation, :unauthenticated, :not_standing]

  @doc false
  # The standing refusals, for a surface that answers them
  # (`standing_refusal/1`) rather than reporting a failure.
  @spec standing_refusals() :: [atom()]
  def standing_refusals, do: @standing_refusals

  @doc false
  # Whether `reason` is one of the standing refusals, in a guard.
  defguard standing_refusal?(reason) when reason in @standing_refusals

  @doc false
  # The sentence a surface answers a standing refusal with: one sentence
  # per word, the same for a key, a webhook secret and a vault entry. None
  # is a fault to log.
  @spec standing_refusal(atom()) :: String.t()
  def standing_refusal(:missing_generation),
    do: "This session cannot issue a credential; sign in again"

  def standing_refusal(:stale_generation),
    do: "Your standing changed since this session was read; sign in again"

  def standing_refusal(:unauthenticated),
    do: "Your session, membership or athanor no longer stands; sign in again"

  def standing_refusal(:not_standing), do: Prima.Refusal.message(:not_standing)

  @type expectation :: %{
          user_id: String.t(),
          user_generation: pos_integer(),
          athanor_id: String.t() | nil,
          athanor_generation: pos_integer() | nil,
          membership_id: String.t() | nil,
          source: Arca.SecurityTransitions.Issuance.source(),
          identity: Context.device_identity() | nil,
          key_epoch: String.t() | nil
        }

  @doc false
  @spec expectation(Context.t(), keyword()) :: {:ok, expectation()} | {:error, atom()}
  # A device stands on its paired client, which only its own binding
  # names: a snapshot would issue with no client behind it.
  def expectation(%Context{auth_method: :device} = ctx, _opts), do: from_binding(ctx)

  def expectation(%Context{} = ctx, opts) do
    case Keyword.get(opts, :generation_snapshot) do
      nil -> from_binding(ctx)
      snapshot -> snapshot(@snapshot_permitted, ctx, snapshot)
    end
  end

  # Only a build compiled with the test permission takes a snapshot; a
  # release answers one as a context with no generations.
  @doc false
  @spec snapshot(boolean(), Context.t(), map()) :: {:ok, expectation()} | {:error, atom()}
  def snapshot(true, ctx, snapshot), do: from_snapshot(ctx, snapshot)
  def snapshot(false, _ctx, _snapshot), do: {:error, :missing_generation}

  defp from_snapshot(
         %Context{user_id: user_id, athanor_id: athanor_id},
         %{user_id: user_id, user_generation: user_generation, athanor_id: athanor_id} = snapshot
       )
       when is_binary(user_id) and is_integer(user_generation) do
    with :ok <- generation_for(athanor_id, snapshot.athanor_generation) do
      {:ok,
       %{
         user_id: user_id,
         user_generation: user_generation,
         athanor_id: athanor_id,
         athanor_generation: snapshot.athanor_generation,
         membership_id: nil,
         source: nil,
         identity: nil,
         key_epoch: nil
       }}
    end
  end

  # A snapshot of another person or another athanor proves nothing about
  # this context.
  defp from_snapshot(_ctx, _snapshot), do: {:error, :missing_generation}

  defp from_binding(%Context{user_id: user_id, credential_binding: %{} = binding} = ctx)
       when is_binary(user_id) do
    with :ok <- generation_for(ctx.athanor_id, binding.athanor_generation),
         :ok <- basis_for(ctx.athanor_id, binding.focus_basis),
         {:ok, source} <- source(ctx, binding) do
      {:ok,
       %{
         user_id: user_id,
         user_generation: binding.user_generation,
         athanor_id: ctx.athanor_id,
         athanor_generation: binding.athanor_generation,
         membership_id: if(is_binary(binding.focus_basis), do: binding.focus_basis),
         source: source,
         identity: identity(source, binding),
         key_epoch: key_epoch(source, binding)
       }}
    end
  end

  defp from_binding(%Context{}), do: {:error, :missing_generation}

  # A focused athanor needs the generation it was read at; an unfocused
  # context needs none.
  defp generation_for(nil, _generation), do: :ok
  defp generation_for(_athanor_id, generation) when is_integer(generation), do: :ok
  defp generation_for(_athanor_id, _generation), do: {:error, :missing_generation}

  # A focused person names the membership that authorized the focus, and
  # the seat check below rereads it; a key's focus is the key itself. A
  # focus no membership backs is not an issuing standing.
  defp basis_for(nil, _basis), do: :ok
  defp basis_for(_athanor_id, :key), do: :ok
  defp basis_for(_athanor_id, basis) when is_binary(basis), do: :ok
  defp basis_for(_athanor_id, _basis), do: {:error, :missing_generation}

  # The credential the context holds, and the one assembly path that
  # stamped it: the session key, the key id and the paired client's id
  # travel with the binding and must agree with it. A device context holds
  # its paired client, focused through its seat, and the certificate whose
  # expiry is its deadline, and nothing else; no other context holds a
  # device's binding.
  defp source(
         %Context{
           auth_method: :device,
           client_id: id,
           credential_deadline: %DateTime{} = deadline
         },
         %{source_kind: :device, source_id: id, focus_basis: basis}
       )
       when is_binary(id) and id != "" and is_binary(basis),
       do: {:ok, {:device, id, deadline}}

  defp source(%Context{auth_method: :device}, _binding), do: {:error, :missing_generation}
  defp source(_ctx, %{source_kind: :device}), do: {:error, :missing_generation}

  defp source(_ctx, %{source_kind: :identity}), do: {:ok, nil}

  defp source(%Context{session_token_hash: hash}, %{source_kind: :session, source_id: id})
       when is_binary(hash) and is_binary(id) do
    if Base.url_encode64(hash, padding: false) == id,
      do: {:ok, {:session, hash}},
      else: {:error, :missing_generation}
  end

  defp source(%Context{api_key_id: id}, %{source_kind: :api_key, source_id: id})
       when is_binary(id),
       do: {:ok, {:api_key, id}}

  defp source(_ctx, _binding), do: {:error, :missing_generation}

  # The remote identity row a device's person was resolved by, which the
  # issuance holds them to; nil for a local subject and for every other
  # source.
  defp identity({:device, _id, _deadline}, binding), do: Map.get(binding, :identity)
  defp identity(_source, _binding), do: nil

  # The `key_epoch` a remote subject's certificate was verified under,
  # which their cached head must still name; nil for every other source.
  defp key_epoch({:device, _id, _deadline}, binding), do: Map.get(binding, :key_epoch)
  defp key_epoch(_source, _binding), do: nil

  @doc false
  # The issuance a credential write that is not itself an issuance's (a
  # webhook secret, a vault entry) runs under, as the options its Arca
  # write takes (`Arca.SecurityTransitions.Issuance.held/2`): from a
  # paired device's context, its expectation's `lock:` and `verify:`, so
  # the write's own transaction holds the device's client, certificate and
  # standing as an issuance does and refuses as one refuses; from any other
  # context, none, and the write runs as it does.
  @spec device_hold(Context.t()) :: {:ok, keyword()} | {:error, atom()}
  def device_hold(%Context{auth_method: :device} = ctx) do
    with {:ok, expectation} <- expectation(ctx, []),
         do: {:ok, lock: lock(expectation), verify: verify(expectation)}
  end

  def device_hold(%Context{}), do: {:ok, []}

  @doc false
  @spec lock(expectation()) :: Arca.SecurityTransitions.Issuance.targets()
  def lock(expectation),
    do: Map.take(expectation, [:user_id, :athanor_id, :membership_id, :source])

  @doc false
  # The policy over the locked rows.
  @spec verify(expectation()) :: (map() -> :ok | {:error, atom()})
  def verify(expectation) do
    fn rows ->
      with :ok <- person(rows.user, expectation),
           :ok <- athanor(rows.athanor, expectation),
           :ok <- seat(rows.membership, expectation) do
        holder(rows.source, rows.now, expectation)
      end
    end
  end

  defp person(%{status: "active", security_generation: generation}, %{user_generation: generation}),
       do: :ok

  defp person(%{status: "active"}, _expectation), do: {:error, :stale_generation}
  defp person(_user, _expectation), do: {:error, :unauthenticated}

  defp athanor(_athanor, %{athanor_id: nil}), do: :ok

  defp athanor(%{status: "active", security_generation: generation}, %{
         athanor_generation: generation
       }),
       do: :ok

  defp athanor(%{status: "active"}, _expectation), do: {:error, :stale_generation}
  defp athanor(_athanor, _expectation), do: {:error, :unauthenticated}

  defp seat(_membership, %{membership_id: nil}), do: :ok

  defp seat(
         %{status: "active", user_id: user_id, scope: "athanor", athanor_id: athanor_id},
         %{user_id: user_id, athanor_id: athanor_id}
       ),
       do: :ok

  defp seat(%{status: "active", user_id: user_id, scope: "platform"}, %{user_id: user_id}),
    do: :ok

  defp seat(_membership, _expectation), do: {:error, :unauthenticated}

  defp holder(nil, _now, %{source: nil}), do: :ok

  defp holder(%{kind: :session, row: %{user_id: user_id, expires_at: expires_at}}, now, %{
         user_id: user_id
       }) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :unauthenticated}
  end

  defp holder(%{kind: :api_key, row: %{revoked: false, athanor_id: athanor_id}}, _now, %{
         athanor_id: athanor_id
       }),
       do: :ok

  defp holder(
         %{kind: :device} = rows,
         now,
         %{source: {:device, client_id, deadline}} = expectation
       ) do
    if client?(rows.row, client_id, expectation) and DateTime.compare(deadline, now) == :gt and
         certified?(rows, client_id, deadline, now, expectation),
       do: :ok,
       else: {:error, :not_standing}
  end

  defp holder(_source, _now, %{source: {:device, _id, _deadline}}), do: {:error, :not_standing}
  defp holder(_source, _now, _expectation), do: {:error, :unauthenticated}

  # The paired client the device stands on: active, a device's, and the
  # person's own in the athanor the context works in.
  defp client?(
         %{
           id: client_id,
           user_id: user_id,
           athanor_id: athanor_id,
           standing: "active",
           source_kind: "device_cert"
         },
         client_id,
         %{user_id: user_id, athanor_id: athanor_id}
       ),
       do: true

  defp client?(_client, _client_id, _expectation), do: false

  # What the certificate the context stands under stands on. A local
  # subject's is a row this home recorded. A remote subject's may be one
  # their home issued again, which this home verifies against their head
  # and never records: it stands while the identity row names them and the
  # cached head is still at the `key_epoch` it was verified under.
  defp certified?(rows, client_id, deadline, now, %{identity: nil} = expectation),
    do: Enum.any?(rows.certificates, &certificate?(&1, client_id, deadline, now, expectation))

  defp certified?(rows, _client_id, _deadline, _now, expectation),
    do: identity?(rows.identity, expectation) and head?(rows.head, expectation)

  # The certificate row the context stands under: that client's and the
  # person's, a local subject's, expiring at the context's deadline,
  # unrevoked and unexpired on the database's clock.
  defp certificate?(
         %{
           paired_client_id: client_id,
           user_id: user_id,
           state: "active",
           expires_at: %DateTime{} = expires_at
         } = certificate,
         client_id,
         deadline,
         now,
         %{user_id: user_id}
       ) do
    DateTime.compare(expires_at, deadline) == :eq and DateTime.compare(expires_at, now) == :gt and
      local?(certificate)
  end

  defp certificate?(_certificate, _client_id, _deadline, _now, _expectation), do: false

  defp local?(%{subject_kind: "local", identifier: nil}), do: true
  defp local?(_certificate), do: false

  # A remote subject's identity row, as it reads now, still names the
  # person, remote, under the identifier the certificate was verified by.
  defp identity?(
         %{user_id: user_id, provenance: "remote", identifier: identifier},
         %{user_id: user_id, identity: %{user_id: user_id, identifier: identifier}}
       )
       when is_binary(identifier),
       do: true

  defp identity?(_row, _expectation), do: false

  # Their cached head, as it reads now under the person's lock, still names
  # the `key_epoch` the certificate was verified under.
  defp head?(
         %{identifier: identifier, key_epoch: key_epoch},
         %{identity: %{identifier: identifier}, key_epoch: key_epoch}
       )
       when is_binary(key_epoch),
       do: true

  defp head?(_head, _expectation), do: false
end
