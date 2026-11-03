# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Members do
  @moduledoc """
  Membership assignments — "user X is a member of athanor A", the person's
  seat in their own athanor.

  A membership row is a presence-only grant: its existence makes the user a
  member. An athanor has one, its owner's, written with it
  (`Sanctum.Tenancy.Athanors.create_personal/2`). A `"platform"` row names
  no athanor: it makes the user a platform admin, the server's operator.
  The one platform row is the installation's first person's, written by
  their admission (`Sanctum.Newcomer`, `Arca.Members.grant_platform!/1`);
  nothing here writes one.

  Every change is announced (`Sanctum.Telemetry.membership_changed/3`),
  keyed by the person, so a mounted LiveView can re-derive what it shows.

  The statements are `Arca.Members`'. A row inside one athanor is written
  and read as the server narrowed to that athanor; the rows that name no
  athanor, or that name a person across every athanor, run as the server
  itself.
  """

  @typedoc "A membership row, as the plain map `Arca.Members` answers."
  @type membership :: %{required(:id) => String.t(), optional(atom()) => term()}

  @doc """
  Insert an athanor membership. `attrs` carries `:user_id` and
  `:athanor_id`, which must name an existing athanor. A platform row is no
  membership this writes (`{:error, :no_athanor}`).
  """
  @spec create(map()) :: {:ok, membership()} | {:error, term()}
  def create(attrs) do
    attrs = Map.new(attrs)

    if Map.get(attrs, :scope) == "platform",
      do: {:error, :no_athanor},
      else: Arca.Members.seat(in_athanor(Map.get(attrs, :athanor_id)), attrs)
  end

  @doc """
  Idempotently ensure an active membership exists for `user_id`.

  Opts: `:scope` (required — the two scopes are different grants and neither
  is a default), `:athanor_id` and `:added_by`. Safe under concurrent first
  sign-ins — a unique-constraint conflict resolves to a re-read of the
  existing row.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, membership()} | {:error, term()}
  def ensure(user_id, opts) when is_binary(user_id) do
    scope = Keyword.fetch!(opts, :scope)
    athanor_id = Keyword.get(opts, :athanor_id)

    # Read-before-write: the membership almost always already exists, so
    # probing first avoids a failed INSERT on every later call. A concurrent
    # call can still race past the probe; the INSERT's conflict then
    # resolves to a re-read.
    case find(user_id, scope, athanor_id) do
      {:ok, membership} ->
        {:ok, membership}

      _ ->
        case create(%{
               user_id: user_id,
               scope: scope,
               athanor_id: athanor_id,
               added_by: Keyword.get(opts, :added_by)
             }) do
          {:ok, membership} -> {:ok, membership}
          {:error, :conflict} -> find(user_id, scope, athanor_id)
          other -> other
        end
    end
  end

  @doc "Is `user_id` an active member of the athanor?"
  @spec member?(String.t() | nil, String.t()) :: boolean()
  def member?(user_id, athanor_id), do: match?({:ok, _seat}, active_seat(user_id, athanor_id))

  @doc """
  The active membership row seating `user_id` in the athanor: `{:ok, row}`,
  `:none`, or `{:error, reason}` when the store cannot answer. Its id is
  what a focus on that athanor is bound to
  (`t:Sanctum.Context.credential_binding/0`).
  """
  @spec active_seat(String.t() | nil, String.t() | nil) ::
          {:ok, membership()} | :none | {:error, term()}
  def active_seat(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    case find(user_id, "athanor", athanor_id) do
      {:ok, %{status: "active"} = row} -> {:ok, row}
      {:ok, %{}} -> :none
      {:error, :not_found} -> :none
      {:error, _} = err -> err
    end
  end

  def active_seat(_user_id, _athanor_id), do: :none

  @doc "The person's platform row, as `active_seat/2` answers: `{:ok, row}`, `:none` or `{:error, reason}`."
  @spec platform_seat(String.t() | nil) :: {:ok, membership()} | :none | {:error, term()}
  def platform_seat(user_id) when is_binary(user_id) do
    case find(user_id, "platform", nil) do
      {:ok, %{status: "active"} = row} -> {:ok, row}
      {:ok, %{}} -> :none
      {:error, :not_found} -> :none
      {:error, _} = err -> err
    end
  end

  def platform_seat(_user_id), do: :none

  @doc """
  Announce the rows a committed denial removed, from the data it
  returned (`Arca.SecurityTransitions.deny_user/3`): the person hears
  they left their athanor, and its roster is told.
  """
  @spec announce_removed(String.t(), map()) :: :ok
  def announce_removed(user_id, %{removed_memberships: removed}) do
    for %{athanor_id: athanor_id} <- removed, is_binary(athanor_id) do
      broadcast_change(user_id, athanor_id, :left)
      Sanctum.Notify.member_changed(athanor_id)
    end

    :ok
  end

  @doc """
  The members of an athanor as display rows, oldest first: `%{user_id,
  email, display_name, namespace, status, added_by, since}`. Paged with
  `limit:` (default and ceiling `Arca.Members.max_page/0`) and `offset:`.
  """
  @spec list_by_athanor(String.t(), keyword()) :: {:ok, [map()]} | {:error, :database_error}
  def list_by_athanor(athanor_id, opts \\ []) when is_binary(athanor_id),
    do: Arca.Members.list(in_athanor(athanor_id), opts)

  @doc "Every row of a person: platform and athanor, active only. Uncapped."
  @spec list_by_user(String.t()) :: {:ok, [membership()]} | {:error, :database_error}
  def list_by_user(user_id), do: Arca.Members.list_active_for_user(server(), user_id)

  @doc false
  def broadcast_change(user_id, athanor_id, change) when is_binary(user_id),
    do: Sanctum.Telemetry.membership_changed(user_id, athanor_id, change)

  def broadcast_change(_user_id, _athanor_id, _change), do: :ok

  # ---- internal --------------------------------------------------------------

  # A person's seats span athanors and a platform row names none, so the
  # fabric reads as the server.
  defp server, do: Prima.Actor.system()

  # The server narrowed to one athanor — the actor a read or write of that
  # athanor's own roster runs as. A nil athanor is refused by the facade
  # before any query.
  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  defp find(user_id, "platform", _athanor_id),
    do: Arca.Members.find_platform(server(), user_id)

  defp find(user_id, _scope, athanor_id),
    do: Arca.Members.find(in_athanor(athanor_id), user_id)
end
