# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Pairing do
  @moduledoc """
  Which changes need a fresh confirmation, and which clients can give one.

  Three facts stay apart: who a person is, established by their session;
  which devices they have connected; and whether a change needs a fresh
  confirmation. None of them is a rank, and the rule is the same for every
  person: members stay equals.

  ## The action table

  Each action a confirmation can concern, and what it needs:

  | Action | Needs |
  |---|---|
  | `:grant` | the session |
  | `:approval` | the session |
  | `:credential_entry` | a fresh confirmation |
  | `:credential_issuance` | a fresh confirmation |
  | `:vault_unlock` | a fresh confirmation |
  | `:home_transfer` | a fresh confirmation |
  | `:pairing_revocation` | a fresh confirmation |
  | `:recovery_material` | a fresh confirmation |
  | `:device_pairing` | a fresh confirmation |
  | `:passkey_registration` | a fresh confirmation |
  | `:remote_sign_in` | a fresh confirmation |
  | `:key_rotation` | a fresh confirmation |
  | `:sign_in_methods` | a fresh confirmation |

  `sensitive?/1` answers the table. `vault_unlock` and `home_transfer`
  have no operation until their features land, and stay sensitive.
  `action_for/1` maps each operation that confirms something to its
  action.

  `fresh_required?/2` is what the deciding sites ask
  (`Sanctum.Consent.Authz.confirm/3`). It answers `false` for every
  action until a proof can be given — a passkey assertion or a fresh
  re-authentication over a pending confirmation — so no change asks for a
  proof before one exists.

  ## Who can confirm

  `can_confirm?/1` answers whether the context has a person behind it who
  can give a proof: a signed-in browser session (`:oidc`). A paired
  device (`:device`) confirms once its paired client's standing is read
  here; until then it confirms nothing. A key, a guest body, a tincture, a
  webhook, a schedule, the system and an anonymous caller confirm nothing.
  The system layer reads it to hide a control and never decides by it: the
  operation a confirmation dispatches is decided where the change is.
  """

  alias Sanctum.Context

  @table %{
    grant: :session,
    approval: :session,
    credential_entry: :fresh,
    credential_issuance: :fresh,
    vault_unlock: :fresh,
    home_transfer: :fresh,
    pairing_revocation: :fresh,
    recovery_material: :fresh,
    device_pairing: :fresh,
    passkey_registration: :fresh,
    remote_sign_in: :fresh,
    key_rotation: :fresh,
    sign_in_methods: :fresh
  }

  # Each operation that confirms something, as `tool.action`, the spelling
  # a pending confirmation records (`Prima.Confirmation`).
  @operations %{
    "vault.create" => :credential_entry,
    "vault.rotate" => :credential_entry,
    "vault.authorize" => :credential_entry,
    "oauth.set_client" => :credential_entry,
    "key.create" => :credential_issuance,
    "key.rotate" => :credential_issuance,
    "webhook.create" => :credential_issuance,
    "webhook.rotate" => :credential_issuance,
    "pairing.revoke" => :pairing_revocation,
    "person.enroll" => :recovery_material,
    "person.kit" => :recovery_material,
    "person.enroll_holder" => :recovery_material,
    "passkey.register" => :passkey_registration,
    "passkey.revoke" => :passkey_registration,
    "passkey.recover_admin" => :passkey_registration,
    "pairing.begin" => :device_pairing,
    "person.certify" => :device_pairing,
    "person.assert" => :remote_sign_in,
    "person.rotate" => :key_rotation,
    "person.link_door" => :sign_in_methods,
    "person.unlink_door" => :sign_in_methods
  }

  @typedoc "An action the table names."
  @type action ::
          :grant
          | :approval
          | :credential_entry
          | :credential_issuance
          | :vault_unlock
          | :home_transfer
          | :pairing_revocation
          | :recovery_material
          | :device_pairing
          | :passkey_registration
          | :remote_sign_in
          | :key_rotation
          | :sign_in_methods

  @doc "Every action the table names, sorted."
  @spec actions() :: [action()]
  def actions, do: @table |> Map.keys() |> Enum.sort()

  @doc """
  Whether the table names `action` a sensitive change, one that needs a
  fresh confirmation for every person, rather than the session alone.
  """
  @spec sensitive?(action()) :: boolean()
  def sensitive?(action) when is_map_key(@table, action), do: Map.fetch!(@table, action) == :fresh

  @doc """
  The action the operation `operation` (`tool.action`) confirms, or `nil`
  for an operation that confirms nothing.
  """
  @spec action_for(String.t()) :: action() | nil
  def action_for(operation) when is_binary(operation), do: Map.get(@operations, operation)

  @doc """
  Whether `action`, asked for under `ctx`, needs a fresh confirmation
  before it is decided. `false` for every action until a proof can be
  given (see the module doc).
  """
  @spec fresh_required?(action(), Context.t()) :: false
  def fresh_required?(action, %Context{}) when is_map_key(@table, action), do: false

  @doc """
  Whether the client behind `ctx` has a person behind it who can give a
  proof: an authenticated, non-anonymous browser session (`:oidc`) on the
  external plane that names its person and no paired client. Every other
  context — a paired device until its standing is read here, a key, a
  guest body, a tincture, a webhook, a schedule, the system — `false`.
  """
  @spec can_confirm?(Context.t()) :: boolean()
  def can_confirm?(%Context{plane: :external, authenticated: true, anonymous: false} = ctx),
    do: ctx.auth_method == :oidc and is_nil(ctx.client_id) and person?(ctx.user_id)

  def can_confirm?(%Context{}), do: false

  defp person?(user_id), do: is_binary(user_id) and user_id != ""
end
