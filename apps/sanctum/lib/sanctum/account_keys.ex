# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AccountKeys do
  @moduledoc """
  The keys of a person's account, as their Settings lists them
  (`session.list`): every key the account's log lists, read from the head
  this CYFR caches (`Sanctum.IdentityFreshness.keys/1`, within its
  freshness bound), in the order they were added, and under each the
  person's sessions here that it signed.

  A key is its `kid`, its `kind` (`passkey` or `device`), its short `code`
  (the first 16 hexadecimal digits of its kid, as the account pages and a
  device show it) and when it was added (`added_at`, the `at` of the
  entry that listed it). A passkey whose `add_key` named its maker has
  its `maker`, a name from the table below; a device that said hello here
  has its `name`, the display name its newest client here was paired
  with. A session is its `session_id`, the `browser` and `system` its
  sign-in named, when it was signed in and last seen, and whether it is
  the caller's own (`current`).

  This CYFR owns only the sessions: a key is the account's, and removing
  one is the account pages' (`/account/devices`). Ending one session is
  `Sanctum.Session.end_own/2`.
  """

  alias Sanctum.{Context, IdentityFreshness}

  # The makers a passkey's AAGUID names: the passkey managers and
  # security keys people most often hold, from the community list at
  # github.com/passkeydeveloper/passkey-authenticator-aaguids (aaguid.json
  # and combined_aaguid.json, read 2026-11-08; the list is retired in
  # 2027). An AAGUID not here reads as a plain passkey.
  @makers %{
    "fbfc3007-154e-4ecc-8c0b-6e020557d7bd" => "Apple Passwords",
    "dd4ec289-e01d-41c9-bb89-70fa845d4bf2" => "Apple Passwords",
    "ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4" => "Google Password Manager",
    "adce0002-35bc-c60a-648b-0b25f1f05503" => "Chrome",
    "771b48fd-d3d4-4f74-9232-fc157ab0507a" => "Edge",
    "d3452668-01fd-4c12-926c-83a4204853aa" => "Microsoft Password Manager",
    "08987058-cadc-4b81-b6e1-30de50dcbe96" => "Windows Hello",
    "9ddd1817-af5a-4672-a2b9-3e3dd95000a9" => "Windows Hello",
    "6028b017-b1d4-4c02-b4b3-afcdafc96bb2" => "Windows Hello",
    "53414d53-554e-4700-0000-000000000000" => "Samsung Pass",
    "bada5566-a7aa-401f-bd96-45619a55120d" => "1Password",
    "d548826e-79b4-db40-a3d8-11116f7e8349" => "Bitwarden",
    "531126d6-e717-415c-9320-3d9aa6981239" => "Dashlane",
    "50726f74-6f6e-5061-7373-50726f746f6e" => "Proton Pass",
    "b84e4048-15dc-4dd0-8640-f4f60813c8af" => "NordPass",
    "0ea242b4-43c4-4a1b-8b17-dd6d0b6baec6" => "Keeper",
    "b78a0a55-6ef8-d246-a042-ba0f6d55050c" => "LastPass",
    "f3809540-7f14-49c1-a8b3-8f813b225541" => "Enpass",
    "fdb141b2-5d84-443e-8a35-4698c205a502" => "KeePassXC",
    "cb69481e-8ff7-4039-93ec-0a2729a154a8" => "YubiKey",
    "ee882879-721c-4913-9775-3dfcce97072a" => "YubiKey",
    "19083c3d-8383-4b18-bc03-8f1c9ab2fd1b" => "YubiKey",
    "ff4dac45-ede8-4ec2-aced-cf66103f4335" => "YubiKey",
    "fa2b99dc-9e39-4257-8f92-4a30d23c4118" => "YubiKey",
    "2fc0579f-8113-47ea-b116-bb5a8db9202a" => "YubiKey",
    "d7781e5d-e353-46aa-afe2-3ca49f13332a" => "YubiKey",
    "a25342c0-3cdc-4414-8e46-f4807fca511c" => "YubiKey",
    "c5ef55ff-ad9a-4b9f-b580-adebafe026d0" => "YubiKey",
    "a02167b9-ae71-4ac7-9a07-06432ebb6f1c" => "YubiKey",
    "24673149-6c86-42e7-98d9-433fb5b73296" => "YubiKey",
    "d8522d9f-575b-4866-88a9-ba99fa02f35b" => "YubiKey Bio",
    "dd86a2da-86a0-4cbe-b462-4bd31f57bc6f" => "YubiKey Bio",
    "7409272d-1ff9-4e10-9fc9-ac0019c124fd" => "YubiKey Bio",
    "f8a011f3-8c0a-4d15-8006-17111f9edc7d" => "Yubico Security Key",
    "b92c3f9a-c014-4056-887f-140a2501163b" => "Yubico Security Key",
    "149a2021-8ef6-4133-96b8-81f8d5b7f1f5" => "Yubico Security Key",
    "6d44ba9b-f6ec-2e49-b930-0c8fe920cb73" => "Yubico Security Key",
    "b7d3f68e-88a6-471e-9ecf-2df26d041ede" => "Yubico Security Key",
    "a4e9fc6d-4cbe-4758-b8ba-37598bb5bbaa" => "Yubico Security Key",
    "e77e3c64-05e3-428b-8824-0cbeb04b829d" => "Yubico Security Key",
    "42b4fb4a-2866-43b2-9bf7-6c6669c2e5d3" => "Google Titan Security Key"
  }

  @typedoc "One session of the person's here, under the key that signed it."
  @type session :: %{
          session_id: String.t(),
          browser: String.t() | nil,
          system: String.t() | nil,
          signed_in_at: String.t(),
          last_seen_at: String.t(),
          current: boolean()
        }

  @typedoc "One key of the person's account (the module doc)."
  @type key :: %{
          kid: String.t(),
          kind: String.t(),
          code: String.t(),
          added_at: String.t(),
          maker: String.t() | nil,
          name: String.t() | nil,
          sessions: [session()]
        }

  @doc """
  The context person's account keys and their sessions here (the module
  doc). Refused with `:unauthenticated` for no person, the account's
  freshness refusals (`{:refused, :identity_stale | :identity_gone}`),
  and `:unavailable` when a store cannot answer.
  """
  @spec list(Context.t()) ::
          {:ok, [key()]}
          | {:error, :unauthenticated | :unavailable}
          | IdentityFreshness.refusal()
  def list(%Context{} = ctx) do
    with {:ok, user_id} <- person(ctx),
         {:ok, identifier} <- identifier(user_id),
         {:ok, head} <- fresh(identifier),
         {:ok, keys} <- listed(head),
         {:ok, sessions} <- sessions(user_id),
         {:ok, names} <- names(user_id) do
      by_kid = Enum.group_by(sessions, & &1.kid)

      {:ok,
       Enum.map(keys, fn %{key: key} = listed ->
         %{
           kid: key.kid,
           kind: Atom.to_string(key.kind),
           code: code(key.kid),
           added_at: iso(DateTime.from_unix!(listed.added_at, :millisecond)),
           maker: listed.aaguid && Map.get(@makers, listed.aaguid),
           name: if(key.kind == :device, do: Map.get(names, key.kid)),
           sessions: Enum.map(Map.get(by_kid, key.kid, []), &session(&1, ctx))
         }
       end)}
    end
  end

  defp person(%Context{plane: :guest}), do: {:error, :unauthenticated}

  defp person(%Context{authenticated: true, user_id: user_id}) when is_binary(user_id) do
    if Prima.PersonId.person?(user_id), do: {:ok, user_id}, else: {:error, :unauthenticated}
  end

  defp person(%Context{}), do: {:error, :unauthenticated}

  defp identifier(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{identifier: identifier}} when is_binary(identifier) -> {:ok, identifier}
      {:ok, _none} -> {:error, :unauthenticated}
      {:error, :not_found} -> {:error, :unauthenticated}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp fresh(identifier) do
    case IdentityFreshness.fresh?(identifier) do
      {:ok, head} -> {:ok, head}
      {:refused, _why} = refused -> refused
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp listed(head) do
    case IdentityFreshness.keys(head) do
      {:ok, keys} -> {:ok, keys}
      {:error, :corrupt} -> {:error, :unavailable}
    end
  end

  defp sessions(user_id) do
    case Arca.SessionStorage.list_live(user_id) do
      {:ok, rows} -> {:ok, rows}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # Each device's name, as its newest client here was paired with it.
  defp names(user_id) do
    case Arca.PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :active) do
      {:ok, clients} ->
        {:ok,
         clients
         |> Enum.filter(&(is_binary(&1.kid) and is_binary(&1.display_name)))
         |> Enum.sort_by(& &1.inserted_at, DateTime)
         |> Map.new(&{&1.kid, &1.display_name})}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp session(row, %Context{session_token_hash: own}) do
    %{
      session_id: row.id,
      browser: row.browser,
      system: row.system,
      signed_in_at: iso(row.inserted_at),
      last_seen_at: iso(row.last_seen_at || row.inserted_at),
      current: is_binary(own) and row.token_hash == own
    }
  end

  defp code("sha256:" <> hex), do: String.slice(hex, 0, 16)

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
