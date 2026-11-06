# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorPlacementTest do
  @moduledoc """
  A session is minted at exactly two places, each behind the door or an
  admission: the sign-in (`Sanctum.SignIn`) mints for a person this CYFR
  holds only once the door admits them (`Sanctum.Door.sign_in/1`), and for
  a new person only past their admission (`Sanctum.Newcomer.admit/2`),
  which mints a newcomer only past the door's verdict on their identifier,
  an invitation or the setup token; and the restore ingress mints behind
  the installation capability, since no door admits a person who does not
  exist yet. Reads the sources rather than the behaviour: a new
  `Session.create/2` caller that forgot the door would pass every
  behavioural test on the paths that remembered it.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @recovery "apps/sanctum/lib/sanctum/recovery.ex"
  @newcomer "apps/sanctum/lib/sanctum/newcomer.ex"
  @sign_in "apps/sanctum/lib/sanctum/sign_in.ex"
  @minters [@recovery, @sign_in]

  defp lib_files do
    for dir <- Prima.Test.SourceTree.app_libs(@root),
        file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
        do: file
  end

  defp source(path), do: Prima.Test.SourceTree.read(Path.join(@root, path))

  test "every Session.create/2 call site sits behind the door or an admission" do
    callers =
      lib_files()
      |> Enum.reject(&String.ends_with?(&1, "sanctum/session.ex"))
      |> Enum.filter(&(Prima.Test.SourceTree.read(&1) =~ ~r/\bSession\.create\(/))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert callers == Enum.sort(@minters),
           "Session.create/2 is called from #{inspect(callers)}; only the sign-in paths may mint"

    # The sign-in asks the door about a person this CYFR holds, and admits
    # a new one only through the admission.
    sign_in = source(@sign_in)

    assert sign_in =~ "Sanctum.Door.sign_in(user)",
           "#{@sign_in} signs in a person without asking the door"

    assert sign_in =~ "Sanctum.Newcomer.admit(",
           "#{@sign_in} makes a person outside the admission"

    # The admission mints a newcomer only past the door's verdict on the
    # identifier, or the setup token, compared in constant time.
    newcomer = source(@newcomer)
    assert newcomer =~ "Sanctum.Door.sign_in_identifier(identifier)"
    assert newcomer =~ "Plug.Crypto.secure_compare(configured, token)"

    # The restore mints the first person of an empty node, whom no door can
    # have admitted: it checks the installation capability instead, and
    # mints only the reserved `restore` provider's session, which the
    # session store holds to the restore attempt that minted the person.
    recovery = source(@recovery)
    assert recovery =~ "Application.get_env(:sanctum, :restore_token)"
    assert recovery =~ "Plug.Crypto.secure_compare("
    assert recovery =~ "Sanctum.Session.create(ctx, restore: attempt.id)"
  end
end
