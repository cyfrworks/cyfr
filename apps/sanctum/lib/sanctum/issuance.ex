# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Issuance do
  @moduledoc false
  # The policy a session or an API key is issued under, shared by
  # `Sanctum.Session.create/2` and `Sanctum.ApiKey`'s create and rotate.
  #
  # An issuing context must say what standing it read: its
  # `credential_binding` (an admitted sign-in's `:identity`, a session's,
  # or a key's), or — for the few fixtures that build a context by hand,
  # and only in a build compiled with `:issuance_snapshot_permitted` —
  # a `:generation_snapshot` read from the rows
  # (`Sanctum.Tenancy.generation_snapshot/2`). Neither is
  # `{:error, :missing_generation}`, and so is a key with no person behind
  # it and a person focused on an estate through no membership. The rows it names are then locked and reread inside the issuing
  # transaction (`Arca.SecurityTransitions.Issuance`): the person must be
  # active at the generation read, the focused estate active at its
  # generation read, the membership that authorized the focus still an
  # active seat, and the credential the context holds still live. A
  # generation that moved is `{:error, :stale_generation}`; a row that no
  # longer stands is `{:error, :not_standing}`.

  alias Sanctum.Context

  # config:compile-runtime-ok — the permission is compiled in on purpose: a
  # release is built without it, so no runtime setting can hand an issuance
  # a snapshot in place of its context's own binding.
  @snapshot_permitted Application.compile_env(:sanctum, :issuance_snapshot_permitted, false)

  @type expectation :: %{
          user_id: String.t(),
          user_generation: pos_integer(),
          athanor_id: String.t() | nil,
          athanor_generation: pos_integer() | nil,
          membership_id: String.t() | nil,
          source: {:session, binary()} | {:api_key, String.t()} | nil
        }

  @doc false
  @spec expectation(Context.t(), keyword()) :: {:ok, expectation()} | {:error, atom()}
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
         source: nil
       }}
    end
  end

  # A snapshot of another person or another estate proves nothing about
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
         source: source
       }}
    end
  end

  defp from_binding(%Context{}), do: {:error, :missing_generation}

  # A focused estate needs the generation it was read at; an unfocused
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
  # stamped it: the session key and the key id travel with the binding and
  # must agree with it.
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
           :ok <- estate(rows.athanor, expectation),
           :ok <- seat(rows.membership, expectation) do
        holder(rows.source, rows.now, expectation)
      end
    end
  end

  defp person(%{status: "active", security_generation: generation}, %{user_generation: generation}),
       do: :ok

  defp person(%{status: "active"}, _expectation), do: {:error, :stale_generation}
  defp person(_user, _expectation), do: {:error, :not_standing}

  defp estate(_athanor, %{athanor_id: nil}), do: :ok

  defp estate(%{status: "active", security_generation: generation}, %{
         athanor_generation: generation
       }),
       do: :ok

  defp estate(%{status: "active"}, _expectation), do: {:error, :stale_generation}
  defp estate(_athanor, _expectation), do: {:error, :not_standing}

  defp seat(_membership, %{membership_id: nil}), do: :ok

  defp seat(
         %{status: "active", user_id: user_id, scope: "athanor", athanor_id: athanor_id},
         %{user_id: user_id, athanor_id: athanor_id}
       ),
       do: :ok

  defp seat(%{status: "active", user_id: user_id, scope: "platform"}, %{user_id: user_id}),
    do: :ok

  defp seat(_membership, _expectation), do: {:error, :not_standing}

  defp holder(nil, _now, %{source: nil}), do: :ok

  defp holder(%{kind: :session, row: %{user_id: user_id, expires_at: expires_at}}, now, %{
         user_id: user_id
       }) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :not_standing}
  end

  defp holder(%{kind: :api_key, row: %{revoked: false, athanor_id: athanor_id}}, _now, %{
         athanor_id: athanor_id
       }),
       do: :ok

  defp holder(_source, _now, _expectation), do: {:error, :not_standing}
end
