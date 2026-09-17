# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

unless Code.ensure_loaded?(Opus.Test.FormulaHost) do
  defmodule Opus.Test.FormulaHost do
    @moduledoc """
    A formula's attempt as its runner holds it, for tests that drive a
    formula's host functions without running the formula's guest.

    `attached!/1` admits a formula's row under an authority, opens its
    attempt dispatched to the running `Opus.WorkerService` and attaches a
    runner of that worker service's group (`Cyfr.Test.AttemptFixtures`), so
    the children its host functions admit run in runners of that group. Its
    client reaches CYFR over the wire, through the test boot's host API
    listener (`Cyfr.Test.OpusService.host_url/0`). `current!/2` is the
    client of a formula a real run has attached.
    """

    alias Cyfr.Test.AttemptFixtures

    @doc """
    An attached formula attempt: the fixture (`Cyfr.Test.AttemptFixtures.attached!/1`)
    with its `host` client. Options are the fixture's; the component type
    defaults to `:formula`, the worker service to the running
    `Opus.WorkerService`, and the row is admitted with its authority's
    reservation.
    """
    @spec attached!(keyword()) :: map()
    def attached!(opts \\ []) do
      {:ok, %{service: service, boot: boot}} = Opus.WorkerService.status()

      fixture =
        AttemptFixtures.attached!(
          Keyword.merge(
            [
              component_type: :formula,
              worker: Cyfr.Test.OpusService.endpoint(),
              service_id: service,
              boot_id: boot,
              reservation: true
            ],
            opts
          )
        )

      Map.put(
        fixture,
        :host,
        Opus.HostClient.new(
          fixture.keys,
          fixture.runner,
          fixture.boot,
          Cyfr.Test.OpusService.host_url()
        )
      )
    end

    @doc """
    The client of the attempt that owns the running execution `execution_id`,
    presenting as the runner that claimed it.
    """
    @spec current!(String.t(), String.t()) :: Opus.HostClient.t()
    def current!(athanor_id, execution_id) do
      attempt = AttemptFixtures.current!(athanor_id, execution_id)

      Opus.HostClient.new(
        attempt.keys,
        attempt.runner,
        attempt.boot,
        Cyfr.Test.OpusService.host_url()
      )
    end

    @doc "The actions an assignment names as a formula's host's to run."
    @spec intercepted() :: [String.t()]
    def intercepted, do: Cyfr.Ops.Catalog.host_intercepted_actions()

    @doc "The options a formula's host functions run with under `authority`."
    @spec opts(Cyfr.Authority.t()) :: keyword()
    def opts(authority),
      do: [limits: Cyfr.Authority.limits(authority), intercepted: intercepted()]
  end
end
