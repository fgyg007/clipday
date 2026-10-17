#!/usr/bin/env python3
"""Cross-language pairing and records using public fixtures in an isolated directory."""
import argparse, base64, json, os, pathlib, subprocess, tempfile

repo = pathlib.Path(__file__).resolve().parent.parent
tools = pathlib.Path(os.environ.get('CLIPDAY_ANDROID_TOOLS', pathlib.Path.home() / '.local/share/clipday-android'))
env = dict(os.environ, JAVA_HOME=str(tools / 'jdk/Contents/Home'), ANDROID_HOME=str(tools / 'sdk'))
parser = argparse.ArgumentParser()
parser.add_argument('--root', type=pathlib.Path)
parser.add_argument('--smb-config', type=pathlib.Path)
args = parser.parse_args()
temporary = tempfile.TemporaryDirectory(prefix='clipday-android-interop-') if not args.root else None
root = (args.root or pathlib.Path(temporary.name)).resolve()
pair = dict(v=1, space='c1416f42-de6e-43e0-97f0-122e9016a926', key=base64.b64encode(bytes(range(32))).decode())
dotnet = os.environ.get('CLIPDAY_DOTNET', str(pathlib.Path.home() / '.local/share/clipday-dotnet/dotnet'))
def run(command, **kwargs):
    return subprocess.run([str(v) for v in command], cwd=repo, env=env, check=True, timeout=90, **kwargs)
if not (root / 'ClipDaySync').exists():
    run([repo/'build/android-interop', 'write', root])
    run([dotnet, 'run', '--project', 'Android/interop', '-c', 'Release', '--', 'write', root])
classpath = subprocess.check_output([str(tools/'gradle-8.11.1/bin/gradle'), '-q', ':core:interopClasspath'], cwd=repo/'Android', env=env, text=True).strip().splitlines()[-1]
client = [tools/'jdk/Contents/Home/bin/java', '-cp', classpath, 'io.jlmac.clipday.core.Interop']
host = subprocess.Popen([str(repo/'build/pairing-mac/ClipDayPair')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    host.stdin.write(json.dumps(dict(mode='host', folder=str(root), pair=pair)) + '\n'); host.stdin.flush()
    offer = json.loads(host.stdout.readline()); assert offer['type'] == 'offer'
    pin = offer['code']
    if not args.smb_config:
        wrong = '000001' if pin == '000000' else '000000'
        run(client + ['badjoin', root], input=wrong + '\n', text=True)
        offer = json.loads(host.stdout.readline()); assert offer['type'] == 'offer'
    run(client + (['smb', args.smb_config.resolve()] if args.smb_config else ['join', root]), input=pin + '\n', text=True)
    run([repo/'build/android-interop', 'read', root])
    run([dotnet, 'run', '--project', 'Android/interop', '-c', 'Release', '--', 'read', root])
finally:
    if host.poll() is None:
        host.stdin.write('\n'); host.stdin.flush()
        try: host.wait(timeout=5)
        except subprocess.TimeoutExpired: host.terminate(); host.wait(timeout=5)
    if temporary: temporary.cleanup()
