# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Assertion do
  @moduledoc """
  The `person` tool's assertion for another home, declared apart from the
  tool's other actions.

  `person.assert_confirmation`: the person's own home certifying that they
  confirmed one pending confirmation at another home
  (`Sanctum.RemoteCertification.assert_confirmation/2`), over the bindings
  that home's record carries for it (`at_home`). Issuing one is a
  sensitive change (`remote_confirmation`) only a passkey or a protected
  device of the person's here confirms. The answer is the assertion and
  `callback`, that home's `/confirm` page with it in the fragment.

  `Sanctum.Providers.Person` carries this declaration in its tool and
  hands the action here.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

  @doc "The action's declaration, which the `person` tool carries."
  @spec operations() :: [Operation.t()]
  def operations do
    [
      Operation.new(
        "person",
        "assert_confirmation",
        "Confirm a change at another CYFR, as your own CYFR",
        [
          Arg.new("audience", :string,
            required: true,
            description:
              "The other CYFR, as its origin: the assertion's audience, or the CYFR a certificate is presented to"
          ),
          Arg.new("athanor", :string,
            required: true,
            description:
              "The athanor at the other CYFR: the one a certified device joins, or the one a confirmed change is in"
          ),
          Arg.new("ref", :string,
            required: true,
            description: "assert_confirmation: the other CYFR's pending confirmation, by its ref"
          ),
          Arg.new("digest", :string,
            required: true,
            description: "assert_confirmation: that confirmation's stored digest (sha256:<hex>)"
          ),
          Arg.new("expires_at", :integer,
            required: true,
            description: "assert_confirmation: when that confirmation expires, in Unix ms"
          ),
          Arg.new("preview", :json,
            required: true,
            description: "assert_confirmation: the change as the other CYFR stored it"
          ),
          Arg.new("preview_digest", :string,
            required: true,
            description:
              "assert_confirmation: the digest of that preview the other CYFR names (sha256:<hex>)"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      )
    ]
  end

  @doc "The action's handler."
  @spec handle(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(%Context{} = ctx, %{"action" => "assert_confirmation"} = args),
    do: Sanctum.RemoteCertification.assert_confirmation(ctx, Map.delete(args, "action"))
end
