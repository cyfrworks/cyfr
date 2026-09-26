# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Pairing do
  @moduledoc """
  Confirmation authority: which confirmation class (`Prima.ConfirmationClass`)
  a client holds, and which class an action requires.

  Display authority, pointer input and confirmation authority are three
  contracts. A client that draws a prompt, or that the person points at,
  confirms nothing by doing so: what it may confirm is the class assigned
  here from its standing, and the consent decision for a confirming intent
  checks that class (`confirm?/2`) and nothing else does. The system layer
  presents a prompt and never decides it.

  ## The classes a client holds

  Every authenticated browser session and API key on the external plane
  is a `session` client; anything else — a guest body, an anonymous or
  unauthenticated caller, a tincture, webhook, schedule or system context
  — is `none` and confirms nothing. The pairing ceremony that makes a
  `paired` client and the enrolment that makes a `strong` one are not
  here yet, so no client holds either.

  ## The class an action requires

  | Action | Minimum class |
  |---|---|
  | `:grant` | `session` |
  | `:approval` | `session` |
  | `:credential_entry` | `session` |
  | `:vault_unlock` | `session` |
  | `:home_transfer` | `strong` |
  | `:pairing_revocation` | `strong` |

  Credential entry and the vault unlock require `session` until a
  `strong` client is enrolled for the athanor, and `strong` once one is;
  with no enrolment yet, they work from a browser exactly as they always
  have. An action whose minimum class no client of the athanor holds
  waits for one: its requirement never degrades to the class that is
  present.
  """

  alias Prima.ConfirmationClass
  alias Sanctum.Context

  @required %{
    grant: :session,
    approval: :session,
    credential_entry: :session,
    vault_unlock: :session,
    home_transfer: :strong,
    pairing_revocation: :strong
  }

  @typedoc "An action that needs a confirmation."
  @type action ::
          :grant
          | :approval
          | :credential_entry
          | :vault_unlock
          | :home_transfer
          | :pairing_revocation

  @doc "Every action the class table names."
  @spec actions() :: [action()]
  def actions, do: @required |> Map.keys() |> Enum.sort()

  @doc """
  The confirmation class the client behind `ctx` holds: `:session` for an
  authenticated, non-anonymous session (`:oidc`) or API key context on
  the external plane, `:none` for every other context.
  """
  @spec class_of(Context.t()) :: ConfirmationClass.t()
  def class_of(%Context{plane: :external, anonymous: false, auth_method: method} = ctx)
      when method in [:oidc, :api_key] do
    if ctx.authenticated == true and is_binary(ctx.user_id) and ctx.user_id != "",
      do: :session,
      else: :none
  end

  def class_of(%Context{}), do: :none

  @doc "The minimum class `action` requires (see the module doc's table)."
  @spec required_class(action()) :: ConfirmationClass.t()
  def required_class(action) when is_map_key(@required, action), do: Map.fetch!(@required, action)

  @doc """
  Whether the client behind `ctx` may confirm `action`: `:ok` when its
  class is at least the action's minimum, `{:error, :class_too_low}`
  otherwise. An action the table does not name is never confirmed.
  """
  @spec confirm?(Context.t(), action()) :: :ok | {:error, :class_too_low}
  def confirm?(%Context{} = ctx, action) when is_map_key(@required, action) do
    if ConfirmationClass.at_least?(class_of(ctx), required_class(action)),
      do: :ok,
      else: {:error, :class_too_low}
  end

  def confirm?(%Context{}, _action), do: {:error, :class_too_low}
end
