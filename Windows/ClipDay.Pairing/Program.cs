using System.Text.Json;
using ClipDay.Sync;

// Structured private stdin/stdout only. No credentials in argv, files, stderr, or diagnostic logs.
using var cancelled = new CancellationTokenSource();
void Emit(PairEvent ev) { Console.WriteLine(JsonSerializer.Serialize(ev, PairJson.Default.PairEvent)); Console.Out.Flush(); }
try
{
    var line = Console.ReadLine();
    if (line == null || line.Length > 16384) throw new InvalidDataException();
    var input = JsonSerializer.Deserialize(line, PairJson.Default.PairCommand) ?? throw new InvalidDataException();
    _ = Task.Run(() => { Console.ReadLine(); cancelled.Cancel(); }); // Closing stdin or sending a line cancels cleanly.
    if (input.Mode == "host" && input.Pair != null) await ShortPairing.HostAsync(input.Folder, input.Pair, Emit, cancelled.Token);
    else if (input.Mode == "join" && input.Code != null) Emit(new("joined", Pair: await ShortPairing.JoinAsync(input.Folder, input.Code, cancelled.Token)));
    else throw new InvalidDataException();
}
catch (OperationCanceledException) { Emit(new("cancelled", Message: "配对已取消")); }
catch (Exception e) { Emit(new("error", Message: e is IOException or InvalidDataException ? e.Message : "配对失败，请检查 NAS 连接后重试。")); }
