# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DeviceCertificates do
  @moduledoc """
  The device certificates this home issued (`Arca.Schemas.DeviceCertificate`),
  one row per certificate, scoped by athanor and tied to the paired client
  it was issued to.

  A certificate is `active`, `revoked` or `expired`: `revoked` is stored
  and terminal, and `expired` is read from the database's clock against
  the certificate's own expiry, never extended by any later read. Every
  row is answered with its `status`, one of the three, as of that read.

  Recording a certificate widens what a device may do, so `record/2`
  proves first that this member still owns its slot (`:not_owner`), and
  records only for a paired client that stands in the actor's athanor, for
  the same person, whose recorded `device_public_key` is the certificate's:
  a client paired without a device key (a `session` or `api_key` source)
  is never certified. An identity-subject certificate binds the `key_epoch`
  current when it is recorded (`Arca.DirectoryHeads.certifiable!/3`, under
  the person's lock), so a head that retires the epoch either revokes it
  or refuses it. A revocation only narrows and is never
  refused for ownership; revoking a revoked certificate answers it as it
  is. A standing transition revokes the certificates it retires in its
  own transaction (`Arca.SecurityTransitions`), and a head that retires an
  identity's `key_epoch` revokes the identity-subject certificates issued
  under it (`revoke_key_epoch!/2`).

  Every function takes the actor first, and the athanor comes from it.
  Rows are plain maps (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{DeviceCertificate, PairedClient}

  @typedoc "A certificate row, as a plain map with its `status`."
  @type row :: map()

  @typedoc """
  What `list/2` narrows by: `paired_client_id`, `user_id`, and `status`
  (`:active`, the default, `:revoked`, `:expired` or `:all`).
  """
  @type filters :: [
          paired_client_id: String.t(),
          user_id: String.t(),
          status: :active | :revoked | :expired | :all
        ]

  @doc """
  Record a certificate issued to a paired client of the actor's athanor.
  `attrs`: `:paired_client_id`, `:user_id`, `:subject_kind` (`"local"`, or
  `"identity"` with the `:identifier` and `:key_epoch` it was issued
  under), `:device_public_key`, `:issuing_home`, `:audience_home`,
  `:not_before`, `:expires_at`, the signed `:certificate` bytes and their
  `:digest`. Refusals: `:client_not_active` (no standing client of that
  person), `:no_device_key` (the client was paired without one),
  `:device_key_mismatch` (the client's device key is another),
  `:stale_key_epoch`, `:conflict` (the digest is already recorded),
  `:not_owner`, `:no_athanor`, `{:invalid, errors}`, `:database_error`.
  """
  @spec record(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def record(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    with {:ok, row} <- build(QueryHelpers.stamp_tenant!(actor, Map.new(attrs))) do
      Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertificates.record", fn ->
        fenced(fn -> record_in(athanor_id, row) end)
      end)
      |> Arca.Data.project()
    end
  end

  def record(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc "The certificate `id` in the actor's athanor, with its status."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertificates.get", fn ->
      now = Arca.ServerMetaStorage.now!()

      DeviceCertificate
      |> QueryHelpers.where_tenant(actor)
      |> where([c], c.id == ^id)
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        certificate -> {:ok, with_status(certificate, now)}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc "The certificates of the actor's athanor, newest first, narrowed by `filters`."
  @spec list(Prima.Actor.t(), filters()) ::
          {:ok, [row()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor, filters)
      when is_binary(athanor_id) and athanor_id != "" and is_list(filters) do
    Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertificates.list", fn ->
      now = Arca.ServerMetaStorage.now!()

      rows =
        DeviceCertificate
        |> QueryHelpers.where_tenant(actor)
        |> by(:paired_client_id, Keyword.get(filters, :paired_client_id))
        |> by(:user_id, Keyword.get(filters, :user_id))
        |> by_status(Keyword.get(filters, :status, :active), now)
        |> order_by([c], desc: c.inserted_at, desc: c.id)
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &with_status(&1, now))}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _filters), do: {:error, :no_athanor}

  @doc """
  The paired client's newest certificate that is active now, or
  `{:error, :not_found}`.
  """
  @spec current(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def current(%Prima.Actor{athanor_id: athanor_id} = actor, paired_client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(paired_client_id) do
    case list(actor, paired_client_id: paired_client_id, status: :active) do
      {:ok, [newest | _]} -> {:ok, newest}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = refusal -> refusal
    end
  end

  def current(%Prima.Actor{}, _paired_client_id), do: {:error, :no_athanor}

  @doc "Revoke the certificate `id` in the actor's athanor; a revoked one answers as it is."
  @spec revoke(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def revoke(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertificates.revoke", fn ->
      Arca.Repo.locking_transaction(fn ->
        mine = DeviceCertificate |> QueryHelpers.where_tenant(actor) |> where([c], c.id == ^id)

        case Arca.Repo.exists?(mine) do
          true ->
            _ = revoke_all(mine)
            with_status(Arca.Repo.one!(mine), Arca.ServerMetaStorage.now!())

          false ->
            Arca.Repo.rollback(:not_found)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def revoke(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Revoke every certificate of the paired client `paired_client_id` in the
  actor's athanor, answering the ids it revoked, sorted.
  """
  @spec revoke_for_client(Prima.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def revoke_for_client(%Prima.Actor{athanor_id: athanor_id} = actor, paired_client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(paired_client_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.DeviceCertificates.revoke_for_client", fn ->
      Arca.Repo.locking_transaction(fn ->
        DeviceCertificate
        |> QueryHelpers.where_tenant(actor)
        |> where([c], c.paired_client_id == ^paired_client_id)
        |> revoke_all()
      end)
    end)
  end

  def revoke_for_client(%Prima.Actor{}, _paired_client_id), do: {:error, :no_athanor}

  @doc false
  # Revoke every active certificate `query` names, in the caller's
  # transaction or its own statement, answering the ids it revoked, sorted.
  # The one revocation statement: the standing transitions run it inside
  # theirs (`Arca.SecurityTransitions`).
  @spec revoke_all(Ecto.Queryable.t()) :: [String.t()]
  # arca:unscoped-ok the caller's query carries its own scope: an athanor, a person or an epoch.
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def revoke_all(query) do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(c in query, where: c.state != "revoked", select: c.id),
        set: [state: "revoked", revoked_at: now, updated_at: now]
      )

    Enum.sort(ids || [])
  end

  @doc false
  # The identity-subject certificates issued under `key_epoch` for
  # `identifier`, revoked when a fresh head retires it
  # (`Arca.DirectoryHeads.advance/4`).
  @spec revoke_key_epoch!(String.t(), String.t()) :: [String.t()]
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def revoke_key_epoch!(identifier, key_epoch)
      when is_binary(identifier) and is_binary(key_epoch) do
    revoke_all(
      from(c in DeviceCertificate,
        where:
          c.subject_kind == "identity" and c.identifier == ^identifier and
            c.key_epoch == ^key_epoch
      )
    )
  end

  # ---- internals -------------------------------------------------------------

  # The person first, then the cached head, then the client: the standing
  # order, and the order `Arca.DirectoryHeads.advance/4` takes.
  defp record_in(athanor_id, row) do
    with :ok <- epoch_current(row) do
      record_for_client(athanor_id, row)
    end
  end

  defp epoch_current(%{subject_kind: "identity"} = row),
    do: Arca.DirectoryHeads.certifiable!(row.user_id, row.identifier, row.key_epoch)

  defp epoch_current(row) do
    Arca.DirectoryHeads.lock_person!(row.user_id)
    :ok
  end

  defp record_for_client(athanor_id, row) do
    standing =
      from(p in PairedClient,
        where:
          p.athanor_id == ^athanor_id and p.id == ^row.paired_client_id and
            p.user_id == ^row.user_id and p.standing == "active"
      )
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    cond do
      is_nil(standing) ->
        {:error, :client_not_active}

      is_nil(standing.device_public_key) ->
        {:error, :no_device_key}

      standing.device_public_key != row.device_public_key ->
        {:error, :device_key_mismatch}

      true ->
        case Arca.Repo.insert_all(DeviceCertificate, [row], on_conflict: :nothing) do
          {1, _} ->
            {:ok,
             with_status(Arca.Repo.get!(DeviceCertificate, row.id), Arca.ServerMetaStorage.now!())}

          {0, _} ->
            {:error, :conflict}
        end
    end
  end

  defp with_status(%DeviceCertificate{} = certificate, now) do
    status =
      cond do
        certificate.state == "revoked" -> "revoked"
        DateTime.compare(certificate.expires_at, now) != :gt -> "expired"
        true -> "active"
      end

    certificate |> Arca.Data.project() |> Map.put(:status, status)
  end

  defp by(query, _field, nil), do: query
  defp by(query, field, value), do: where(query, [c], field(c, ^field) == ^value)

  defp by_status(query, :all, _now), do: query

  defp by_status(query, :active, now),
    do: where(query, [c], c.state == "active" and c.expires_at > ^now)

  defp by_status(query, :revoked, _now), do: where(query, [c], c.state == "revoked")

  defp by_status(query, :expired, now),
    do: where(query, [c], c.state == "active" and c.expires_at <= ^now)

  defp build(attrs) do
    subject = attrs[:subject_kind]

    checks = [
      {:paired_client_id, is_binary(attrs[:paired_client_id]) and attrs[:paired_client_id] != ""},
      {:user_id, is_binary(attrs[:user_id]) and attrs[:user_id] != ""},
      {:subject_kind, subject in DeviceCertificate.subject_kinds()},
      {:identifier,
       if(subject == "identity",
         do: Prima.Identity.Encoding.identifier?(attrs[:identifier]),
         else: is_nil(attrs[:identifier])
       )},
      {:key_epoch,
       if(subject == "identity",
         do: Prima.Identity.Encoding.digest?(attrs[:key_epoch]),
         else: is_nil(attrs[:key_epoch])
       )},
      {:device_public_key, Prima.Identity.Encoding.key?(attrs[:device_public_key])},
      {:issuing_home, Prima.Identity.Encoding.home?(attrs[:issuing_home])},
      {:audience_home, Prima.Identity.Encoding.home?(attrs[:audience_home])},
      {:not_before, match?(%DateTime{}, attrs[:not_before])},
      {:expires_at, match?(%DateTime{}, attrs[:expires_at])},
      {:certificate, is_binary(attrs[:certificate]) and attrs[:certificate] != ""},
      {:digest, Prima.Identity.Encoding.digest?(attrs[:digest])}
    ]

    errors =
      checks
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)

    errors =
      if errors == %{} and DateTime.compare(attrs.expires_at, attrs.not_before) != :gt,
        do: Map.put(errors, :expires_at, ["is after not_before"]),
        else: errors

    if errors == %{} do
      now = DateTime.utc_now()

      {:ok,
       attrs
       |> Map.take([
         :athanor_id,
         :paired_client_id,
         :user_id,
         :subject_kind,
         :identifier,
         :key_epoch,
         :device_public_key,
         :issuing_home,
         :audience_home,
         :not_before,
         :expires_at,
         :certificate,
         :digest
       ])
       |> Map.merge(%{
         not_before: usec(attrs.not_before),
         expires_at: usec(attrs.expires_at),
         id: Prima.UUID7.generate_id("dct"),
         identifier: attrs[:identifier],
         key_epoch: attrs[:key_epoch],
         state: "active",
         revoked_at: nil,
         inserted_at: now,
         updated_at: now
       })}
    else
      {:error, {:invalid, errors}}
    end
  end

  # A caller's instant stored at the column's microsecond precision,
  # whatever precision it arrived with.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  # Recording a certificate widens what a device may do, so its transaction
  # first proves this member still owns its slot on the database's clock
  # (`Arca.ControlPlane.verify_held/1`): a stale owner records nothing.
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
