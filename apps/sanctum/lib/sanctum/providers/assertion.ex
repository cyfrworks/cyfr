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
  hands the action here. The work is `Sanctum.Person.sign_assertion/3`'s:
  it signs only for the context's own person, only for a pending carry of
  theirs whose destination is the audience, and names that carry in the
  assertion.

  The answer is what the browser carries back to the audience:
  `assertion` (`Prima.PersonAssertion`'s JSON), `genesis` (the person's
  genesis entry, by which that home finds their directory), and
  `callback`, the audience's `/login` page with the two in its fragment
  (`cyfr=` and the unpadded base64url of the JCS bytes of
  `{"assertion": …, "genesis": …}`), which the browser navigates to and
  never sends in a request line.
  """

  alias Prima.{Arg, Operation}
  alias Prima.Identity.Encoding
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
  @spec handle(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(
        %Context{} = ctx,
        %{
          "action" => "assert",
          "audience" => audience,
          "challenge" => challenge,
          "action_id" => action_id,
          "key_epoch" => key_epoch
        }
      )
      when is_binary(audience) and is_binary(challenge) and is_binary(action_id) and
             is_binary(key_epoch) do
    with {:ok, challenge} <- challenge(challenge),
         {:ok, %{assertion: assertion, genesis: genesis}} <-
           Sanctum.Person.sign_assertion(
             ctx,
             %{
               audience: audience,
               challenge: challenge,
               action_id: action_id,
               key_epoch: key_epoch
             },
             []
           ) do
      encoded = Prima.PersonAssertion.encode(assertion)

      {:ok,
       %{
         assertion: encoded,
         genesis: genesis,
         callback: assertion.audience <> "/login#cyfr=" <> fragment(encoded, genesis)
       }}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{}, %{"action" => "assert"}),
    do:
      {:error,
       {:invalid_argument,
        "assert needs the audience, the challenge, the action_id and the key_epoch"}}

  # The signer's own refusals in the sentences their person reads; the
  # consent signal, the confirmation's refusals and the sentences the
  # signer already wrote pass as they are.
  defp refusal(:not_enrolled),
    do: {:conflict, "Signing in at another home needs an enrolled identity; enroll first."}

  defp refusal(:not_found),
    do: {:conflict, "Your keys are held at another home; sign in from there."}

  defp refusal(:stale_key_epoch),
    do:
      {:conflict,
       "Your identity's keys changed since this sign-in began; begin it again from your home."}

  defp refusal(reason), do: reason

  defp challenge(value) do
    case Encoding.unb64(value, Prima.PersonAssertion.challenge_bytes()) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_argument, "The challenge is that home's 32 bytes, base64url"}}
    end
  end

  # The fragment the audience's sign-in page reads: the transport
  # `Prima.PersonAssertion.open/1` takes, as unpadded base64url of its JCS
  # bytes.
  defp fragment(assertion, genesis),
    do: %{"assertion" => assertion, "genesis" => genesis} |> Encoding.jcs!() |> Encoding.b64()
end
