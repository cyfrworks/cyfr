# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DeviceCertifications do
  @moduledoc """
  What this home certified for its people's devices at other homes
  (`Arca.Schemas.DeviceCertification`): a person's and never an athanor's,
  since the athanor a certification names is the other home's.

  One row per person, other home (`audience_home`) and the client id that
  home reserved (`client_id`), unique on the three, so one person's
  certification never blocks another's. A row names the device key, the
  other home's athanor (`audience_athanor`), the person's identifier, the
  `key_epoch` the person confirmed it under and the latest certificate's
  expiry.

    * `certify/3` — a fresh certification, written after the person's
      confirmation: the row is inserted, or replaced whole under the same
      binding (a new device key, athanor or `key_epoch` included), active
      again.
    * `renew/3` — a renewal proven by the device key: the row's expiry
      moves, and nothing else, only while it is active, names the same
      device key and athanor, and its `key_epoch` is the person's head now.

  Both lock the person's row first, the standing order, then read their
  identity row: the person's own local identity, whose head must be the
  `key_epoch` written. A changed head refuses (`:stale_key_epoch` at a
  certification, `:certification_ended` at a renewal). Both prove first
  that this member still owns its slot (`:not_owner`).

  Every function takes the actor first: a person reaches their own rows,
  and the platform's own actor any. Rows are plain maps (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.Schemas.{DeviceCertification, PersonIdentity, User}

  @fields [
    :user_id,
    :identifier,
    :key_epoch,
    :client_id,
    :device_public_key,
    :audience_home,
    :audience_athanor,
    :expires_at
  ]

  @typedoc "A certification row, as a plain map."
  @type row :: map()

  @typedoc """
  What `certify/3` writes: `:user_id`, `:identifier`, `:key_epoch`,
  `:client_id`, `:device_public_key` (32 raw bytes), `:audience_home`,
  `:audience_athanor` and `:expires_at`.
  """
  @type certification :: %{
          required(:user_id) => String.t(),
          required(:identifier) => String.t(),
          required(:key_epoch) => String.t(),
          required(:client_id) => String.t(),
          required(:device_public_key) => binary(),
          required(:audience_home) => String.t(),
          required(:audience_athanor) => String.t(),
          required(:expires_at) => DateTime.t()
        }

  @typedoc """
  What a renewal names: the `:key_epoch` it was signed under, the
  `:device_public_key` and `:audience_athanor` it is for, and the new
  certificate's `:expires_at`.
  """
  @type renewal :: %{
          required(:key_epoch) => String.t(),
          required(:device_public_key) => binary(),
          required(:audience_athanor) => String.t(),
          required(:expires_at) => DateTime.t()
        }

  @doc """
  Record a fresh certification of the person `attrs.user_id`
  (`t:certification/0`). In one transaction: the person's row locked,
  `verify` run (the person's confirmation consumed there, `:ok` or
  `{:error, reason}`, which leaves nothing written), the identity row
  read, which must be the person's own local identity under `identifier`
  with its head at `key_epoch`, and the row inserted or replaced.

  Refusals: `:unknown_person`, `:stale_key_epoch` (the head is another, or
  the identity is not this person's local one), `verify`'s own,
  `:not_owner`, `:cross_tenant`, `{:invalid, errors}`, `:database_error`.
  """
  @spec certify(Prima.Actor.t(), certification(), (-> :ok | {:error, term()})) ::
          {:ok, row()} | {:error, term()}
  def certify(%Prima.Actor{} = actor, attrs, verify)
      when is_map(attrs) and is_function(verify, 0) do
    attrs = Map.new(attrs)

    with :ok <- person(actor, attrs[:user_id]),
         {:ok, row} <- build(attrs) do
      Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertifications.certify", fn ->
        fenced(fn -> certify_in(row, verify) end)
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  The person `user_id`'s certification for the client `client_id` of the
  home `audience_home`, or `:not_found`.
  """
  @spec get(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, user_id, audience_home, client_id)
      when is_binary(user_id) and is_binary(audience_home) and is_binary(client_id) do
    with :ok <- person(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertifications.get", fn ->
        case Arca.Repo.one(binding(user_id, audience_home, client_id)) do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Extend the certification `id` to `attrs.expires_at` (`t:renewal/0`). In
  one transaction: the person's row locked, the certification locked, and
  then, read again under those locks, the person active, the row active
  and naming `attrs.device_public_key` and `attrs.audience_athanor`, its
  `key_epoch` the renewal's, and the person's local identity's head that
  same `key_epoch`. An expiry earlier than the row's leaves it as it is.

  Refusals: `:not_found`, `:revoked`, `:not_standing` (the person is not
  active), `:binding_changed` (a fresh certification since named another
  device key or athanor), `:certification_ended` (the row's or the
  person's `key_epoch` is not the renewal's), `:not_owner`,
  `:cross_tenant`, `:database_error`.
  """
  @spec renew(Prima.Actor.t(), String.t(), renewal()) :: {:ok, row()} | {:error, term()}
  def renew(%Prima.Actor{} = actor, id, %{expires_at: %DateTime{}} = attrs) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertifications.renew", fn ->
      fenced(fn -> renew_in(actor, id, Map.update!(attrs, :expires_at, &usec/1)) end)
    end)
    |> Arca.Data.project()
  end

  # ---- internals -------------------------------------------------------------

  defp certify_in(row, verify) do
    now = Arca.ServerMetaStorage.now!()

    with {:ok, _user} <- lock_person(row.user_id),
         :ok <- verified(verify.()),
         :ok <- head(row.user_id, row.identifier, row.key_epoch, :stale_key_epoch) do
      existing =
        binding(row.user_id, row.audience_home, row.client_id)
        |> Arca.QueryHelpers.for_update()
        |> Arca.Repo.one()

      case existing do
        nil -> insert(row, now)
        %DeviceCertification{} = held -> replace(held, row, now)
      end
    end
  end

  defp insert(row, now) do
    row =
      Map.merge(row, %{
        id: Prima.UUID7.generate_id("dcf"),
        state: "active",
        revision: 1,
        inserted_at: now,
        updated_at: now
      })

    case Arca.Repo.insert_all(DeviceCertification, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, Arca.Repo.get!(DeviceCertification, row.id)}
      # A concurrent first certification of the same binding committed
      # first: the person certifies again, over it.
      {0, _} -> {:error, :conflict}
    end
  end

  defp replace(held, row, now) do
    set = [
      identifier: row.identifier,
      key_epoch: row.key_epoch,
      device_public_key: row.device_public_key,
      audience_athanor: row.audience_athanor,
      expires_at: row.expires_at,
      state: "active",
      updated_at: now
    ]

    moved(held, set)
  end

  defp renew_in(actor, id, attrs) do
    now = Arca.ServerMetaStorage.now!()

    with {:ok, owner} <- owner(actor, id),
         {:ok, user} <- lock_person(owner),
         {:ok, held} <- locked(id),
         :ok <- renewable(user, held, attrs),
         :ok <- head(held.user_id, held.identifier, held.key_epoch, :certification_ended) do
      if DateTime.compare(attrs.expires_at, held.expires_at) == :gt,
        do: moved(held, expires_at: attrs.expires_at, updated_at: now),
        else: {:ok, held}
    end
  end

  # The certification's person, read before any lock so their row is
  # locked first; a person's actor reaches only their own.
  defp owner(actor, id) do
    case Arca.Repo.one(from(c in DeviceCertification, where: c.id == ^id, select: c.user_id)) do
      nil ->
        {:error, :not_found}

      user_id ->
        case person(actor, user_id) do
          :ok -> {:ok, user_id}
          refusal -> refusal
        end
    end
  end

  defp locked(id) do
    from(c in DeviceCertification, where: c.id == ^id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      held -> {:ok, held}
    end
  end

  defp renewable(user, held, attrs) do
    cond do
      held.state != "active" -> {:error, :revoked}
      user.status != "active" -> {:error, :not_standing}
      held.key_epoch != attrs.key_epoch -> {:error, :certification_ended}
      held.device_public_key != attrs.device_public_key -> {:error, :binding_changed}
      held.audience_athanor != attrs.audience_athanor -> {:error, :binding_changed}
      true -> :ok
    end
  end

  # The person's own local identity, enrolled under `identifier`, its head
  # at `key_epoch`, read in the transaction that writes the record. A head
  # that moves while a certificate is issued leaves that certificate on the
  # old epoch, so the hub refuses it and this home renews it no more.
  defp head(user_id, identifier, key_epoch, refusal) do
    from(p in PersonIdentity,
      where: p.user_id == ^user_id,
      select: %{provenance: p.provenance, identifier: p.identifier, head_hash: p.head_hash}
    )
    |> Arca.Repo.one()
    |> case do
      %{provenance: "local", identifier: ^identifier, head_hash: ^key_epoch} -> :ok
      _other -> {:error, refusal}
    end
  end

  defp lock_person(user_id) do
    from(u in User, where: u.id == ^user_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :unknown_person}
      user -> {:ok, user}
    end
  end

  defp moved(held, set) do
    {count, _} =
      from(c in DeviceCertification, where: c.id == ^held.id and c.revision == ^held.revision)
      |> Arca.Repo.update_all(set: set, inc: [revision: 1])

    if count == 1,
      do: {:ok, Arca.Repo.get!(DeviceCertification, held.id)},
      else: {:error, :stale}
  end

  defp verified(:ok), do: :ok
  defp verified({:error, _reason} = refusal), do: refusal

  defp verified(other) do
    raise ArgumentError,
          "a certification's verify answers :ok or {:error, reason}, got " <>
            Prima.LoggerContext.shape(other)
  end

  defp binding(user_id, audience_home, client_id) do
    from(c in DeviceCertification,
      where:
        c.user_id == ^user_id and c.audience_home == ^audience_home and
          c.client_id == ^client_id
    )
  end

  defp person(%Prima.Actor{scope: :platform}, _user_id), do: :ok

  defp person(%Prima.Actor{user_id: user_id}, user_id) when is_binary(user_id) and user_id != "",
    do: :ok

  defp person(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  defp build(attrs) do
    errors =
      [
        {:user_id, nonempty?(attrs[:user_id])},
        {:identifier, Prima.Identity.Encoding.identifier?(attrs[:identifier])},
        {:key_epoch, Prima.Identity.Encoding.digest?(attrs[:key_epoch])},
        {:client_id, Prima.Identity.Encoding.id?(attrs[:client_id])},
        {:device_public_key, Prima.Identity.Encoding.key?(attrs[:device_public_key])},
        {:audience_home, Prima.Identity.Encoding.home?(attrs[:audience_home])},
        {:audience_athanor, Prima.Identity.Encoding.id?(attrs[:audience_athanor])},
        {:expires_at, match?(%DateTime{}, attrs[:expires_at])}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)

    if errors == %{},
      do: {:ok, attrs |> Map.take(@fields) |> Map.update!(:expires_at, &usec/1)},
      else: {:error, {:invalid, errors}}
  end

  # The column's precision, whatever precision the caller's clock gave.
  defp usec(%DateTime{microsecond: {value, _precision}} = at), do: %{at | microsecond: {value, 6}}

  defp nonempty?(value), do: is_binary(value) and value != ""

  # A certification lets a device act for its person at another home, so
  # each write first proves this member still owns its slot on the
  # database's clock (`Arca.ControlPlane.verify_held/1`): a stale owner
  # writes nothing.
  defp fenced(write) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot() do
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> committed(write.())
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)
end
