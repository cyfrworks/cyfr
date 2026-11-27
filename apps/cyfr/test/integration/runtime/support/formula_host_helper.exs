# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

unless Code.ensure_loaded?(Cyfr.Test.FormulaHost) do
  defmodule Cyfr.Test.FormulaHost do
    @moduledoc """
    A formula's attempt as its runner holds it, for tests of what CYFR
    decides of each host call a formula's host functions make, under the
    authority the attempt holds, without running the formula's guest.

    `attached!/1` admits a formula's row under an authority, opens its
    attempt dispatched to the running runtime service and attaches a runner
    of that service's boot (`Cyfr.Test.AttemptFixtures`). `call/3` posts one
    host call for it as a runner's worker service does
    (`Cyfr.Test.HostCaller`), over the suite's wire
    (`Cyfr.Test.TwoServices.wire/0`) to the host API listener, so what it
    asks and what it is answered can be read there. The runner it presents
    is no process: a child CYFR admits and claims for it is started by no
    runner. A child's own run is a real formula's in a real runner
    (`Locus.Runtime.Test.NestedExecution`). `current!/2` is the attempt of a
    formula a real run has attached.
    """

    alias Cyfr.Test.{AttemptFixtures, HostCaller, RuntimeService, TwoServices}

    @doc """
    An attached formula attempt (`Cyfr.Test.AttemptFixtures.attached!/1`).
    Options are the fixture's; the component type defaults to `:formula`,
    the worker service to the running runtime service, and the row is
    admitted with its authority's reservation.
    """
    @spec attached!(keyword()) :: map()
    def attached!(opts \\ []) do
      %{service: service, boot: boot} = RuntimeService.status()

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
    end

    @doc """
    The attempt that owns the running execution `execution_id`, presenting
    as the runner that claimed it.
    """
    @spec current!(String.t(), String.t()) :: map()
    def current!(athanor_id, execution_id), do: AttemptFixtures.current!(athanor_id, execution_id)

    @doc "Post the host call `op` with `args` for `attempt` over the suite's wire, once."
    @spec call(map(), atom(), map()) :: HostCaller.answer()
    def call(attempt, op, args), do: HostCaller.call(attempt, TwoServices.wire().url, op, args)

    @doc """
    Admit a child of `attempt` on `reference` made with `guest_fn`, under a
    fresh child key unless `args` name one; `args` add the call's other
    arguments (`need`, `input`, `connection`).
    """
    @spec admit_child(map(), String.t(), String.t(), map()) :: HostCaller.answer()
    def admit_child(attempt, reference, guest_fn, args \\ %{}) do
      call(
        attempt,
        :admit_child,
        Map.merge(
          %{
            "reference" => reference,
            "need" => nil,
            "input" => %{},
            "guest_fn" => guest_fn,
            "child_key" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
          },
          args
        )
      )
    end

    @doc "A catalog tool call of `attempt`: `tool` with `action` and `args`, made with `guest_fn`."
    @spec tool_call(map(), String.t(), String.t(), map(), String.t()) :: HostCaller.answer()
    def tool_call(attempt, tool, action, args \\ %{}, guest_fn \\ "call") do
      call(attempt, :tool_call, %{
        "name" => tool,
        "args" => Map.put(args, "action", action),
        "guest_fn" => guest_fn
      })
    end
  end
end
