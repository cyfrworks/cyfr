# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions.Issuance do
  @moduledoc """
  The one transaction a credential is issued in: the rows its standing
  rests on locked and reread, the caller's policy asked over them, and the
  credential written only if it agrees — all before commit, so a
  transition that retires that standing either commits first, and the
  issuance rereads its result, or waits for the credential and then
  retires it.

  `targets` names the rows: the person (`:user_id`), the athanor the
  credential works in (`:athanor_id`, or nil), the membership that
  authorized the caller's focus (`:membership_id`, or nil) and the
  credential the caller holds (`:source`: `{:session, token_hash}`,
  `{:api_key, id}`, `{:device, client_id, expires_at}`, or nil). They are
  locked in the order every standing transition takes
  (`Arca.SecurityTransitions`): person, athanor, membership, then the
  session, the key, or the paired client and its certificates; the
  credential `write` changes comes last.

  A paired device's source is its paired-client row, locked after the
  person, the athanor and the membership, and the certificates of that
  client that expire at `expires_at`, the expiry of the one the caller's
  context stands under, locked after it. So a revocation of the client or
  of its certificates that commits before the issuance reaches the
  client is read here and refused by the caller's policy, and one that
  starts later waits for the credential, which the revocation does not
  take back. Beside them it reads, without locking, the person's identity
  row, which a person whose keys are at another home was resolved by, and
  for such a person their cached head (`Arca.DirectoryHeads`), whose
  `key_epoch` their certificate stands on: this home keeps no row for a
  certificate their own home issued them again. Both are read under the
  person's lock, which `Arca.DirectoryHeads.advance/4` takes before it
  moves a head, so neither moves while the issuance holds the person.

  `verify` is handed plain maps of those rows, each nil when there is no
  such row, and the database's own time read after every lock was won —
  an expiry is judged on that instant, never on one taken before a wait.
  `write` runs only after `verify` answers `:ok` and answers
  `{:ok, result}` or `{:error, reason}`; either refusal rolls everything
  back.
  """

  import Ecto.Query

  alias Arca.QueryHelpers

  alias Arca.Schemas.{
    ApiKey,
    Athanor,
    DeviceCertificate,
    DirectoryHead,
    Membership,
    PairedClient,
    PersonIdentity,
    Session,
    User
  }

  alias Arca.SecurityTransitions.Projection

  # What a device's policy reads of its rows, and nothing more: no device
  # key, no certificate bytes, no sealed key material.
  @paired_client ~w(id user_id athanor_id source_kind standing)a
  @device_certificate ~w(id paired_client_id user_id subject_kind identifier key_epoch expires_at state)a
  @person_identity ~w(user_id provenance identifier)a
  @directory_head ~w(identifier key_epoch)a

  @type source ::
          {:session, binary()}
          | {:api_key, String.t()}
          | {:device, String.t(), DateTime.t()}
          | nil
  @type targets :: %{
          required(:user_id) => String.t(),
          required(:athanor_id) => String.t() | nil,
          required(:membership_id) => String.t() | nil,
          required(:source) => source()
        }

  @doc "Lock `targets`' rows, ask `verify`, then `write`, in one locking transaction."
  @spec run(
          targets(),
          (map() -> :ok | {:error, term()}),
          (map() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  # arca:db-raise-ok a transaction step: every caller (`Arca.SessionStorage`, `Arca.ApiKeyStorage`) rescues around it.
  def run(%{user_id: user_id} = targets, verify, write)
      when is_binary(user_id) and is_function(verify, 1) and is_function(write, 1) do
    fn ->
      projection = locked(targets)

      with :ok <- verify.(projection),
           {:ok, result} <- write.(projection) do
        result
      else
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end
    |> Arca.Repo.locking_transaction()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run `write`, a credential write that is not itself an issuance's (a
  webhook secret, a vault entry), under the issuance `opts` names: with
  `lock:` and `verify:`, as `run/3` takes them, `write` runs in that
  transaction once the rows are locked and `verify` agrees; with neither,
  it runs alone, as it would without one. `write` answers `{:ok, result}`
  or `{:error, reason}`, and a refusal under an issuance rolls it back.
  Naming one of `lock:` and `verify:` without the other is an
  `ArgumentError`.
  """
  @spec held(keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  # arca:db-raise-ok a transaction step: every caller (`Arca.WebhookStorage`, `Arca.VaultStorage`, `Arca.ProviderCredentialStorage`) rescues around it.
  def held(opts, write) when is_list(opts) and is_function(write, 0) do
    case {Keyword.get(opts, :lock), Keyword.get(opts, :verify)} do
      {nil, nil} ->
        write.()

      {%{} = targets, verify} when is_function(verify, 1) ->
        run(targets, verify, fn _locked -> write.() end)

      _partial ->
        raise ArgumentError, "an issuance names both its targets and its policy, or neither"
    end
  end

  @doc false
  # The rows `targets` names, locked in the standing order and projected,
  # with the database's own time read after every lock was won. Runs
  # inside the caller's locking transaction; `Arca.CredentialBindings`
  # reads a derived credential's rows through it too.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  @spec locked(targets()) :: map()
  def locked(%{user_id: user_id} = targets) when is_binary(user_id) do
    %{
      user: Projection.user(lock_user(user_id)),
      athanor: Projection.athanor(lock_athanor(Map.get(targets, :athanor_id))),
      membership: Projection.membership(lock_membership(Map.get(targets, :membership_id))),
      source: lock_source(Map.get(targets, :source), user_id),
      now: Arca.ServerMetaStorage.now!()
    }
  end

  defp lock_user(user_id) do
    from(u in User, where: u.id == ^user_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp lock_athanor(athanor_id) when is_binary(athanor_id) do
    from(a in Athanor, where: a.id == ^athanor_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp lock_athanor(_athanor_id), do: nil

  # arca:unscoped-ok the membership an issuing context was focused through, by its own id; a platform row names no athanor.
  defp lock_membership(membership_id) when is_binary(membership_id) do
    from(m in Membership, where: m.id == ^membership_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp lock_membership(_membership_id), do: nil

  # arca:unscoped-ok a session addressed by its token hash, the credential the caller holds.
  defp lock_source({:session, token_hash}, _user_id) when is_binary(token_hash) do
    session =
      from(s in Session, where: s.token_hash == ^token_hash)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    %{kind: :session, row: Projection.session(session)}
  end

  # arca:unscoped-ok an API key addressed by its own id, the credential the caller holds.
  defp lock_source({:api_key, id}, _user_id) when is_binary(id) do
    key =
      from(k in ApiKey, where: k.id == ^id)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    %{kind: :api_key, row: Projection.api_key(key)}
  end

  # The paired client, then the certificates it holds at the caller's
  # expiry, each locked: the order every standing transition takes, so a
  # revocation waiting on the client never holds a certificate this waits
  # on. The identity row and then the cached head of a remote person are
  # read, not locked, under the person's lock: a head moves only under
  # that lock (`Arca.DirectoryHeads.advance/4` takes the person first), so
  # neither moves while the issuance holds the person.
  # arca:unscoped-ok a paired client addressed by its own id, the credential the caller holds; the caller's policy holds it to the person and athanor locked before it.
  defp lock_source({:device, client_id, %DateTime{} = expires_at}, user_id)
       when is_binary(client_id) do
    client =
      from(p in PairedClient, where: p.id == ^client_id)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    certificates = lock_certificates(client, usec(expires_at))
    identity = Arca.Repo.one(from(p in PersonIdentity, where: p.user_id == ^user_id))

    %{
      kind: :device,
      row: narrowed(client, @paired_client),
      certificates: Enum.map(certificates, &narrowed(&1, @device_certificate)),
      identity: narrowed(identity, @person_identity),
      head: narrowed(cached_head(identity), @directory_head)
    }
  end

  defp lock_source(_source, _user_id), do: nil

  # A remote person's head as this home caches it; a local person's
  # certificates stand on their rows, and no head is read for them.
  defp cached_head(%PersonIdentity{provenance: "remote", identifier: identifier})
       when is_binary(identifier),
       do: Arca.Repo.one(from(h in DirectoryHead, where: h.identifier == ^identifier))

  defp cached_head(_identity), do: nil

  # The client's certificates in the client's own athanor that expire at
  # the caller's expiry; none for a client that is not there.
  defp lock_certificates(nil, _expires_at), do: []

  defp lock_certificates(%PairedClient{id: client_id, athanor_id: athanor_id}, expires_at) do
    from(c in DeviceCertificate,
      where:
        c.athanor_id == ^athanor_id and c.paired_client_id == ^client_id and
          c.expires_at == ^expires_at,
      order_by: [asc: c.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  defp narrowed(nil, _fields), do: nil
  defp narrowed(row, fields), do: row |> Arca.Data.project() |> Map.take(fields)

  # The caller's instant at the column's microsecond precision, as a
  # certificate's expiry is stored (`Arca.DeviceCertificates.record/2`).
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
end
