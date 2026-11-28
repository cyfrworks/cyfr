// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/release"
)

const (
	kvmEnv = access.KVMSetting
	tunEnv = access.TunSetting
)

// devicesHere stands in for a machine that has both devices a person's
// computer of their own needs, or lacks them.
func devicesHere(t *testing.T, has bool) {
	t.Helper()
	saved := machine.devices
	t.Cleanup(func() { machine.devices = saved })
	machine.devices = func() bool { return has }
}

// deviceLines is .env's device settings as values give them: kvm, then
// tun.
func deviceLines(kvm, tun string) string {
	return kvmEnv + "=" + kvm + "\n" + tunEnv + "=" + tun + "\n"
}

// devicesAre fails unless .env holds kvm and tun as its device settings,
// "<unset>" for a setting it does not assign.
func devicesAre(t *testing.T, kvm, tun string) {
	t.Helper()
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		t.Fatal(err)
	}
	got := func(name string) string {
		if v, ok := values[name]; ok {
			return v
		}
		return "<unset>"
	}
	if got(kvmEnv) != kvm || got(tunEnv) != tun {
		t.Errorf(".env's devices are %s=%q and %s=%q, want %q and %q", kvmEnv, got(kvmEnv), tunEnv, got(tunEnv), kvm, tun)
	}
}

// initDocker stands a docker in for init's one question, through the
// engine's runner: the volumes of the project's name it lists, and its
// exit status. It answers the log of its calls.
func initDocker(t *testing.T, volumes string, exit int) func() []string {
	t.Helper()
	fake := t.TempDir()
	for name, data := range map[string]string{"docker": fakeDocker, "volume.out": volumes, "volume.exit": strings.Repeat("1", min(exit, 1))} {
		if name == "volume.exit" && exit == 0 {
			continue
		}
		if err := os.WriteFile(filepath.Join(fake, name), []byte(data), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_DIR", fake)
	return func() []string {
		data, _ := os.ReadFile(filepath.Join(fake, "log"))
		return strings.Split(strings.TrimSpace(string(data)), "\n")
	}
}

// volumesAsked is the one docker call init makes before it gives a new
// project the devices: the volumes Docker holds of the project's name.
func volumesAsked(dir string) string {
	return "volume ls -q --filter label=com.docker.compose.project=" + access.ProjectName(dir)
}

// runInitHere runs cyfr init in the working directory and answers its
// output.
func runInitHere(t *testing.T) string {
	t.Helper()
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	return out.String()
}

// init gives the devices only to a project it makes: there each is the
// machine's, both or neither. In a project that exists it writes no device
// line, whatever the machine has, and leaves the lines it finds as they
// are: where the machine could run each person's programs in a computer of
// their own and .env does not give the devices, it says that cyfr update
// turns that on.
func TestInitGivesTheDevicesOnlyToAProjectItMakes(t *testing.T) {
	for name, m := range map[string]struct {
		has      bool
		kvm, tun string
	}{
		"both here": {true, "/dev/kvm", "/dev/net/tun"},
		"none here": {false, "", ""},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, m.has)
			dir := newInitProject(t)
			useFakeEngine(t)
			asked := initDocker(t, "", 0)
			out := runInitHere(t)
			devicesAre(t, m.kvm, m.tun)
			if strings.Contains(out, devicesUpdateGives) {
				t.Errorf("init of a new project says cyfr update gives the devices:\n%s", out)
			}
			if want := []string{volumesAsked(dir)}; m.has && !slices.Equal(asked(), want) {
				t.Errorf("init asked docker %q, want %q", asked(), want)
			}

			for env, says := range map[string]bool{
				"CYFR_ACCESS=local\nCYFR_PORT=4000\n":                                           m.has,
				"CYFR_ACCESS=local\nCYFR_PORT=4000\n" + deviceLines("", ""):                     m.has,
				"CYFR_ACCESS=local\nCYFR_PORT=4000\n" + deviceLines("/dev/sda", ""):             m.has,
				"CYFR_ACCESS=local\nCYFR_PORT=4000\n" + deviceLines("/dev/kvm", "/dev/net/tun"): false,
			} {
				if err := os.WriteFile(".env", []byte(env), 0o600); err != nil {
					t.Fatal(err)
				}
				before, _ := access.EnvValues([]byte(env))
				out := runInitHere(t)
				after, err := access.ReadEnvValues(".env")
				if err != nil {
					t.Fatal(err)
				}
				for _, d := range vmDevices {
					v, assigned := after[d.env]
					w, was := before[d.env]
					if v != w || assigned != was {
						t.Errorf("init in a project whose .env is %q left %s as %q (assigned %t)", env, d.env, v, assigned)
					}
				}
				if strings.Contains(out, kvmEnv) || strings.Contains(out, tunEnv) {
					t.Errorf("init in a project whose .env is %q names a device setting:\n%s", env, out)
				}
				if got := strings.Contains(out, devicesUpdateGives+"\n"); got != says {
					t.Errorf("init in a project whose .env is %q says cyfr update gives the devices: %t, want %t:\n%s", env, got, says, out)
				}
			}
		})
	}
}

// A project whose folder holds no .env but whose volumes Docker still
// holds, which a person's data outlives the folder's files in (cyfr
// uninstall keeps them), is no new project: init gives it no device, so
// no start removes their kept folders unasked, and says cyfr update turns
// them on; so too where Docker answers the question with a failure. A
// Docker not installed holds none.
func TestInitGivesNoDeviceToAProjectDockerHoldsVolumesOf(t *testing.T) {
	for name, c := range map[string]struct {
		volumes string
		exit    int
		noPath  bool
		given   bool
	}{
		"volumes of its name": {"cyfr_homes\ncyfr_data\n", 0, false, false},
		"none":                {"", 0, false, true},
		"Docker refuses":      {"", 1, false, false},
		"Docker not here":     {"", 0, true, true},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, true)
			dir := newInitProject(t)
			useFakeEngine(t)
			asked := initDocker(t, c.volumes, c.exit)
			if c.noPath {
				t.Setenv("PATH", t.TempDir())
			}
			out := runInitHere(t)
			if c.given {
				devicesAre(t, "/dev/kvm", "/dev/net/tun")
			} else {
				devicesAre(t, "", "")
			}
			if got := strings.Contains(out, devicesUpdateGives+"\n"); got == c.given {
				t.Errorf("init says cyfr update gives the devices: %t, want %t:\n%s", got, !c.given, out)
			}
			if want := []string{volumesAsked(dir)}; !c.noPath && !slices.Equal(asked(), want) {
				t.Errorf("init asked docker %q, want %q", asked(), want)
			}
		})
	}
}

// The commands that start the stack as .env stands refuse a device .env
// names that this machine does not have, by the sentence that says what
// mends it, never naming the value.
func TestADeviceThisMachineLacksIsNotPassedToDocker(t *testing.T) {
	devicesHere(t, false)
	t.Chdir(t.TempDir())
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\n"+deviceLines("/dev/kvm", "/dev/net/tun")), 0o600); err != nil {
		t.Fatal(err)
	}
	want := kvmEnv + " in .env is not a device this machine has for CYFR, so nothing was started. Run `cyfr update` here, which writes what this machine has, then run `cyfr up` again"
	if err := refuseDevices("cyfr up"); err == nil || err.Error() != want {
		t.Fatalf("a .env naming devices this machine lacks answered %v, want %q", err, want)
	}
}

// cyfr init run again in a project that exists, which its help calls safe,
// writes no device: the update that first gives them says what that
// removes, and init says it is cyfr update that does.
func TestInitInAProjectThatExistsLeavesTheDevicesToTheUpdate(t *testing.T) {
	devicesHere(t, true)
	newInitProject(t)
	useFakeEngine(t)
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\nCYFR_PORT=4000\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := runInitHere(t)
	devicesAre(t, "<unset>", "<unset>")
	if !strings.Contains(out, devicesUpdateGives+"\n") || strings.Contains(out, devicesSignInAgain) {
		t.Fatalf("init in a project that exists does not say cyfr update gives the devices, or says what the update says:\n%s", out)
	}
}

// cyfr init run in the folder before the update that first gives the
// devices leaves that update its sentence.
func TestInitBeforeTheUpdateLeavesTheSentenceToIt(t *testing.T) {
	devicesHere(t, true)
	newUpdateScenario(t, shippedCompose(t), nil)
	said := func() bool {
		askWith(t, true, strings.NewReader("no\n"))
		var out bytes.Buffer
		if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{}); err != nil {
			t.Fatalf("a declined update answered %v:\n%s", err, out.String())
		}
		return strings.Contains(out.String(), devicesSignInAgain+"\n")
	}
	if !said() {
		t.Fatal("before cyfr init, the offer does not say programs sign in again")
	}
	if _, err := ensureEnvFileKeys(".env"); err != nil {
		t.Fatal(err)
	}
	devicesAre(t, "<unset>", "<unset>")
	if !said() {
		t.Error("after cyfr init, the update that first gives the devices says nothing of signing in again")
	}
}

// cyfr update writes the devices as this machine has them over whatever
// .env held, at the switch and on a home on its release already.
func TestUpdateWritesTheDevicesThisMachineHas(t *testing.T) {
	for name, m := range map[string]struct {
		has      bool
		kvm, tun string
		others   []string
	}{
		"both here": {true, "/dev/kvm", "/dev/net/tun", []string{"", deviceLines("", ""), deviceLines("", "/dev/net/tun"), deviceLines("/dev/sda", "/dev/net/tun")}},
		"none here": {false, "", "", []string{deviceLines("/dev/kvm", "/dev/net/tun"), deviceLines("/dev/kvm", ""), deviceLines("/dev/sda", "")}},
	} {
		for release, compose := range map[string]func(*testing.T) []byte{
			"switch":         shippedCompose,
			"on its release": func(t *testing.T) []byte { return switched(shippedCompose(t)) },
		} {
			for _, other := range m.others {
				t.Run(name+", "+release+", "+strings.ReplaceAll(other, "\n", " "), func(t *testing.T) {
					devicesHere(t, m.has)
					s := newUpdateScenario(t, compose(t), nil)
					s.edit(".env", scenarioEnv+other)
					if out, err := s.run(context.Background()); err != nil {
						t.Fatalf("update: %v\n%s", err, out)
					}
					devicesAre(t, m.kvm, m.tun)
				})
			}
		}
	}
}

// What an update says of the devices, before it changes anything: the
// update that first gives the Locus services both devices, which only an
// update does, that each person signs their programs in again, in the
// change it shows before its question, in the change the CYFR app's page
// shows, and on a home on its release before its question; the update
// that takes them away, since the machine no longer has them, that a
// program kept in a person's own computer does not start, said and not
// asked. No other update says either. At a terminal or with --yes, a
// device setting this machine does not have is emptied first, both
// together, and said at once, whatever the update is then answered: the
// app's offer empties nothing.
func TestUpdateSaysWhatItDoesToTheDevices(t *testing.T) {
	const on, off, neither = "on", "off", ""
	strayKVM := kvmEnv + " in .env was not a device this machine has for CYFR, so cyfr emptied it.\n"
	strayTun := tunEnv + " in .env was not a device this machine has for CYFR, so cyfr emptied it.\n"
	for name, c := range map[string]struct {
		has  bool
		env  string
		says string
		// emptied is what the update says at once as it empties the
		// device settings, before anything else.
		emptied string
	}{
		"none named, both here":         {true, "", on, ""},
		"tun named, both here":          {true, deviceLines("", "/dev/net/tun"), on, ""},
		"another path named, both here": {true, deviceLines("/dev/sda", "/dev/net/tun"), on, strayKVM},
		"both named, both here":         {true, deviceLines("/dev/kvm", "/dev/net/tun"), neither, ""},
		"none named, none here":         {false, "", neither, ""},
		"tun named, none here":          {false, deviceLines("", "/dev/net/tun"), neither, strayTun},
		"both named, none here":         {false, deviceLines("/dev/kvm", "/dev/net/tun"), off, devicesGone("update") + "\n"},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, c.has)
			said := func(out string) string {
				switch {
				case strings.Contains(out, devicesSignInAgain+"\n") && !strings.Contains(out, devicesGone("update")):
					return on
				case strings.Contains(out, devicesGone("update")+"\n") && !strings.Contains(out, devicesSignInAgain):
					return off
				case !strings.Contains(out, devicesGone("update")) && !strings.Contains(out, devicesSignInAgain):
					return neither
				}
				return "both"
			}

			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.edit(".env", scenarioEnv+c.env)
			askWith(t, true, strings.NewReader("no\n"))
			var out bytes.Buffer
			closing, left := "Nothing changed", scenarioEnv+c.env
			if c.emptied != "" {
				closing, left = "Nothing else changed", scenarioEnv+deviceLines("", "")
			}
			if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{}); err != nil || !strings.HasPrefix(out.String(), c.emptied) ||
				!strings.HasSuffix(out.String(), "Update this CYFR? (yes/no) [no]: "+closing+". Run cyfr update again when you want this release.\n") {
				t.Fatalf("a declined update answered %v:\n%s", err, out.String())
			}
			if got := said(out.String()); got != c.says {
				t.Errorf("the offer says %q of the devices, want %q:\n%s", got, c.says, out.String())
			}
			s.onlyReadTheSchema()
			if got := read(t, filepath.Join(s.project, ".env")); got != left {
				t.Errorf("a declined update left .env as %q, want %q", got, left)
			}

			s.edit(".env", scenarioEnv+c.env)
			out.Reset()
			if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
				t.Fatalf("the app's offer answered %v:\n%s", err, out.String())
			}
			if got := said(offered(t, out.String()).Change); got != c.says {
				t.Errorf("the app's offer says %q of the devices, want %q:\n%s", got, c.says, out.String())
			}

			s = newUpdateScenario(t, switched(shippedCompose(t)), nil)
			s.edit(".env", scenarioEnv+c.env)
			got, err := s.run(context.Background())
			if err != nil {
				t.Fatalf("an update on its release answered %v:\n%s", err, got)
			}
			first := "This CYFR is on release 0.9.0 already, so there is nothing to switch; cyfr update starts it and waits for every service of its stack.\n"
			want := c.emptied + "Verifying the manifest of release 0.9.0...\n" + map[string]string{
				on:      "This CYFR is on release 0.9.0 already, so there is nothing to switch; cyfr update writes this machine's devices to .env, starts it and waits for every service of its stack.\n" + devicesSignInAgain + "\n",
				off:     first,
				neither: first,
			}[c.says] + "Starting release 0.9.0...\n"
			if !strings.HasPrefix(got, want) {
				t.Errorf("an update on its release does not begin %q:\n%s", want, got)
			}
		})
	}
}

// offered is the app's offer an --offer run printed last.
func offered(t *testing.T, out string) shownChange {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var shown shownChange
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &shown); err != nil {
		t.Fatalf("the app's offer is %q (%v)", out, err)
	}
	return shown
}

// cyfr update makes the device settings true whatever it is then asked or
// refused: at a terminal or with --yes it empties a device setting this
// machine does not have, both together, and says so at once, before the
// change and its question. On a machine that lost the devices .env passes,
// it says that from this update on programs run in spaces; for a value cyfr
// never writes, on a machine that has both, that it emptied it, and then
// asks to give them as any update does. Declined, it changed that and
// nothing else, and cyfr up starts. With no terminal and no --yes, and for
// the CYFR app's offer, it changes nothing.
func TestADeclinedUpdateStillEmptiesADeviceThisMachineDoesNotHave(t *testing.T) {
	for name, c := range map[string]struct {
		has          bool
		compose      func(*testing.T) []byte
		env, said    string
		asks, closes string
	}{
		"a machine that lost the devices, at the switch": {false, shippedCompose, deviceLines("/dev/kvm", "/dev/net/tun"),
			devicesGone("update") + "\n", "Update this CYFR? (yes/no) [no]: ",
			"Nothing else changed. Run cyfr update again when you want this release.\n"},
		"a value cyfr does not write, on its release": {true, func(t *testing.T) []byte { return switched(shippedCompose(t)) }, deviceLines("/dev/null", ""),
			kvmEnv + " in .env was not a device this machine has for CYFR, so cyfr emptied it.\n", devicesSignInAgain + "\nUpdate this CYFR? (yes/no) [no]: ",
			"Nothing else changed. Run cyfr update again when you want each person's programs in a computer of their own.\n"},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, c.has)
			s := newUpdateScenario(t, c.compose(t), nil)
			s.edit(".env", scenarioEnv+c.env)
			if err := refuseDevices("cyfr up"); err == nil {
				t.Fatal("the test's premise: cyfr up is refused for .env's devices")
			}

			// The app's offer empties nothing, even run at a terminal.
			askWith(t, true, strings.NewReader(""))
			var out bytes.Buffer
			if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
				t.Fatalf("the app's offer answered %v:\n%s", err, out.String())
			}
			if got := read(t, filepath.Join(s.project, ".env")); got != scenarioEnv+c.env {
				t.Fatalf("the app's offer changed .env to %q:\n%s", got, out.String())
			}
			askWith(t, false, strings.NewReader(""))
			out.Reset()
			err := runHomeUpdate(context.Background(), &out, &out, updateOptions{})
			if got := read(t, filepath.Join(s.project, ".env")); got != scenarioEnv+c.env || strings.Contains(out.String(), "emptied") {
				t.Fatalf("the app's offer, or an update with no terminal and no --yes (%v), changed .env to %q:\n%s", err, got, out.String())
			}

			askWith(t, true, strings.NewReader("no\n"))
			out.Reset()
			if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{}); err != nil {
				t.Fatalf("a declined update answered %v:\n%s", err, out.String())
			}
			said := out.String()
			if !strings.HasPrefix(said, c.said) || strings.Count(said, c.said) != 1 || !strings.HasSuffix(said, c.asks+c.closes) {
				t.Errorf("a declined update said:\n%s\nwant it to begin %q, once, and end %q", said, c.said, c.asks+c.closes)
			}
			devicesAre(t, "", "")
			if err := refuseDevices("cyfr up"); err != nil {
				t.Errorf("after the declined update cyfr up is refused: %v", err)
			}
		})
	}
}

// An update refused before its question empties them too, said first: by
// the home step's own refusal, here its release's manifest, and by the
// program step's, here the newest release unread.
func TestAnUpdateRefusedBeforeItsQuestionStillEmptiesADeviceThisMachineDoesNotHave(t *testing.T) {
	for name, refuse := range map[string]func(t *testing.T) error{
		"the manifest": func(t *testing.T) error {
			fetchManifest = func(context.Context, string) (*release.Manifest, error) {
				return nil, errors.New("dial tcp: lookup github.com: no such host")
			}
			var out bytes.Buffer
			err := runHomeUpdate(context.Background(), &out, &out, updateOptions{yes: true})
			if !strings.HasPrefix(out.String(), devicesGone("update")+"\n") {
				t.Errorf("the update said:\n%s\nwant it to begin %q", out.String(), devicesGone("update"))
			}
			return err
		},
		"the program step": func(t *testing.T) error {
			saved := latestRelease
			t.Cleanup(func() { latestRelease = saved })
			latestRelease = func(context.Context) (string, error) {
				return "", errors.New("dial tcp: lookup api.github.com: no such host")
			}
			var out bytes.Buffer
			err := runUpdate(context.Background(), &out, &out, updateOptions{yes: true})
			if !strings.Contains(out.String(), devicesGone("update")+"\n") {
				t.Errorf("the update said:\n%s\nwant it to say %q", out.String(), devicesGone("update"))
			}
			return err
		},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, false)
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.edit(".env", scenarioEnv+deviceLines("/dev/kvm", "/dev/net/tun"))
			if err := refuse(t); err == nil {
				t.Fatal("the test's premise: the update is refused")
			}
			devicesAre(t, "", "")
			if err := refuseDevices("cyfr up"); err != nil {
				t.Errorf("after the refused update cyfr up is refused: %v", err)
			}
		})
	}
}

// An update on its release that would first give the devices asks before
// it changes anything, as an offered update does: declined, or with no
// terminal and no --yes, nothing changes and nothing starts; answered yes,
// it writes them and starts. One on its release with nothing to give asks
// nothing.
func TestAnUpdateOnItsReleaseAsksBeforeItFirstGivesTheDevices(t *testing.T) {
	text := "Verifying the manifest of release 0.9.0...\nThis CYFR is on release 0.9.0 already, so there is nothing to switch; cyfr update writes this machine's devices to .env, starts it and waits for every service of its stack.\n" + devicesSignInAgain + "\n"
	for name, c := range map[string]struct {
		terminal bool
		answer   string
		yes      bool
		err      string
		out      string
		given    bool
	}{
		"declined":     {true, "no\n", false, "", text + "Update this CYFR? (yes/no) [no]: Nothing changed. Run cyfr update again when you want each person's programs in a computer of their own.\n", false},
		"no terminal":  {false, "", false, "Nothing changed: there is no terminal to confirm the update on. Run it again with --yes to make it, or at a terminal", text, false},
		"answered yes": {true, "yes\n", false, "", text + "Update this CYFR? (yes/no) [no]: Starting release 0.9.0...\n", true},
		"--yes":        {false, "", true, "", text + "Starting release 0.9.0...\n", true},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, true)
			s := newUpdateScenario(t, switched(shippedCompose(t)), nil)
			askWith(t, c.terminal, strings.NewReader(c.answer))
			var out bytes.Buffer
			err := runHomeUpdate(context.Background(), &out, &out, updateOptions{yes: c.yes})
			if (err == nil) != (c.err == "") || (err != nil && err.Error() != c.err) {
				t.Fatalf("the update answered %v, want %q:\n%s", err, c.err, out.String())
			}
			if !strings.HasPrefix(out.String(), c.out) {
				t.Errorf("the update said %q, want it to begin %q", out.String(), c.out)
			}
			if c.given {
				devicesAre(t, "/dev/kvm", "/dev/net/tun")
				return
			}
			if got := read(t, filepath.Join(s.project, ".env")); got != scenarioEnv {
				t.Errorf("the update left .env as %q", got)
			}
			s.nothingStopped()
		})
	}

	devicesHere(t, true)
	s := newUpdateScenario(t, switched(shippedCompose(t)), nil)
	s.edit(".env", scenarioEnv+deviceLines("/dev/kvm", "/dev/net/tun"))
	askWith(t, true, strings.NewReader("no\n"))
	var out bytes.Buffer
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{}); err != nil || strings.Contains(out.String(), "(yes/no)") {
		t.Fatalf("an update on its release with the devices given answered %v, or asked:\n%s", err, out.String())
	}
}

// The devices an update writes are the ones it read when it began, which
// its offer showed: never read again at the write.
func TestTheUpdateWritesTheDevicesItShowed(t *testing.T) {
	for release, compose := range map[string]func(*testing.T) []byte{
		"switch":         shippedCompose,
		"on its release": func(t *testing.T) []byte { return switched(shippedCompose(t)) },
	} {
		t.Run(release, func(t *testing.T) {
			saved := machine.devices
			t.Cleanup(func() { machine.devices = saved })
			reads := 0
			machine.devices = func() bool { reads++; return reads == 1 }
			s := newUpdateScenario(t, compose(t), nil)
			out, err := s.run(context.Background())
			if err != nil {
				t.Fatalf("update: %v\n%s", err, out)
			}
			if !strings.Contains(out, devicesSignInAgain+"\n") {
				t.Errorf("the update did not say what giving the devices removes:\n%s", out)
			}
			devicesAre(t, "/dev/kvm", "/dev/net/tun")
			if reads != 1 {
				t.Errorf("the update read the machine's devices %d times, want once", reads)
			}
		})
	}
}

// The CYFR app's confirmed update holds to the devices its offer showed:
// where this machine's devices, or .env's, changed since, it changes
// nothing and the app offers again; where neither did, it is made, the
// devices with it. On a home on its release, the offer that would first
// give the devices shows that change.
func TestTheAppsConfirmedUpdateHoldsToTheDevicesItShowed(t *testing.T) {
	refused := "What updating this CYFR changes is not the change the CYFR app showed, so nothing was changed. Open Update CYFR in the app again to see the change as it is now"
	for release, compose := range map[string]func(*testing.T) []byte{
		"switch":         shippedCompose,
		"on its release": func(t *testing.T) []byte { return switched(shippedCompose(t)) },
	} {
		for name, change := range map[string]func(t *testing.T, s *updateScenario){
			"the machine's devices changed": func(t *testing.T, s *updateScenario) { devicesHere(t, false) },
			".env's devices changed":        func(t *testing.T, s *updateScenario) { s.edit(".env", scenarioEnv+deviceLines("", "/dev/net/tun")) },
			"nothing changed":               func(t *testing.T, s *updateScenario) {},
		} {
			t.Run(release+", "+name, func(t *testing.T) {
				devicesHere(t, true)
				s := newUpdateScenario(t, compose(t), nil)
				var out bytes.Buffer
				if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
					t.Fatalf("the app's offer answered %v:\n%s", err, out.String())
				}
				shown := offered(t, out.String())
				if shown.Confirmation == "" || !strings.Contains(shown.Change, devicesSignInAgain+"\n") {
					t.Fatalf("the app's offer shows %+v, want a change that says what giving the devices removes", shown)
				}
				if shown.OnRelease != (release == "on its release") {
					t.Fatalf("the app's offer says it is on its release: %t, at its %s", shown.OnRelease, release)
				}
				change(t, s)
				before := read(t, filepath.Join(s.project, ".env"))
				out.Reset()
				err := runHomeUpdate(context.Background(), &out, &out, updateOptions{confirmed: shown.Confirmation})
				if name == "nothing changed" {
					if err != nil {
						t.Fatalf("the confirmed update answered %v:\n%s", err, out.String())
					}
					devicesAre(t, "/dev/kvm", "/dev/net/tun")
					return
				}
				if err == nil || err.Error() != refused {
					t.Fatalf("the confirmed update answered %v, want %q:\n%s", err, refused, out.String())
				}
				if got := read(t, filepath.Join(s.project, ".env")); got != before {
					t.Errorf("the refused update left .env as %q, want %q", got, before)
				}
			})
		}
	}
}
