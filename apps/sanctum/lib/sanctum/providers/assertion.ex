# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Assertion do
  @moduledoc """
  The `person.assert` action of the `person` tool, declared apart from
  the tool's other actions: the assertion the person's signing home signs
  for the `cyfr` door at another home, over that home's audience and
  challenge, the pending carry it serves and the current `key_epoch`.
  Issuing one is a sensitive change (`remote_sign_in`).

  `Sanctum.Providers.Person` carries this declaration in its tool and
  hands the action here. It answers `{:error, :not_built}`: no assertion
  is signed yet.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

  @doc "The action's declaration, which the `person` tool carries."
  @spec operations() :: [Operation.t()]
  def operations do
    [
      Operation.new(
        "person",
        "assert",
        "Sign an assertion for another home's door",
        [
          Arg.new("audience", :string,
            required: true,
            description:
              "The other home, as its origin: the assertion's audience, or the home a certificate is presented to"
          ),
          Arg.new("challenge", :string,
            required: true,
            description: "assert: the challenge that home issued for this sign-in"
          ),
          Arg.new("action_id", :string,
            required: true,
            description: "The pending sign-in carry, by its action id"
          ),
          Arg.new("key_epoch", :string,
            required: true,
            description:
              "assert: the key_epoch (sha256:<hex>) of the identity head the assertion is signed under"
          )
        ],
        kind: :write,
        planes: [:external],
        consent: :interactive
      )
    ]
  end

  @doc "The action's handler."
  @spec handle(Context.t(), map()) :: {:error, term()}
  def handle(%Context{}, %{"action" => "assert"}), do: {:error, :not_built}
end
