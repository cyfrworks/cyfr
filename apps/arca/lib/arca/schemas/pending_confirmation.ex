# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PendingConfirmation do
  @moduledoc """
  Ecto schema for the `pending_confirmations` table (backs
  `Arca.PendingConfirmations`): one pending confirmation of a sensitive
  change in an athanor, as `Prima.Confirmation` shapes it, keyed by its
  public `ref` and never by the secret its asking request holds, with the
  credential that opened it (`opener`), a name for the client that asked
  (`asker`), how it was proven and its state.
  """

  use Ecto.Schema

  @primary_key {:ref, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @states ~w(pending confirmed consumed cancelled voided expired)
  @proofs ~w(passkey oidc_reauth email_code)

  @doc "The states a confirmation moves through; all but the first two are terminal."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The proofs a confirmation may be confirmed with."
  @spec proofs() :: [String.t()]
  def proofs, do: @proofs

  schema "pending_confirmations" do
    field :athanor_id, :string
    field :user_id, :string
    field :operation, :string
    field :args_digest, :string
    field :action, :string
    field :preview, :string
    field :home, :string
    field :rp_id, :string
    field :challenge, :binary
    field :digest, :string
    field :opener, :string
    field :asker, :string
    field :identity_key_epoch, :string
    field :state, :string, default: "pending"
    field :proof, :string
    field :confirmed_client_id, :string
    field :confirmed_passkey_id, :string
    field :reauth_nonce, :string
    field :email_code_hash, :string, redact: true
    field :email_code_failures, :integer, default: 0
    field :opened_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
