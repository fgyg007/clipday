using ClipDay.Sync;
var pair = new Pair(1, "c1416f42-de6e-43e0-97f0-122e9016a926", Convert.ToBase64String(Enumerable.Range(0, 32).Select(n => (byte)n).ToArray()));
var sync = new FolderSync(args[1], Path.Combine(args[1], "csharp-local"), pair, "Windows interop");
if (args[0] == "write") { sync.Enqueue("Windows → Android 你好 🪟\r\nline two"); sync.Poll(); Console.WriteLine("PASS: Windows fixture published"); }
else {
    var batch = sync.Poll();
    if (!batch.Records.Any(r => r.Text == "Android → desktop 你好 📱\r\nline two" || r.Text == "Android share fixture 你好 📱")) throw new Exception("Android interop failed");
    Console.WriteLine("PASS: Android record decrypted by Windows .NET core");
}
