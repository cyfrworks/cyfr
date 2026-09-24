# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Actor do
  @moduledoc """
  The actors this suite's fixtures work as.

  Arca authorizes on the actor and nothing else, so its tests build one
  directly rather than projecting a context from the layer above. The
  three shapes here are the three the facades distinguish: a tenant's own
  caller, the server's own platform-scope caller, and a bare athanor for
  work the control plane has already narrowed to one estate.
  """

  @athanor_id "ath_test"

  @doc "The athanor `local/0` works in, and the one the suite seeds."
  @spec athanor_id() :: String.t()
  def athanor_id, do: @athanor_id

  @doc """
  A person's caller inside the well-known test athanor: athanor scope, no
  system authority, an identity to attribute a row to.
  """
  @spec local(keyword()) :: Prima.Actor.t()
  def local(opts \\ []) do
    %Prima.Actor{
      athanor_id: Keyword.get(opts, :athanor_id, @athanor_id),
      user_id: Keyword.get(opts, :user_id, "local|local|testns"),
      authenticated: true,
      scope: :athanor,
      system: false
    }
  end

  @doc """
  The server's own caller: platform scope, so it reads across tenants, and
  system authority, so it may mutate the seed and global paths.
  """
  @spec platform(keyword()) :: Prima.Actor.t()
  def platform(opts \\ []) do
    %Prima.Actor{
      Prima.Actor.system()
      | athanor_id: Keyword.get(opts, :athanor_id),
        user_id: Keyword.get(opts, :user_id)
    }
  end

  @doc """
  The issuance options (`Arca.SecurityTransitions.Issuance`) a storage
  test writes a session or a key under: the rows named for locking, and a
  policy that admits. The policy is the identity domain's
  (`Sanctum.Issuance`); a storage test is about the write, not the
  decision.
  """
  @spec issuance(String.t()) :: keyword()
  def issuance(user_id \\ "usr_test") do
    [
      lock: %{user_id: user_id, athanor_id: nil, membership_id: nil, source: nil},
      verify: fn _rows -> :ok end
    ]
  end

  @doc """
  The grant options (`Arca.ExecutionStanding`) a storage test admits an
  execution under: the athanor's grant at the generation its row carries
  now (1 when the suite has minted no row), and a check that admits. The
  check is the identity domain's (`Sanctum.ExecutionStanding`); a storage
  test is about the write, not the decision.
  """
  @spec standing(String.t()) :: keyword()
  def standing(athanor_id \\ @athanor_id),
    do: [grant: grant(athanor_id), verify: &admits/1]

  @doc """
  The grant options a storage test writes an admitted execution under: the
  stamp its attempt stores, and a check that admits.
  """
  @spec stored() :: keyword()
  def stored, do: [grant: :stored, verify: &admits/1]

  @doc "A check that admits every grant: the storage test's stand-in for the decision."
  @spec admits(Prima.ExecutionGrant.t()) :: :ok
  def admits(%Prima.ExecutionGrant{}), do: :ok

  @doc "The grant of `athanor_id` at the generation its row carries now."
  @spec grant(String.t()) :: Prima.ExecutionGrant.t()
  def grant(athanor_id \\ @athanor_id) do
    generation =
      case Arca.ExecutionStanding.current(Prima.Actor.in_athanor(athanor_id), athanor_id) do
        {:ok, %{security_generation: generation}} -> generation
        _none -> 1
      end

    {:ok, grant} = Prima.ExecutionGrant.new(athanor_id, generation)
    grant
  end

  @doc """
  The identity domain's decision over a grant, for a storage test that
  exercises it: the estate row locked and read at the grant's generation
  (`Sanctum.ExecutionStanding.verify/1` spells the same rule).
  """
  @spec verify(Prima.ExecutionGrant.t()) :: :ok | {:error, :not_standing | :unavailable}
  def verify(%Prima.ExecutionGrant{athanor_id: athanor_id, generation: generation}) do
    case Arca.ExecutionStanding.locked(Prima.Actor.in_athanor(athanor_id), athanor_id) do
      {:ok, %{status: "active", security_generation: ^generation}} -> :ok
      {:ok, _retired} -> {:error, :not_standing}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc "A bare tenant caller — an athanor, and nothing else."
  @spec in_athanor(String.t()) :: Prima.Actor.t()
  def in_athanor(athanor_id), do: Prima.Actor.in_athanor(athanor_id)

  @doc """
  The `athanors` row `local/0` names, minted if the suite has not already.
  Blob storage needs no row; per-athanor settings live on it.
  """
  @spec athanor!() :: Arca.Schemas.Athanor.t()
  def athanor!(athanor_id \\ @athanor_id), do: ensure_athanor_row(athanor_id)

  # The athanor ids test fixtures name by hand, across every suite in this
  # repository. Seeded once per run, outside any sandbox, so every caller
  # that names one works against a real (active) row. The roster lives
  # here because an `athanors` row is this layer's; the identity domain's
  # own fixture seeds it through `seed_athanors!/0` below.
  @well_known [
    {"ath_test", "test"},
    {"ath_a", "ath-a"},
    {"ath_b", "ath-b"},
    {"ath_acme", "ath-acme"},
    {"ath_other", "ath-other"},
    {"ath_1", "ath-1"},
    {"ath_alpha", "ath-alpha"},
    {"ath_x", "ath-x"},
    {"ath_evt_x", "ath-evt-x"},
    {"ath_o", "ath-o"},
    {"ath_o1", "ath-o1"},
    {"ath_gamma", "ath-gamma"},
    {"ath_myorg", "ath-myorg"},
    {"ath_reg", "ath-reg"},
    {"ath_scaffold", "ath-scaffold"},
    {"ath_stub", "ath-stub"},
    {"ath_sweep", "ath-sweep"}
  ]

  @doc """
  Insert the well-known test athanor rows (idempotent). Called from each
  app's `test_helper.exs` after the migrations ran, before ExUnit starts.
  """
  @spec seed_athanors!() :: :ok
  def seed_athanors! do
    # Outside the sandbox: the rows must be committed and visible to every
    # test's connection, and the pool may already be in manual mode when a
    # second app's helper runs in the same BEAM.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fn ->
      for {id, slug} <- @well_known do
        ensure_athanor_row(id, name: "Test #{slug}", slug: slug)
      end
    end)

    :ok
  end

  @doc """
  Insert an `athanors` row so settings-bearing paths can resolve it.
  Idempotent.
  """
  @spec ensure_athanor_row(String.t(), keyword()) :: Arca.Schemas.Athanor.t()
  def ensure_athanor_row(athanor_id, opts \\ []) do
    system = Prima.Actor.system()

    case Arca.Athanors.get(system, athanor_id) do
      {:ok, athanor} ->
        athanor

      {:error, :not_found} ->
        slug =
          Keyword.get_lazy(opts, :slug, fn ->
            athanor_id
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9]+/, "-")
            |> String.trim("-")
          end)

        {:ok, athanor} =
          Arca.Athanors.insert(system, %{
            id: athanor_id,
            kind: Keyword.get(opts, :kind, "group"),
            name: Keyword.get(opts, :name, athanor_id),
            slug: slug,
            created_by: Keyword.get(opts, :created_by, "system"),
            owner_user_id: Keyword.get(opts, :owner_user_id)
          })

        athanor
    end
  end
end
