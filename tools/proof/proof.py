#!/usr/bin/env python3
"""The Playground's release proof: its app on the tier-1 platforms (and on
Linux and Windows when named), each with its one renderer (SwiftUI on iOS
and the Mac, Compose on Android, React on the web, OpenGL on Linux, DirectX
on Windows): its projects, a project open, and 2048 and the Pokédex built on
the device by the compiler it carries and running
(ISO_PLAYGROUND_RUN_PROJECT=<name>). Isomer's own proof (the Storybook) is
isomer's tools/proof/proof.py, whose machinery this is.

  tools/proof/proof.py [ios] [macos] [android] [web] [linux] [windows] --review <dir>
      [--commit <sha>] [--version 0.47.N] [--quick] [--held windows=<file>]
      [--web-toolchain <dir>] [--linux-packages <dir>] [--android-abi x86_64]
      [--build-to <dir> | --from <dir> [--here]]

CI's proof builds in its Linux container and pictures on GitHub's own
machines (tools/ci/proof.sh): --build-to keeps each platform's app in
<dir>/<platform>/ and stops; --from <dir> pictures those rather than
building; --here pictures on this machine, nothing leased (an iPhone
simulator made here, this Mac's screen, the emulator adb sees, this
machine's Chrome).

--quick takes the same screens (the Playground's are few) and marks the
runs `"scope": "quick"`, naming no release, so they never stand for one: a
release is always proven by a full run.

What changes between runs without the app changing is held still or left
out: the iPhone's status bar (oss's simctl override from an ios lease's
start: 9:41; a simulator made here, the same override), Android's cropped
off (its demo mode held it still one run and not the next), and on the
desktops everything but the app's window (a Mac's and Windows' screenshots
are cropped to the app's frontmost window (a Mac slot's by OS Server), a
Mac's rounded corners cut away, Linux's below GNOME's top bar and right of
its dock).

Each platform's pictures are a folder of the review store's snapshots,
<dir>/review-<platform>-playground/manifest.json (AttilaTheFun/reviews'
MANIFEST.md). CI runs it (tools/ci/proof.sh), which makes the `proof`
artifact of those folders' pictures; only CI's proof counts. The launch
hooks reach each platform as it passes a process environment: simctl's
SIMCTL_CHILD_ (`oss machine simctl --env`), `open --env`, an Android
intent's ISO_ extras, the web page's ISO_ query, the desktops' environment.

The builds are this checkout's, made here (-c opt) before the platforms
start, except Linux's (packaged in a Linux container by tools/ci/proof.sh,
--linux-packages) and Windows' (on its VM). Then the platforms run at once,
each on a lease of its own (an iOS simulator, in OS Server's primary macOS
VM, driven through oss alone (PROOF_IOS=local: simctl on this Mac, for a
server whose simulators are its Mac's), an Android emulator, a slot of OS
Server's primary macOS VM (PROOF_MAC=vm: a macOS VM of its own), Linux and
Windows VMs; the web in this machine's headless Chrome), released however
the run ends. Stamp the build's version first, as CI does
(tools/playground/stamp.py), and check the files out after.
"""
import argparse, json, os, re, shlex, shutil, subprocess, sys, tempfile, threading, time, urllib.parse

# The repository's root: the Playground's Bazel module.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = {"name": "Playground", "bundle": "com.LoganShire.IsomerPlayground"}
# The Playground's screens: its opening screen, a project open, and two
# projects built on the device and running (2048; the Pokédex, whose
# @Observable needs the compiler's macro plugins).
PLAYGROUND_SHOTS = [
    ("projects", "Projects", {}, "open"),
    ("project", "A project (2048)", {"ISO_PLAYGROUND_OPEN_PROJECT": "2048"}, "open"),
    ("game2048", "2048, built here and running", {"ISO_PLAYGROUND_RUN_PROJECT": "2048"}, "run"),
    ("pokedex", "The Pokédex, built here and running", {"ISO_PLAYGROUND_RUN_PROJECT": "Pokédex"}, "run"),
]

# What the app is launched with, whatever the machine: UTC, so anything it
# shows of the clock shows the same on GitHub's runners (UTC) and OS
# Server's Macs (US Eastern), as the rule for pictures asks (a fixed time
# zone). Android and the web set theirs below.
HELD_ENVIRONMENT = {"TZ": "UTC"}

failures = []
lock = threading.Lock()
# --here: the platform is this machine (GitHub's runners, in CI's proof: an
# iPhone simulator made here, this Mac's screen, the emulator adb sees, this
# machine's Chrome), nothing leased.
HERE = False


def log(message):
    name = threading.current_thread().name
    with lock:
        print(f"[proof {name}] {message}", flush=True)


def failed(command, result):
    """A command's failure, for the log: its output, less any password
    (oss prints a lease it fails to reach, its passwords too, and CI's log
    is public)."""
    text = f"{command}\n{result.stdout[-3000:]}{result.stderr[-3000:]}"
    return RuntimeError(re.sub(r'("\w*[Pp]assword"\s*:\s*")[^"]*"', r'\1***"', text))


def sh(command, check=True, cwd=ROOT, **kwargs):
    result = subprocess.run(command, shell=isinstance(command, str), cwd=cwd, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        raise failed(command, result)
    return result


def bazel_output(target, *flags, suffix=""):
    sh(["bazel", "build", target, *flags])
    files = sh(["bazel", "cquery", "--output=files", target, *flags]).stdout.split()
    # cquery names outputs under the execution root (no bazel-out link in
    # the workspace where convenience symlinks are off, as in CI).
    root = sh(["bazel", "info", "execution_root", *flags]).stdout.strip()
    return os.path.join(root, next(f for f in files if f.endswith(suffix)))


def crop(path, box):
    """A screenshot cut down to `box` (left, top, right, bottom), within the
    screenshot (a window larger than the screen is cut to what shows); kept
    whole when nothing of the box is on it."""
    try:
        from PIL import Image
        image = Image.open(path)
        left, top, right, bottom = box
        left, top, right, bottom = max(0, left), max(0, top), min(image.width, right), min(image.height, bottom)
        if left < right and top < bottom:
            image.crop((left, top, right, bottom)).save(path)
    except Exception as error:
        log(f"crop {os.path.basename(path)}: {error}")


# A Mac window's corners in the VM's screenshots (macOS 27, at 1x): the curve
# is 14 pixels in from its outer pixel; two more for a darker shadow.
CORNER_RADIUS = 16


def flat(path):
    """Whether a capture is one colour throughout (a window that came back
    unpainted)."""
    from PIL import Image
    return all(low == high for low, high in Image.open(path).convert("RGB").getextrema())


def cut_corners(path):
    """A Mac window's shot without what isn't the window's: its outer pixel
    and the curve of its corners, where its edge blends with its shadow and
    the desktop behind (OS Server's proof saw the edge 15-20 levels darker
    in one of two runs, the window's own pixels the same), made transparent."""
    try:
        from PIL import Image, ImageDraw
        image = Image.open(path).convert("RGBA")
        image = image.crop((1, 1, image.width - 1, image.height - 1))
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius=CORNER_RADIUS, fill=255)
        Image.composite(image, Image.new("RGBA", image.size, (0, 0, 0, 0)), mask).save(path)
    except Exception as error:
        log(f"corners {os.path.basename(path)}: {error}")


def steady_shot(shoot, path, tries=6, pause=2.0):
    """`shoot(path)` again until two shots in a row are the same, at most
    `tries` more: what was still settling as the screen came up (iOS's
    glass toolbar of a build that just started) settles before it counts."""
    shoot(path)
    again = path + ".again.png"
    for _ in range(tries):
        time.sleep(pause)
        shoot(again)
        same = open(path, "rb").read() == open(again, "rb").read()
        os.replace(again, path)
        if same:
            return


def wait_until(check, seconds):
    """Whether `check()` came true within `seconds`."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


# --- oss

held = {}


def lease(platform, *flags):
    """An oss lease's exports (OSS_ID, OSS_SSH_PORT, OSS_UDID…)."""
    if platform in held:
        env = dict(re.findall(r"(OSS_[A-Z_]+)='([^']*)'", open(held[platform]).read()))
        env["held"] = True
        log(f"using held {platform} {env['OSS_ID']}")
        return env
    # --wait: CI's leases queue for a machine other runs hold.
    out = sh(["oss", "machine", "lease", platform, "--exports", "--minutes=180", "--wait", *flags]).stdout
    env = dict(re.findall(r"(OSS_[A-Z_]+)='([^']*)'", out))
    # Its VNC password never in CI's log (a workflow command; the line itself isn't shown).
    if os.environ.get("GITHUB_ACTIONS") and env.get("OSS_VNC_PASSWORD"):
        print(f"::add-mask::{env['OSS_VNC_PASSWORD']}", flush=True)
    log(f"leased {platform} {env['OSS_ID']}")
    return env


def release(env):
    if env and not env.get("held"):
        sh(["oss", "machine", "release", env["OSS_ID"]], check=False)


def ssh(env, command, check=True):
    command_line = ["oss", "machine", "ssh", env["OSS_ID"], "--", command]
    result = sh(command_line, check=False)
    if result.returncode != 0 and result.stderr.startswith("oss:"):
        # oss failed before ssh ran (looking the lease up: once, a Windows
        # build's packaging step), so the command never did: once more.
        time.sleep(5)
        result = sh(command_line, check=False)
    if check and result.returncode != 0:
        raise failed(command_line, result)
    return result


def scp(env, source, destination):
    sh(["scp", "-q", "-P", env["OSS_SSH_PORT"], "-o", f"UserKnownHostsFile={os.path.expanduser('~/.local/state/oss/known_hosts-' + env['OSS_ID'])}",
        "-o", "StrictHostKeyChecking=accept-new", source, f"{env.get('OSS_SSH_USER', 'runner')}@127.0.0.1:{destination}"])


def oss_shot(env, path):
    sh(["oss", "machine", "screenshot", env["OSS_ID"], path])


# --- The review store

class Review:
    def __init__(self, folder, commit, version, quick=False):
        self.folder, self.commit, self.version, self.quick = folder, commit, version, quick

    def manifest(self, name, device, orientation, items):
        """A cell's manifest. A quick run's names no release and says so:
        it never stands for one."""
        manifest = {"schema": 1, "app": APP["name"], "version": self.version,
                    "release": None if self.quick else self.version, "commit": self.commit, "kind": "snapshots",
                    "target": name, "device": device, "orientation": orientation,
                    "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items}
        if self.quick:
            manifest["scope"] = "quick"
        return manifest

    def dir(self, name):
        path = os.path.join(self.folder, f"review-{name}")
        os.makedirs(path, exist_ok=True)
        return path

    def cell(self, name, device, orientation, shots):
        """`shots`: (item name, capture file) pairs; a missing capture is a failure."""
        out = self.dir(name)
        items = [{"name": item, "status": "new", "capture": capture} for item, capture in shots
                 if os.path.exists(os.path.join(out, capture))]
        missing = [item for item, capture in shots if not os.path.exists(os.path.join(out, capture))]
        with lock:
            failures.extend(f"{name}: {item}" for item in missing)
        json.dump(self.manifest(name, device, orientation, items), open(os.path.join(out, "manifest.json"), "w"), indent=1)
        log(f"{name}: {len(items)} screens" + (f", MISSING {missing}" if missing else ""))


def shoot_playground(review, platform, device, orientation, launcher, waits):
    """The Playground's screens on one platform, into
    review-<platform>-playground. `launcher(environment, wait, path)`
    launches the app afresh with `environment`, waits, and shoots `path`.
    `waits`: seconds after a launch: open (the app's opening screen or a
    project), run (a project built and running)."""
    name = f"{platform}-playground"
    out = review.dir(name)
    shots = []
    for slug, title, environment, kind in PLAYGROUND_SHOTS:
        capture = f"{slug}.png"
        try:
            launcher(environment, waits[kind], os.path.join(out, capture))
        except Exception as error:
            log(f"playground {slug}: {error}")
        shots.append((title, capture))
    review.cell(name, device, orientation, shots)


# --- iOS (an oss simulator lease: since OS Server put its `ios` leases in
# its primary macOS VM, the simulator isn't on this Mac, so everything goes
# through oss's verbs: simctl, upload, download, screenshot. PROOF_IOS=local:
# simctl here, against the lease's OSS_UDID, for a server whose simulators
# are its own Mac's, primary.macos.simulators 0. --here: a simulator made
# on this Mac, GitHub's `xcode-27` runner.)

def build_ios():
    # The compiler linked into the app (its staged embedded_toolchain).
    return bazel_output("//apple/playground_ios_application:playground_ios_sim_application",
                        "-c", "opt", "--ios_multi_cpus=sim_arm64", "--define", "iso_playground_embedded=1", suffix=".ipa")


def oss_api():
    """The oss server's API level (`oss capabilities`)."""
    return json.loads(sh(["oss", "capabilities"]).stdout).get("api", 0)


class LeasedSimulator:
    """An oss `ios` lease's simulator, wherever OS Server runs it (its
    primary macOS VM since 0.14), through oss alone: `simctl` (`--env=NAME=
    VALUE` its SIMCTL_CHILD_NAME), `screenshot` (masked, the status bar held
    at 9:41 since the lease began). API 20 for the environment."""

    def __init__(self, lease_id):
        self.id = lease_id

    def simctl(self, *arguments, environment=None, check=True):
        command = ["oss", "machine", "simctl", self.id]
        if environment:
            command += [f"--env={key}={value}" for key, value in environment.items()] + ["--"]
        return sh(command + list(arguments), check=check)

    def install_ipa(self, ipa):
        # Through OS Server's storage, which unpacks the .ipa itself: simctl
        # install of a local .app zips it here first, with ditto, which only
        # a Mac has (the proof runs in a Linux container).
        put = json.loads(sh(["oss", "storage", "put", ipa, "--ttl=2h", "--json"]).stdout)
        sh(["oss", "machine", "install", self.id, put["object"]["sha256"]])

    def prepare(self):
        # Light, as every platform's shots are. (The status bar: oss holds
        # every ios lease's at 9:41 from the start.)
        self.simctl("ui", "booted", "appearance", "light", check=False)

    def terminate(self, bundle):
        self.simctl("terminate", "booted", bundle, check=False)   # not running: fine

    def launch(self, bundle, environment):
        result = self.simctl("launch", "booted", bundle, environment=environment, check=False)
        if result.returncode != 0:
            log(f"launch {bundle}: {result.stdout[-500:]}{result.stderr[-500:]}")

    def screenshot(self, path):
        sh(["oss", "machine", "screenshot", self.id, path])


class LocalSimulator:
    """PROOF_IOS=local or --here: the simulator on this Mac, by simctl here
    (OSS_UDID)."""

    def __init__(self, udid):
        self.udid = udid

    def install(self, app):
        sh(["xcrun", "simctl", "install", self.udid, app])

    def prepare(self):
        # The status bar held still, as every snapshot holds it: 9:41, full
        # Wi-Fi and signal, a full battery, no carrier.
        sh(["xcrun", "simctl", "status_bar", self.udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
            "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
            "--batteryState", "charged", "--batteryLevel", "100"], check=False)
        sh(["xcrun", "simctl", "ui", self.udid, "appearance", "light"], check=False)

    def terminate(self, bundle):
        sh(["xcrun", "simctl", "terminate", self.udid, bundle], check=False)

    def launch(self, bundle, environment):
        variables = dict(os.environ)
        for key, value in environment.items():
            variables["SIMCTL_CHILD_" + key] = value
        subprocess.run(["xcrun", "simctl", "launch", self.udid, bundle], env=variables, capture_output=True)

    def screenshot(self, path):
        sh(["xcrun", "simctl", "io", self.udid, "screenshot", "--mask=black", path])


def here_simulator():
    """--here: an iPhone simulator of the run's own on this Mac (GitHub's
    `xcode-27` runner), as OS Server's ios leases are: an iPhone 17 of the
    newest iOS this Xcode has (PROOF_IOS_DEVICE, PROOF_IOS_RUNTIME to
    choose), booted. Its exports, as a lease's."""
    device = os.environ.get("PROOF_IOS_DEVICE", "iPhone 17")
    runtimes = json.loads(sh(["xcrun", "simctl", "list", "runtimes", "-j"]).stdout)["runtimes"]
    ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")
           and any(d.get("name") == device for d in r.get("supportedDeviceTypes", []))]
    wanted = os.environ.get("PROOF_IOS_RUNTIME")
    if wanted:
        ios = [r for r in ios if r["version"] == wanted]
    if not ios:
        raise RuntimeError(f"no iOS runtime here for {device} ({wanted or 'any'})")
    runtime = max(ios, key=lambda r: [int(n) for n in r["version"].split(".")])
    udid = sh(["xcrun", "simctl", "create", f"proof-{os.getpid()}", device, runtime["identifier"]]).stdout.strip()
    sh(["xcrun", "simctl", "boot", udid])
    sh(["xcrun", "simctl", "bootstatus", udid, "-b"])
    log(f"made {device}, iOS {runtime['version']}: {udid}")
    return {"OSS_ID": udid, "OSS_UDID": udid, "here": True}


def ios(review, ipa):
    local = HERE or os.environ.get("PROOF_IOS", "oss") == "local"
    if not local and (api := oss_api()) < 20:
        raise RuntimeError(f"the iPhone's proof needs OS Server's API 20 (an ios lease's launch environment); "
                           f"this server's is {api}. PROOF_IOS=local for a server whose simulators are its Mac's")
    env = here_simulator() if HERE else lease("ios")
    try:
        simulator = LocalSimulator(env["OSS_UDID"]) if local else LeasedSimulator(env["OSS_ID"])
        if local:
            work = tempfile.mkdtemp(prefix="proof-ios-")
            sh(["unzip", "-q", ipa, "-d", work])
            payload = os.path.join(work, "Payload")
            simulator.install(os.path.join(payload, os.listdir(payload)[0]))
        else:
            simulator.install_ipa(ipa)
        simulator.prepare()

        def launcher(environment, wait, path):
            # Closed first: launched with another app in front, iOS shows a
            # "◀ <that app>" link in the status bar.
            simulator.terminate(APP["bundle"])
            simulator.launch(APP["bundle"], {**HELD_ENVIRONMENT, **environment})
            time.sleep(wait)
            steady_shot(simulator.screenshot, path)

        shoot_playground(review, "ios", "iPhone (simulator)", "portrait", launcher, {"open": 5, "run": 25})
        simulator.terminate(APP["bundle"])
    finally:
        if env.get("here"):
            sh(["xcrun", "simctl", "shutdown", env["OSS_UDID"]], check=False)
            sh(["xcrun", "simctl", "delete", env["OSS_UDID"]], check=False)
        else:
            release(env)


# --- macOS (a slot of OS Server's primary macOS VM; PROOF_MAC=vm: a whole
# vanilla VM, as until 2026-11-03; --here this Mac. Either way the app
# built here, copied in)

def build_macos():
    return bazel_output("//apple/playground_macos_application", "-c", "opt", suffix=".zip")


# What the Mac app is launched with, on a slot and a VM alike. Light, as
# every platform's shots are, whatever the session is in (the VMs' and the
# primary's come up dark, and a defaults write doesn't change a running
# session's appearance): the app's own choice. A caret that doesn't blink
# (the Pokédex's focused search field was shot mid-blink): on for a day.
# Light, in the app's argument domain (AppKit reads AppleInterfaceStyle as
# a user default): the primary's screen is shared, and its user's own
# appearance (Dark, once another run set it) is not the proof's to change.
MAC_ARGUMENTS = ["-AppleInterfaceStyle", "Light", "-NSRequiresAquaSystemAppearance", "YES",
                 "-NSTextInsertionPointBlinkPeriodOn", "100000000", "-NSTextInsertionPointBlinkPeriodOff", "0"]

# A slot's app, run by `oss machine exec --gui` in the primary's console
# session (its user's, not the slot's). Started by `open -n -a`, as the Dock
# starts it, so that its window is frontmost and active (started by its
# binary, it stayed behind, inactive: grey traffic lights, no vibrancy), its
# environment passed by `--env` and its arguments by `--args`; then found by
# its binary's path, which is under this slot's own home (no other slot's
# copy matches it), waited for, and ended with the exec (the server signals
# the exec's process group when the client goes, and this script ends the
# app then).
SLOT_LAUNCH = """
app=$1; shift
binary="$app/Contents/MacOS/$(basename "$app" .app)"
# Its environment for the app (LaunchServices starts it, not this shell).
set --  --args "$@"
for name in $(env | grep -oE '^(ISO_[A-Z0-9_]+|CFFIXED_USER_HOME)=' | tr -d =); do
    set -- --env "$name=$(printenv "$name")" "$@"
done
/usr/bin/open -n -a "$app" "$@" || exit 1
for _ in $(seq 1 50); do pid=$(/usr/bin/pgrep -n -f "^$binary") && break; sleep 0.2; done
[ -n "$pid" ] || exit 1
trap 'kill "$pid" 2> /dev/null; exit 0' TERM INT HUP
while kill -0 "$pid" 2> /dev/null; do sleep 1; done
"""


def macos(review, archive):
    """On a slot of OS Server's primary macOS VM (a `mac` lease), unless
    PROOF_MAC=vm: then a whole macOS VM of its own; --here this Mac."""
    if HERE:
        macos_here(review, archive)
    elif os.environ.get("PROOF_MAC", "slot") == "vm":
        macos_vm(review, archive)
    else:
        macos_slot(review, archive)


# A process's main window on this Mac's screen, from CoreGraphics' window
# list (its owners and numbers need no permission): its number, the largest
# of its windows at the normal level, or nothing.
MAC_WINDOW_JS = r"""
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = Number(argv[0]);
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(
    $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
  let number = '', area = 0;
  for (let i = 0; i < list.count; i++) {
    const w = list.objectAtIndex(i);
    if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerPID')) !== pid) continue;
    if (ObjC.unwrap(w.objectForKey('kCGWindowLayer')) !== 0) continue;
    const b = w.objectForKey('kCGWindowBounds');
    const a = ObjC.unwrap(b.objectForKey('Width')) * ObjC.unwrap(b.objectForKey('Height'));
    if (a > area) { area = a; number = String(ObjC.unwrap(w.objectForKey('kCGWindowNumber'))); }
  }
  return number;
}
"""


def macos_here(review, archive):
    """--here: this Mac's own screen (GitHub's `xcode-27` runner, its screen
    made OS Server's slots' 1920 by 1200 by tools/ci/proof.sh): the app
    unzipped here, opened as the Dock opens it, pictured by its window alone
    (`screencapture -l`: no shadow, nothing behind), with a home of the
    proof's own (CFFIXED_USER_HOME), as on a slot."""
    # Its real path: /var/folders is /private/var/folders to a running
    # app, which pgrep finds by its binary's path.
    work = os.path.realpath(tempfile.mkdtemp(prefix="proof-macos-"))
    home = os.path.join(work, "home")
    os.makedirs(home)
    script = os.path.join(work, "window.js")
    with open(script, "w") as file:
        file.write(MAC_WINDOW_JS)
    # No "quit unexpectedly" dialog over the next launch after a crash.
    sh(["defaults", "write", "com.apple.CrashReporter", "DialogType", "-string", "none"], check=False)
    sh(["ditto", "-x", "-k", archive, work])
    bundle = os.path.join(work, f"{APP['name']}.app")
    running = {}

    def alive(pid):
        return subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0

    def stop():
        pid = running.pop("pid", None)
        if pid:
            subprocess.run(["kill", str(pid)], capture_output=True)
            if not wait_until(lambda: not alive(pid), 10):
                subprocess.run(["kill", "-9", str(pid)], capture_output=True)

    def window():
        pid = running.get("pid")
        return sh(["osascript", "-l", "JavaScript", script, str(pid)], check=False).stdout.strip() if pid else ""

    def shoot(path):
        # A flat capture is taken again, as on a slot.
        for attempt in range(3):
            number = window()
            if not number:
                raise RuntimeError(f"no window of {APP['name']} on the screen")
            sh(["screencapture", "-x", "-o", "-l", number, path])
            if not flat(path):
                break
            log(f"macos {os.path.basename(path)}: a flat capture (try {attempt + 1} of 3)")
            time.sleep(2)
        cut_corners(path)

    def launcher(environment, wait, path):
        stop()
        executable = sh(["plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-",
                         os.path.join(bundle, "Contents", "Info.plist")]).stdout.strip()
        binary = os.path.join(bundle, "Contents", "MacOS", executable)
        command = ["open", "-n", "-a", bundle]
        for key, value in {"CFFIXED_USER_HOME": home, **HELD_ENVIRONMENT, **environment}.items():
            command += ["--env", f"{key}={value}"]
        sh(command + ["--args", *MAC_ARGUMENTS, "-AppleShowScrollBars", "WhenScrolling",
                      "-ApplePersistenceIgnoreState", "YES"])

        def started():
            found = subprocess.run(["pgrep", "-n", "-f", f"^{binary}"], capture_output=True, text=True).stdout.strip()
            if found:
                running["pid"] = int(found)
            return bool(found)
        if not wait_until(started, 30):
            raise RuntimeError(f"{APP['name']} didn't start")
        if not wait_until(lambda: window() != "", 60):
            raise RuntimeError(f"no window of {APP['name']} in a minute")
        time.sleep(wait)
        shoot(path)

    version = sh(["sw_vers", "-productVersion"]).stdout.strip()
    try:
        shoot_playground(review, "macos", f"Mac (macOS {version})", "landscape", launcher, {"open": 6, "run": 30})
    finally:
        stop()


def macos_slot(review, archive):
    """The Mac's pictures on a slot: the app unzipped in the slot's home, run
    by `exec --gui` (one GUI run at a time on the primary, the server
    queueing the others' turns) and pictured by `screenshot --window`, which
    the server crops to the app's frontmost window.

    The primary is shared and lives on, where a VM lease was fresh: what
    the app keeps goes to a home of the proof's own (CFFIXED_USER_HOME, which
    Foundation's home directory, Application Support and the defaults
    follow), not the console user's, so the Playground's projects and
    defaults start as on a fresh VM; and the scroll bars are set in the
    app's argument domain rather than the session's defaults."""
    env = lease("mac")
    slot = env["OSS_ID"]
    running = []

    def run(*command, check=True):
        return sh(["oss", "machine", "exec", slot, "--", *command], check=check)

    def stop():
        # The exec's client ended: the server ends its process group (TERM,
        # then KILL), so the app with it.
        while running:
            process = running.pop()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

    work = f"/tmp/oss-proof-{slot}"
    home = f"{work}/home"
    name = APP["name"]
    try:
        apps = run("/bin/sh", "-c", 'printf %s "$HOME"').stdout.strip()
        sh(["oss", "machine", "upload", slot, archive, "playground.zip"])
        run("/bin/sh", "-c", 'rm -rf "$1.app" && /usr/bin/ditto -x -k playground.zip . && rm playground.zip', "unzip", name)
        # The slot's user makes it; the console user's app writes in it.
        run("/bin/sh", "-c", 'rm -rf "$1" && mkdir -p "$1/home" && chmod 777 "$1" "$1/home"', "work", work)
        logs = tempfile.mkdtemp(prefix="proof-macos-")

        def shoot(path):
            # A window's capture can come back all black, between two good
            # ones: a flat picture is taken again.
            for attempt in range(3):
                sh(["oss", "machine", "screenshot", slot, path, f"--window={APP['bundle']}"])
                if not flat(path):
                    break
                log(f"macos {os.path.basename(path)}: a flat capture (try {attempt + 1} of 3)")
                time.sleep(2)
            cut_corners(path)

        def launcher(environment, wait, path):
            stop()
            variables = {"CFFIXED_USER_HOME": home, **HELD_ENVIRONMENT, **environment}
            command = ["oss", "machine", "exec", slot, "--gui", *(f"--env={k}={v}" for k, v in variables.items()), "--",
                       "/bin/sh", "-c", SLOT_LAUNCH, "launch", f"{apps}/{name}.app",
                       *MAC_ARGUMENTS, "-AppleShowScrollBars", "WhenScrolling", "-ApplePersistenceIgnoreState", "YES"]
            output = open(os.path.join(logs, "playground.log"), "ab")
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
            running.append(process)
            # Its window once the GUI turn is the slot's (another slot's run
            # may hold it): until then the screenshot is refused.
            probe = os.path.join(logs, "window.png")
            deadline = time.time() + 900
            while subprocess.run(["oss", "machine", "screenshot", slot, probe, f"--window={APP['bundle']}"],
                                 capture_output=True).returncode != 0:
                if process.poll() is not None:
                    raise RuntimeError(f"{name} ended ({process.returncode}) before its window showed: {output.name}")
                if time.time() > deadline:
                    raise RuntimeError(f"no window of {name} in 15 minutes")
                time.sleep(1)
            time.sleep(wait)
            shoot(path)

        shoot_playground(review, "macos", "Mac (macOS 27 VM)", "landscape", launcher, {"open": 6, "run": 30})
    finally:
        stop()
        # The proof's folder outlives the slot (it's the primary's /tmp, not
        # the slot's home): the console user's files in it removed by that
        # user (a GUI turn), then the folder by the slot's.
        sh(["oss", "machine", "exec", slot, "--gui", "--", "/bin/rm", "-rf", home], check=False)
        run("/bin/rm", "-rf", work, check=False)
        release(env)


def macos_vm(review, archive):
    env = lease("macos")
    name = APP["name"]
    try:
        scp(env, archive, "/tmp/playground.zip")
        ssh(env, f"cd /tmp && rm -rf {name}.app && ditto -x -k playground.zip .")
        # The app's window, where the screenshot is cropped to (window_rect.swift).
        helper = os.path.join(tempfile.mkdtemp(prefix="proof-macos-"), "window_rect")
        sh(["swiftc", "-O", "-target", "arm64-apple-macos14", os.path.join(ROOT, "tools", "proof", "window_rect.swift"), "-o", helper])
        scp(env, helper, "/tmp/window_rect")
        # Scroll bars as overlays, shown only while scrolling. "Automatic" (the
        # default) chose by the pointing devices it saw, so one lease drew
        # legacy scroll bars, which take the sidebar's width, and another
        # didn't. Set before the app opens, which reads it as it starts, by
        # runner itself (the SSH session's user): under `launchctl asuser`
        # it was root's, and runner's apps never saw it.
        ssh(env, "defaults write -g AppleShowScrollBars -string WhenScrolling")
        shown = ssh(env, "defaults read -g AppleShowScrollBars", check=False).stdout.strip()
        if shown != "WhenScrolling":
            raise RuntimeError(f"AppleShowScrollBars is {shown!r}, not WhenScrolling")

        def shoot(path):
            oss_shot(env, path)
            rect = ssh(env, f"sudo launchctl asuser $(id -u runner) /tmp/window_rect {name}", check=False).stdout.split()
            if len(rect) == 4:
                x, y, w, h = map(int, rect)
                crop(path, (x, y, x + w, y + h))
                cut_corners(path)

        def launcher(environment, wait, path):
            ssh(env, f"pkill -x {name}; sleep 1", check=False)
            flags = " ".join(f"--env {k}={shlex.quote(v)}" for k, v in {**HELD_ENVIRONMENT, **environment}.items())
            ssh(env, f"sudo launchctl asuser $(id -u runner) open -n {flags} /tmp/{name}.app"
                f" --args {shlex.join(MAC_ARGUMENTS)}")
            time.sleep(wait)
            shoot(path)

        shoot_playground(review, "macos", "Mac (macOS 27 VM)", "landscape", launcher, {"open": 6, "run": 30})
        ssh(env, f"pkill -x {name}", check=False)
    finally:
        release(env)


# --- Android (an oss emulator lease)

def build_android(abi=None):
    """The app, for `abi` if given (x86_64, for GitHub's Ubuntu runner's
    emulator, once the compiler it carries has an x86_64 build: it is
    arm64's alone today)."""
    flags = ["-c", "opt"] + ([f"--android_platforms=@rules_android//:{abi}"] if abi else [])
    return bazel_output("//android/playground_android_application:playground_android_application_apk", *flags, suffix="_apk.apk")


def android(review, apk):
    """On an emulator leased from OS Server, or --here the one this
    machine's adb sees (PROOF_ADB, PROOF_ANDROID_SERIAL: GitHub's Ubuntu
    runner's, tools/ci/hosted_android_emulator.sh)."""
    env = None if HERE else lease("android")
    try:
        if HERE:
            adb = [os.environ.get("PROOF_ADB", "adb"), "-s", os.environ["PROOF_ANDROID_SERIAL"]]
        else:
            adb = ["oss", "machine", "adb", env["OSS_ID"], "--"]
        bundle = APP["bundle"]
        sh(adb + ["install", "-r", apk])
        sh(adb + ["shell", "pm", "clear", bundle], check=False)

        def launcher(environment, wait, path):
            sh(adb + ["shell", "am", "force-stop", bundle], check=False)
            arguments = []
            for key, value in environment.items(): arguments += ["--es", key, value]
            # adb shell joins its arguments into one line for the device's sh.
            sh(adb + ["shell", "am", "start", "-n", f"{bundle}/.MainActivity", *map(shlex.quote, arguments)])
            time.sleep(wait)
            shot(path)

        # Light, as every platform's shots are.
        sh(adb + ["shell", "cmd", "uimode", "night", "no"], check=False)
        # UTC, as every platform's pictures (HELD_ENVIRONMENT).
        sh(adb + ["shell", "cmd", "alarm", "set-timezone", "UTC"], check=False)
        # The status bar is cropped off every picture, as the desktops' shots
        # are cropped to the app's window: SystemUI's demo mode held it still
        # one run and not the next (the cellular icon drawn two ways, then the
        # Wi-Fi icon gone, then no status bar at all, on one emulator image),
        # and every such run changed every Android picture. Its height is
        # the phone's own (the statusBars inset: 63 px on the 420 dpi phone).
        windows = sh(adb + ["shell", "dumpsys", "window"], check=False).stdout
        inset = re.search(r"type=statusBars frame=\[0,0\]\[\d+,(\d+)\]", windows)
        if not inset:
            raise SystemExit("proof: no status bar inset in the Android phone's dumpsys window")
        status_bar = int(inset.group(1))

        def shot(path):
            if HERE:
                with open(path, "wb") as file:
                    subprocess.run(adb + ["exec-out", "screencap", "-p"], stdout=file, check=True)
            else:
                oss_shot(env, path)
            from PIL import Image
            image = Image.open(path)
            image.crop((0, status_bar, image.width, image.height)).save(path)
        # The first launch after an install shows the splash a while longer.
        launcher({}, 8, os.path.join(tempfile.mkdtemp(), "warm.png"))
        shoot_playground(review, "android", "Android phone (emulator)", "portrait", launcher, {"open": 6, "run": 30})
        sh(adb + ["shell", "am", "force-stop", bundle], check=False)
    finally:
        release(env)


# --- The web (this machine's headless Chrome, the optimized site served here)

def build_web(toolchain):
    """The Playground's whole site (the splash page and the Playground under
    playground/), with the in-browser compiler staged from `toolchain`
    (package_site.sh)."""
    work = tempfile.mkdtemp(prefix="proof-web-")
    sh([os.path.join(ROOT, "tools", "playground", "package_site.sh"), "--toolchain-from", toolchain,
        "--out", os.path.join(work, "site.tar.gz")])
    os.makedirs(os.path.join(work, "site"))
    sh(["tar", "-xzf", os.path.join(work, "site.tar.gz"), "-C", os.path.join(work, "site")])
    return os.path.join(work, "site")


def web(review, site):
    port = 8700 + os.getpid() % 150
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                              cwd=site, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cdp = os.path.join(ROOT, "tools", "testing", "cdp.py")
    # Chrome's profile is the run's own: a page's stored state outlasted the
    # run that made it in a shared one (the Playground opened on the project
    # the last run's 2048 shot had chosen).
    profile = tempfile.mkdtemp(prefix="proof-chrome-")
    # Light, whatever this machine's appearance is (Chrome follows it).
    chrome_env = dict(os.environ, CDP_PROFILE=profile, CDP_COLOR_SCHEME="light", **HELD_ENVIRONMENT)
    try:
        time.sleep(1)

        def launcher(environment, wait, path):
            query = "&".join(["renderer=react"] + [f"{k}={urllib.parse.quote(v)}" for k, v in environment.items()])
            url = f"http://127.0.0.1:{port}/playground/?{query}"
            # The page drawn (the renderer's first tree committed) before the
            # wait, which is then the settling: a fixed wait alone shot a blank
            # page when a load ran slow. A page that never drew in a minute is
            # loaded again: one run's Pokédex was the bare background.
            for attempt in range(3):
                shot = sh([sys.executable, cdp, url, path, "until=window.__isoLastTree", f"wait={wait}",
                           "width=1280", "height=800"], env=chrome_env)
                if "UNTIL timed out" not in shot.stdout:
                    break
                log(f"web {os.path.basename(path)}: the page never drew (try {attempt + 1} of 3)")

        # A fresh Chrome profile's first load compiles the reactor: warmed up
        # before the shots.
        launcher({}, 15, os.path.join(tempfile.mkdtemp(), "warm.png"))
        # A run fetches and starts the in-browser compiler first.
        shoot_playground(review, "web", "Chrome (desktop width)", "landscape", launcher, {"open": 8, "run": 75})
    finally:
        server.terminate()
        shutil.rmtree(profile, ignore_errors=True)


# --- Linux (packaged in a Linux container by tools/ci/proof.sh, run on an oss VM)

def build_linux(packaged):
    """The app packaged already: `<packaged>/playground-linux.tgz` (CI's,
    from a container: tools/ci/proof.sh, when PROOF_PLATFORMS names linux)."""
    if not packaged:
        raise SystemExit("proof: Linux needs --linux-packages (the app packaged in a Linux container, as tools/ci/proof.sh does)")
    return os.path.join(packaged, "playground-linux.tgz")


def linux(review, package):
    env = lease("linux", "--config=dev")
    try:
        scp(env, package, "/tmp/playground-linux.tgz")
        ssh(env, "cd /tmp && tar -xzf playground-linux.tgz")
        ssh(env, "sudo apt-get install -y -q libsdl2-2.0-0 libsdl2-ttf-2.0-0 libwebkit2gtk-4.1-0 libgtk-3-0t64 libcurl4t64 >/dev/null")
        # The window maximized (ISO_WINDOW_MAXIMIZED, the Linux host's): at
        # its own 1100x720 it sat small in the VM's 1920x1080 desktop, which
        # the crop below kept around it.
        session = "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 ISO_WINDOW_MAXIMIZED=1"
        kill = "for p in $(pgrep -x playground) $(pgrep -x playground_wasm); do kill $p; done"

        def shoot(path):
            oss_shot(env, path)
            # Below GNOME's top bar (its clock) and right of its dock: the
            # maximized window, its title bar included.
            from PIL import Image
            width, height = Image.open(path).size
            crop(path, (67, 32, width, height))

        def launcher(environment, wait, path):
            ssh(env, f"{kill}; sleep 1", check=False)
            assignments = " ".join(f"{k}={shlex.quote(v)}" for k, v in environment.items())
            ssh(env, f"cd /tmp && ({session} {assignments} nohup /tmp/playground-linux/run.sh >/tmp/playground.log 2>&1 &)")
            time.sleep(wait)
            shoot(path)

        shoot_playground(review, "linux", "Ubuntu 26.04 (VM, llvmpipe)", "landscape", launcher, {"open": 8, "run": 50})
        ssh(env, kill, check=False)
    finally:
        release(env)


# --- Windows (built and run on an oss VM with the Swift build layer)

def build_windows():
    """What the Windows VM takes from here: the Playground SDK and the wasm
    SDK's sysroot and static stdlib (platform-independent files; the VM's
    own Swift toolchain gives the frontend and wasm-ld), and this checkout."""
    work = tempfile.mkdtemp(prefix="proof-windows-")
    sdk = bazel_output("//apple/playground_ios_application:playground_sdk", "-c", "opt")
    toolchain = bazel_output("//shared/compiler:toolchain", "-c", "opt")
    environment = dict(os.environ, COPYFILE_DISABLE="1")
    sh(["tar", "--no-xattrs", "-czhf", os.path.join(work, "playground_sdk.tgz"), "-C", os.path.dirname(sdk), os.path.basename(sdk)], env=environment)
    sh(["tar", "--no-xattrs", "-czhf", os.path.join(work, "wasm_data.tgz"), "-C", os.path.join(toolchain, "playground_toolchain"), "data"], env=environment)
    source = os.path.join(work, "playground-src.tgz")
    sh(f"git ls-files -co --exclude-standard -z | tar --no-xattrs -czf {shlex.quote(source)} --null -T -", env=environment)
    return {"sdk": os.path.join(work, "playground_sdk.tgz"), "data": os.path.join(work, "wasm_data.tgz"), "source": source}


# PowerShell, with $bin the module's bazel-bin: the app in C:\proof\playground
# as it would ship: its executables with the DLLs their runfiles name beside
# them, version.txt, and the compiler beside the app: the VM's Swift
# toolchain's frontend, wasm-ld, macro plugin server and plugins with the
# DLLs they load (Windows' toolchain keeps them all in usr\bin), the wasm
# SDK's data and the Playground SDK from the build machine.
def windows_package(version):
    executables = ["playground.exe", "playground_wasm_loader.exe"]
    return "; ".join([
        "$out = \"$bin\\windows\\playground_windows_application\"; $app = 'C:\\proof\\playground'",
        "Remove-Item -Recurse -Force $app -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $app | Out-Null",
        "Copy-Item " + ", ".join(f"\"$out\\{e}\"" for e in executables) + " $app",
        "foreach ($m in " + ", ".join(f"'{e}'" for e in executables) + ") { Get-Content \"$out\\$m.runfiles_manifest\" | "
        "ForEach-Object { $real = $_.Substring($_.IndexOf(' ') + 1); if ($real.EndsWith('.dll')) { Copy-Item $real $app -Force } } }",
        f"Set-Content \"$app\\version.txt\" '{version}'",
        "$tc = (Get-ChildItem \"$env:LOCALAPPDATA\\Programs\\Swift\\Toolchains\" | Select-Object -First 1).FullName + '\\usr\\bin'",
        "New-Item -ItemType Directory -Force \"$app\\playground_toolchain\\usr\\bin\" | Out-Null",
        "Copy-Item \"$tc\\swift-frontend.exe\", \"$tc\\wasm-ld.exe\", \"$tc\\*.dll\" \"$app\\playground_toolchain\\usr\\bin\"",
        "tar -xzf C:\\Users\\runner\\wasm_data.tgz -C \"$app\\playground_toolchain\"",
        "tar -xzf C:\\Users\\runner\\playground_sdk.tgz -C $app",
        # Its projects start from the templates (a VM that ran an earlier
        # build keeps that build's in Application Support). Guarded: on a
        # fresh VM there is none, and a failed Remove-Item, silent or not, as
        # the last command fails the whole step.
        "if (Test-Path \"$env:LOCALAPPDATA\\playground\") { Remove-Item -Recurse -Force \"$env:LOCALAPPDATA\\playground\" }",
    ])


def windows(review, builds):
    env = lease("windows", "--config=swift-6.3.2")
    try:
        for path in builds.values():
            scp(env, path, f"C:/Users/runner/{os.path.basename(path)}")
        ps = lambda command, check=True: ssh(env, command, check)
        # Python for rules_swift's autoconfiguration (the build layer carries
        # it from isomer's tools/ci/oss/windows-swift.ps1; older ones don't).
        ps("if (-not (Test-Path 'C:\\Program Files\\Python312-arm64\\python.exe')) { winget install --id Python.Python.3.12 --silent --scope machine "
           "--accept-package-agreements --accept-source-agreements | Out-Null }; "
           "Remove-Item -Recurse -Force C:\\playground-src -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\\playground-src | Out-Null; "
           "tar -xzf C:\\Users\\runner\\playground-src.tgz -C C:\\playground-src")
        # The checkout mirrored into the workspace Bazel built before (its
        # output base keyed by the path, so builds stay warm): files this
        # commit deleted go too, Bazel's convenience junctions are left alone.
        ps("robocopy C:\\playground-src C:\\playground /MIR /XJ /XD bazel-* /NFL /NDL /NJH /NJS /NP | Out-Null; "
           "if ($LASTEXITCODE -ge 8) { exit 1 } else { exit 0 }")
        # Bazel in MSVC's environment (SwiftPM finds link.exe there) with Git's
        # bash for genrules, and Git's find, cp and od ahead of Windows' find
        # (rules_swift_package_manager runs them). Repository rules see the
        # environment only through --repo_env: Swift's SDKROOT and MSVC's.
        build = os.path.join(tempfile.mkdtemp(prefix="proof-windows-"), "build.cmd")
        repo_env = " ".join("--repo_env=" + name for name in [
            "SDKROOT", "PATH", "INCLUDE", "LIB", "LIBPATH", "UniversalCRTSdkDir", "UCRTVersion",
            "WindowsSdkDir", "WindowsSDKVersion", "VCToolsInstallDir", "VCINSTALLDIR", "VSINSTALLDIR"])
        open(build, "w").write("\r\n".join([
            "@echo off",
            'call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvarsall.bat" arm64 >nul',
            'set "BAZEL_SH=C:\\Program Files\\Git\\bin\\bash.exe"',
            'set "PATH=%PATH:C:\\WINDOWS\\system32;=C:\\Program Files\\Git\\usr\\bin;C:\\WINDOWS\\system32;%"',
            "cd /d C:\\playground",
            # The command, then its arguments.
            "set command=%1",
            "shift",
            # Startup option, then the command, its --repo_env flags (`info`
            # must see the same ones to name the same output base), then the rest.
            f"bazel --output_user_root=C:/b %command% {repo_env} %1 %2 %3 %4 %5 %6 %7 %8 %9",
        ]) + "\r\n")
        scp(env, build, "C:/Users/runner/build.cmd")
        ps("cmd /c C:\\Users\\runner\\build.cmd build -c opt //windows/playground_windows_application:playground "
           "//windows/playground_windows_application:playground_wasm_loader")
        ps("$bin = (cmd /c C:\\Users\\runner\\build.cmd info -c opt bazel-bin 2>$null | Select-Object -Last 1); "
           + windows_package(review.version))

        stop = "Stop-Process -Name playground,playground_wasm_loader -ErrorAction SilentlyContinue"
        scripts = tempfile.mkdtemp(prefix="proof-windows-run-")

        def powershell_string(value):
            # ASCII only, whatever the console's code page: other characters
            # as [char] codes ("Pokédex").
            return '"' + "".join(c if ord(c) < 128 and c not in '"$`' else f"$([char]0x{ord(c):X})" for c in value) + '"'

        # The foreground window's visible bounds (DWM's, without the shadow)
        # within the desktop's work area (the screen less the taskbar), read
        # in the desktop's session as the launch is: what a screenshot is
        # cropped to, so the taskbar's clock and the wallpaper don't count. A
        # window taller than the screen reaches behind the taskbar.
        rect_script = os.path.join(scripts, "rect.ps1")
        open(rect_script, "w").write("\r\n".join([
            'Add-Type @"',
            "using System; using System.Runtime.InteropServices;",
            "public static class ProofWindow {",
            '  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();',
            '  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr w, int a, out Rect r, int s);',
            '  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(int a, int b, ref Rect r, int c);',
            "  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L, T, R, B; }",
            "}",
            '"@',
            "$r = New-Object ProofWindow+Rect",
            "[ProofWindow]::DwmGetWindowAttribute([ProofWindow]::GetForegroundWindow(), 9, [ref]$r, 16) | Out-Null",
            "$w = New-Object ProofWindow+Rect",
            "[ProofWindow]::SystemParametersInfo(0x30, 0, [ref]$w, 0) | Out-Null",
            '"$([Math]::Max($r.L, $w.L)) $([Math]::Max($r.T, $w.T)) $([Math]::Min($r.R, $w.R)) $([Math]::Min($r.B, $w.B))" | Set-Content C:\\proof\\rect.txt',
        ]) + "\r\n")
        scp(env, rect_script, "C:/proof/rect.ps1")

        def window_box():
            ps("if (Test-Path C:\\proof\\rect.txt) { Remove-Item C:\\proof\\rect.txt }; "
               "schtasks /create /f /tn PlaygroundProofRect /tr 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\proof\\rect.ps1' "
               "/sc once /st 23:59 /ru runner /it | Out-Null; schtasks /run /tn PlaygroundProofRect | Out-Null", check=False)
            for _ in range(10):
                time.sleep(1)
                found = ssh(env, "if (Test-Path C:\\proof\\rect.txt) { Get-Content C:\\proof\\rect.txt }", check=False).stdout.split()
                if len(found) == 4:
                    return tuple(map(int, found))
            return None

        def launcher(environment, wait, path):
            # The logged-in desktop session runs it (SSH's has no desktop),
            # through a task: a script of its own, copied in, sets the
            # environment and starts the app.
            script = os.path.join(scripts, "run.ps1")
            open(script, "w").write("\r\n".join(
                ["Set-Location C:\\proof\\playground"]
                + [f"$env:{k} = {powershell_string(v)}" for k, v in environment.items()]
                + ["Start-Process .\\playground.exe"]) + "\r\n")
            scp(env, script, "C:/proof/run.ps1")
            ps(f"{stop}; "
               "schtasks /create /f /tn PlaygroundProof /tr 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\proof\\run.ps1' "
               "/sc once /st 23:59 /ru runner /it | Out-Null; schtasks /run /tn PlaygroundProof | Out-Null")
            time.sleep(wait)
            shoot(path)

        def shoot(path):
            oss_shot(env, path)
            box = window_box()
            if box:
                # Less the window's outer pixel, its border, which blends
                # with the desktop behind it differently from run to run.
                left, top, right, bottom = box
                crop(path, (left + 1, top + 1, right - 1, bottom - 1))

        # The first launch after packaging is scanned by Windows first: longer.
        launcher({}, 30, os.path.join(tempfile.mkdtemp(), "warm.png"))
        shoot_playground(review, "windows", "Windows 11 (VM, ARM64)", "landscape", launcher, {"open": 12, "run": 60})
        ps(stop, check=False)
    finally:
        release(env)


PLATFORMS = {
    "ios": (build_ios, ios), "macos": (build_macos, macos), "android": (build_android, android),
    "web": (None, web), "linux": (build_linux, linux), "windows": (build_windows, windows),
}


def keep(built, folder):
    """--build-to: a platform's build copied into `folder`: playground.<ipa|zip|apk>,
    or playground/ (a web site), for a run elsewhere to take --from.
    (Windows' build is its VM's, and Linux's a package already: neither is
    kept so.)"""
    os.makedirs(folder, exist_ok=True)
    if os.path.isdir(built):
        shutil.copytree(built, os.path.join(folder, "playground"), dirs_exist_ok=True)
    else:
        shutil.copyfile(built, os.path.join(folder, "playground" + os.path.splitext(built)[1]))
    log(f"kept the Playground in {folder}")


def kept(folder):
    """--from: what --build-to kept in `folder`."""
    for entry in sorted(os.listdir(folder)):
        if os.path.splitext(entry)[0] == "playground":
            return os.path.join(folder, entry)
    raise SystemExit(f"proof: no Playground in {folder}")


def main():
    global HERE
    parser = argparse.ArgumentParser()
    parser.add_argument("platforms", nargs="*", default=list(PLATFORMS))
    parser.add_argument("--review", required=True)
    parser.add_argument("--commit", default=sh(["git", "rev-parse", "HEAD"]).stdout.strip())
    parser.add_argument("--version", default=None)
    parser.add_argument("--quick", action="store_true",
                        help="mark the runs a quick proof's, which never stands for a release (the screens are the same)")
    parser.add_argument("--web-toolchain", default=None,
                        help="a staged in-browser compiler (an earlier site's playground/toolchain) for the web Playground")
    parser.add_argument("--linux-packages", default=None,
                        help="the Linux app packaged already (<dir>/playground-linux.tgz): CI's, from a container")
    parser.add_argument("--held", action="append", default=[], metavar="PLATFORM=FILE",
                        help="a lease you hold, its `oss machine lease --exports` output in FILE: used, not released")
    parser.add_argument("--here", action="store_true",
                        help="picture on this machine, nothing leased (CI's proof on GitHub's runners)")
    parser.add_argument("--android-abi", default=None, help="the Android app built for this ABI (x86_64)")
    parser.add_argument("--build-to", default=None, metavar="DIR",
                        help="build the platforms' apps into DIR/<platform>/ and stop, for --from elsewhere")
    parser.add_argument("--from", dest="built", default=None, metavar="DIR",
                        help="picture the apps --build-to kept in DIR/<platform>/ rather than building them")
    args = parser.parse_args()
    HERE = args.here
    held.update(item.split("=", 1) for item in args.held)
    version = args.version or re.search(r'version_name = "([^"]+)"', open(os.path.join(
        ROOT, "android/playground_android_application/BUILD.bazel")).read()).group(1)
    review = Review(args.review, args.commit, version, quick=args.quick)
    log(f"{version} at {args.commit[:10]}: platforms {', '.join(args.platforms)}")

    # This machine's builds first (Bazel runs one command a workspace at a
    # time); Linux's and Windows' are made where they run, so in their threads.
    builds = {}
    for name in args.platforms:
        make, _ = PLATFORMS[name]
        if args.built:
            builds[name] = lambda folder=os.path.join(args.built, name): kept(folder)
        elif name == "web":
            if not args.web_toolchain:
                raise SystemExit("the web needs --web-toolchain (an earlier site's playground/toolchain)")
            builds[name] = lambda toolchain=os.path.abspath(args.web_toolchain): build_web(toolchain)
        elif name == "linux":
            builds[name] = lambda packaged=args.linux_packages: build_linux(packaged)
        elif name == "windows":
            builds[name] = make
        else:
            log(f"building {name}")
            built = make(args.android_abi) if name == "android" else make()
            builds[name] = lambda built=built: built
    if args.build_to:
        for name in args.platforms:
            keep(builds[name](), os.path.join(args.build_to, name))
        return

    def run(name):
        try:
            PLATFORMS[name][1](review, builds[name]())
        except BaseException as error:
            with lock:
                failures.append(f"{name}: {error}")
            log(f"FAILED: {error}")

    threads = [threading.Thread(target=run, args=(name,), name=name) for name in args.platforms]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    log("done" if not failures else f"{len(failures)} missing or failed: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
