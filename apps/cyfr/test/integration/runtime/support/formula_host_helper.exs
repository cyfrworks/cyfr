# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

unless Code.ensure_loaded?(Locus.Runtime.Test.FormulaHost) do
  defmodule Locus.Runtime.Test.FormulaHost do
    @moduledoc """
    A formula's attempt as its runner holds it, for tests that drive a
    formula's host functions (`Locus.Runtime.FormulaHandler`) in this VM without
    running the formula's guest: what CYFR decides of each host call they
    make, under the authority the attempt holds.

    `attached!/1` admits a formula's row under an authority, opens its
    attempt dispatched to the running runtime service and attaches a runner
    of that service's boot (`Cyfr.Test.AttemptFixtures`). Its client
    reaches CYFR as a runner does, over the suite's wire
    (`Cyfr.Test.TwoServices.wire/0`) to the host API listener, so what it
    asks and what it is answered can be read there. The runner it presents
    is no process: a child CYFR admits and claims for it is started by no
    runner, and the formula's host function closes it failed as a runner
    that cannot start a child does. A child's own run is a real formula's
    in a real runner (`Locus.Runtime.Test.NestedExecution`). `current!/2` is the
    client of a formula a real run has attached.
    """

    alias Cyfr.Test.{AttemptFixtures, RuntimeService, TwoServices}

    @doc """
    An attached formula attempt: the fixture (`Cyfr.Test.AttemptFixtures.attached!/1`)
    with its `host` client. Options are the fixture's; the component type
    defaults to `:formula`, the worker service to the running runtime
    service, and the row is admitted with its authority's reservation.
    """
    @spec attached!(keyword()) :: map()
    def attached!(opts \\ []) do
      %{service: service, boot: boot} = RuntimeService.status()

      fixture =
        AttemptFixtures.attached!(
          Keyword.merge(
            [
              component_type: :formula,
              worker: RuntimeService.endpoint(),
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
        Locus.Runtime.HostClient.new(fixture.keys, fixture.runner, fixture.boot, %{
          member: fixture.member,
          host_url: TwoServices.wire().url
        })
      )
    end

    @doc """
    The client of the attempt that owns the running execution `execution_id`,
    presenting as the runner that claimed it.
    """
    @spec current!(String.t(), String.t()) :: Locus.Runtime.HostClient.t()
    def current!(athanor_id, execution_id) do
      attempt = AttemptFixtures.current!(athanor_id, execution_id)

      Locus.Runtime.HostClient.new(attempt.keys, attempt.runner, attempt.boot, %{
        member: attempt.member,
        host_url: TwoServices.wire().url
      })
    end

    @doc "The actions an assignment names as a formula's host's to run."
    @spec intercepted() :: [String.t()]
    def intercepted, do: Sanctum.Catalog.host_intercepted_actions()

    @doc "The options a formula's host functions run with under `authority`."
    @spec opts(Prima.Authority.t()) :: keyword()
    def opts(authority),
      do: [limits: Prima.Authority.limits(authority), intercepted: intercepted()]
  end
end
