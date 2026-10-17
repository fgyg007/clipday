#!/usr/bin/env python3
"""Use only the dedicated clipday-qa emulator and temporary clipday-android-qa Samba container."""
import base64, json, pathlib, subprocess, time
repo = pathlib.Path(__file__).resolve().parent.parent
sdk = pathlib.Path.home()/'.local/share/clipday-android/sdk'
adb = [str(sdk/'platform-tools/adb'), '-s', 'emulator-5580']
def run(command, **kwargs):
    return subprocess.run([str(v) for v in command], cwd=repo, check=True, timeout=90, **kwargs)
deadline = time.monotonic() + 120
while time.monotonic() < deadline:
    result = subprocess.run(adb + ['shell','getprop','sys.boot_completed'], capture_output=True, text=True)
    if result.stdout.strip() == '1': break
    time.sleep(2)
else: raise RuntimeError('Dedicated QA emulator did not boot')
for apk in ('Android/app/build/outputs/apk/debug/app-debug.apk', 'Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'):
    run(adb + ['install','-r',str(repo/apk)], capture_output=True)
run(adb + ['shell','pm','clear','io.jlmac.clipday.android'], capture_output=True)
run(adb + ['shell','input','keyevent','82'], capture_output=True)
run(adb + ['reverse','tcp:1445','tcp:1445'], capture_output=True)
def test(method, pin=None):
    command = adb + ['shell','am','instrument','-w','-r','-e','host','127.0.0.1','-e','class','io.jlmac.clipday.android.JourneyTest#'+method]
    if pin: command += ['-e','pin',pin]
    command += ['io.jlmac.clipday.android.test/androidx.test.runner.AndroidJUnitRunner']
    output = run(command, capture_output=True, text=True).stdout
    if 'OK (1 test)' not in output: print(output); raise RuntimeError('Android journey failed: '+method)
    print('PASS: '+method, flush=True)
root = repo/'build/android-qa'
pair = dict(v=1,space='c1416f42-de6e-43e0-97f0-122e9016a926',key=base64.b64encode(bytes(range(32))).decode())
host = subprocess.Popen([str(repo/'build/pairing-mac/ClipDayPair')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    host.stdin.write(json.dumps(dict(mode='host', folder=str(root), pair=pair))+'\n'); host.stdin.flush()
    offer = json.loads(host.stdout.readline()); assert offer['type']=='offer'
    test('testPairShareAndCopy', offer['code'])
finally:
    if host.poll() is None:
        host.stdin.write('\n'); host.stdin.flush()
        try: host.wait(timeout=5)
        except subprocess.TimeoutExpired: host.terminate(); host.wait(timeout=5)
run(['docker','pause','clipday-android-qa'],capture_output=True)
try: test('testOfflineKeepsPairAndQueue')
finally: run(['docker','unpause','clipday-android-qa'],capture_output=True)
test('testReconnectAfterProcessRestart')
run([repo/'build/android-interop','read',root])
run([pathlib.Path.home()/'.local/share/clipday-dotnet/dotnet','run','--project','Android/interop','-c','Release','--','read',root])
run(adb+['shell','am','start','-n','io.jlmac.clipday.android/.MainActivity'],capture_output=True)
test('testLayoutPreview')
run(adb+['pull','/sdcard/Android/data/io.jlmac.clipday.android/files/layout.png',repo/'build/android-layout.png'],capture_output=True)
print('Native view layout saved: build/android-layout.png (ATD disables the system compositor)')
