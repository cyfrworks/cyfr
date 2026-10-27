# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorPlacementTest do
  @moduledoc """
  A session is minted at exactly six places, each behind the door or an
  admission: the sign-in paths unlock a person who exists, and the unlock
  asks the door about that person (`Sanctum.SignIn.unlock/1`); the passkey
  sign-in asks the door itself; an admission (`Sanctum.Newcomer`) mints a
  newcomer's first session only past the door's `*`, the door's verdict on
  their identifier, or the setup token; and the restore ingress mints
  behind the installation capability, since no door admits a person who
  does not exist yet. Reads the sources rather than the behaviour: a new
  `Session.create/1` caller that forgot the door would pass every
  behavioural test on the paths that remembered it.
  """
  use ExUnit.Case, async: true

  # The minters are named relative to the umbrella: the auth domain's own
  # flows, and the console's sign-in response, so the scan spans two
  # applications.
  @root Path.expand("../../../..", __DIR__)

  # The CLI device flow, the CYFR sign-in, the passkey door and the
  # admission mint for themselves; the browser flows mint through the
  # shared sign-in responder.
  @device_flow "apps/sanctum/lib/sanctum/auth/device_flow.ex"
  @passkeys "apps/sanctum/lib/sanctum/passkeys.ex"
  @recovery "apps/sanctum/lib/sanctum/recovery.ex"
  @cyfr_door "apps/sanctum/lib/sanctum/auth/cyfr_door.ex"
  @newcomer "apps/sanctum/lib/sanctum/newcomer.ex"
  @sign_in "apps/sanctum/lib/sanctum/sign_in.ex"
  @browser_callback "apps/cyfr/lib/prism_web/controllers/auth_controller.ex"
  @minters [
    "apps/cyfr/lib/cyfr_web/sign_in_response.ex",
    @cyfr_door,
    @device_flow,
    @newcomer,
    @passkeys,
    @recovery
  ]

  defp lib_files do
    for dir <- Prima.Test.SourceTree.app_libs(@root),
        file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
        do: file
  end

  defp source(path), do: Prima.Test.SourceTree.read(Path.join(@root, path))

  test "every Session.create/1 call site sits behind the door or an admission" do
    callers =
      lib_files()
      |> Enum.reject(&String.ends_with?(&1, "sanctum/session.ex"))
      |> Enum.filter(&(Prima.Test.SourceTree.read(&1) =~ ~r/\bSession\.create\(/))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert callers == Enum.sort(@minters),
           "Session.create/1 is called from #{inspect(callers)}; only the sign-in paths may mint"

    # The unlock every linked sign-in method goes through asks the door
    # about the person the method names.
    assert source(@sign_in) =~ "Sanctum.Door.sign_in(user)",
           "#{@sign_in} unlocks a person without asking the door"

    # The device flow unlocks the person; it never makes one.
    assert source(@device_flow) =~ "Sanctum.SignIn.unlock(",
           "#{@device_flow} mints sessions without asking the door"

    # The `cyfr` door unlocks a person who holds the identity, and admits a
    # first-time one only through the remote admission, which asks the door
    # about the identifier before it records the person or mints anything.
    cyfr_door = source(@cyfr_door)
    assert cyfr_door =~ "Sanctum.SignIn.unlock(", "#{@cyfr_door} skips the unlock"

    assert cyfr_door =~ "Sanctum.Newcomer.admit({:remote,",
           "#{@cyfr_door} makes a person outside the remote admission"

    # The admission mints a newcomer's first session only past the door's
    # `*` (open), the door's verdict on the identifier (remote) or the
    # setup token, compared in constant time.
    newcomer = source(@newcomer)
    assert newcomer =~ "Sanctum.Door.Store.wildcard()"
    assert newcomer =~ "Sanctum.Door.sign_in_identifier(identifier)"
    assert newcomer =~ "Plug.Crypto.secure_compare(configured, token)"

    # The passkey door asks it about the person: a person the door no
    # longer admits signs in with no passkey either.
    assert source(@passkeys) =~ "Sanctum.Door.sign_in(",
           "#{@passkeys} mints sessions without asking the door"

    # The restore mints the first person of an empty node, whom no door can
    # have admitted: it checks the installation capability instead, and
    # mints only the reserved `restore` provider's session, which the
    # session store holds to the restore attempt that minted the person.
    recovery = source(@recovery)
    assert recovery =~ "Application.get_env(:sanctum, :restore_token)"
    assert recovery =~ "Plug.Crypto.secure_compare("
    assert recovery =~ "Sanctum.Session.create(ctx, restore: attempt.id)"

    # The responder mints only when a flow hands it `session: {:mint, ctx}`;
    # the one producer of that option must be the browser callback, and the
    # callback must unlock the person, asking the door, before it does.
    mint_handers =
      lib_files()
      |> Enum.filter(&(Prima.Test.SourceTree.read(&1) =~ ~r/session: \{:mint,/))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert mint_handers == [@browser_callback],
           "session: {:mint, ...} is produced from #{inspect(mint_handers)}; " <>
             "only the browser callback may hand the responder a context to mint for"

    assert source(@browser_callback) =~ "Sanctum.SignIn.unlock(",
           "the browser callback mints sessions without asking the door"
  end
end
