"""Actual launcher/dashboard attach checks on disposable account fixtures."""
import json
import os
import shlex
import uuid
from container_fixture import ROOT
from terminal_support import Terminal
from workflow_support import WorkflowFailure


def arm_markers(fixture, index):
    challenge = uuid.uuid4().hex
    for state in fixture.states:
        for name in ("hook-dispatched", "statusline-dispatched"):
            (state / name).unlink(missing_ok=True)
    state = fixture.spec["containerConfigMount"]
    for name, marker in (("hook", "hook-dispatched"), ("statusline", "statusline-dispatched")):
        (fixture.states[index] / ("local-config/" + name + ".sh")).write_text(
            "#!/bin/sh\nprintf %s " + shlex.quote(challenge) + " > " + shlex.quote(state + "/" + marker) +
            "\nprintf " + name + "-ok\n")
    return challenge


def markers_match(fixture, index, challenge, statusline=True):
    names = ("hook-dispatched", "statusline-dispatched") if statusline else ("hook-dispatched",)
    for other, state in enumerate(fixture.states):
        for name in names:
            marker = state / name
            if other != index and marker.exists():
                raise WorkflowFailure("wrong_account_dispatch")
            if other == index and (not marker.is_file() or marker.read_text() != challenge):
                return False
    return True


def build_tui(fixture):
    binary = fixture.root / "bin" / ("claude-docker-tui.exe" if os.name == "nt" else "claude-docker-tui")
    binary.parent.mkdir(exist_ok=True)
    fixture.run(["go", "-C", str(ROOT / "tui"), "build", "-o", str(binary), "."], timeout=180)
    return binary


def drive_tui(terminal, index, attached):
    terminal.expect(b"(2/2 running)")
    terminal.clear()
    # ANSI arrows are distinct key events even when one pipe read coalesces
    # multiple bytes; adjacent printable letters can become a single paste.
    terminal.send(b"\x1b[B" * index + b"\r")
    terminal.wait_for(attached)
    terminal.clear()
    terminal.send(b"/exit\r")
    terminal.expect(b"[Enter] Attach")
    if terminal.contains(b"Attach failed:"):
        raise WorkflowFailure("tui_runtime_exit_failed")
    # A new help response proves the event loop owns input again, even if an
    # old dashboard frame was still in a pipe when the runtime exited.
    terminal.clear()
    terminal.send(b"?")
    terminal.expect(b"Keybindings")
    terminal.send(b"q")
    terminal.wait_exit()


def runtime_processes(fixture, index):
    script = r'''
import json,os,pathlib,shutil,sys
target=os.path.realpath(shutil.which(sys.argv[1]))
found=[]
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdigit() or int(proc.name)==os.getpid(): continue
    try:
        args=(proc/'cmdline').read_bytes().split(b'\0')
        executable=os.path.realpath(proc/'exe')
        if executable==target or any(arg and not arg.startswith(b'-') and
                os.path.realpath(os.fsdecode(arg))==target for arg in args[:2]):
            found.append(proc.name+':'+(proc/'stat').read_text().rsplit(')',1)[1].split()[19])
    except (OSError,ValueError): pass
print(json.dumps(sorted(found)))
'''
    return set(json.loads(fixture.execute(index, "python3", "-c", script, fixture.spec["binary"], timeout=3)))


def terminal_attach(fixture, index, entry_point, binary=None):
    challenge = arm_markers(fixture, index) if fixture.runtime == "claude" else None
    before = [runtime_processes(fixture, i) for i in range(2)]
    if any(before):
        raise WorkflowFailure("terminal_account_already_busy")
    if entry_point == "tui":
        if not binary or binary.parent.parent.resolve() != fixture.root.resolve():
            raise WorkflowFailure("tui_fixture_binary_required")
        command = [str(binary)]
    else:
        prefix = (["pwsh", "-NoProfile", "-File", str(fixture.root / "scripts/claude-docker.ps1")]
                  if fixture.language == "powershell" else ["bash", str(fixture.root / "scripts/claude-docker")])
        command = prefix + [fixture.runtime, fixture.services[index]]
    # State discovery in the Go dashboard uses HOME as well as the fixture's
    # project root. Both must point at test-owned data. Explicit DOCKER_* stays.
    env = dict(fixture.host_env, HOME=str(fixture.home), USERPROFILE=str(fixture.home))
    try:
        with Terminal(command, fixture.root, env) as terminal:
            trusted = False

            def attached():
                nonlocal trusted
                if not trusted and (terminal.contains(b"Yes, I trust") or
                                    terminal.contains(b"trust this") and terminal.contains(b"Yes, proceed")):
                    terminal.send(b"\r")
                    trusted = True
                if runtime_processes(fixture, 1 - index) - before[1 - index]:
                    raise WorkflowFailure("wrong_account_attach")
                if not runtime_processes(fixture, index) - before[index]:
                    return False
                if challenge:
                    return markers_match(fixture, index, challenge)
                return terminal.contains(fixture.spec["binary"].encode())

            if entry_point == "tui":
                drive_tui(terminal, index, attached)
            else:
                terminal.wait_for(attached)
                terminal.send(b"/exit\r")
                terminal.wait_exit()
        if any(runtime_processes(fixture, i) for i in range(2)):
            raise WorkflowFailure("terminal_runtime_left_running")
        return {"entry_point": entry_point, "terminal": "ConPTY" if os.name == "nt" else "POSIX PTY",
                "selected_account_verified": True, "runtime": fixture.runtime,
                "dashboard_control_returned": entry_point == "tui", "model_tasks_submitted": 0,
                "hook_dispatch": "passed" if challenge else "not_applicable",
                "statusline_dispatch": "passed" if challenge else "not_applicable"}
    finally:
        # Host process cleanup alone cannot kill a detached docker exec child.
        # Stop both fixture services, including a wrongly attached sibling.
        fixture.run(fixture.cmd + ["stop"] + fixture.services, timeout=60)
        fixture.up()
