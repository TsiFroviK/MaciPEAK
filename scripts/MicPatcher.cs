using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class MicPatcher {
    private const string StockHash = "794c5002128f9c9ba7345903f8266f63734f536ac93be1088b9c34210665c8c1";

    public static int Main(string[] args) {
        if (args.Length != 2 || File.Exists(args[1])) throw new ArgumentException("Expected stock PhotonVoice.dll and an unused staged output path");
        string sha;
        using (var file = File.OpenRead(args[0]))
        using (var digest = SHA256.Create()) sha = BitConverter.ToString(digest.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
        if (sha != StockHash) throw new InvalidDataException("Unsupported PEAK PhotonVoice.dll (SHA-256 " + sha + ")");
        using (var module = ModuleDefinition.ReadModule(args[0])) {
            Patch(module);
            module.Write(args[1], new WriterParameters { DeterministicMvid = true });
        }
        using (var check = ModuleDefinition.ReadModule(args[1])) {
            var rec = check.GetType("Photon.Voice.Unity.Recorder");
            foreach (string method in new[] { "peak_mic_may_start", "peak_mic_take_grant" }) {
                if (rec.Methods.Single(m => m.Name == method).PInvokeInfo.Module.Name != "PeakMicConsent") throw new InvalidDataException("Mic import verification failed");
            }
        }
        return 0;
    }

    internal static void Patch(ModuleDefinition module) {
        var recorder = module.GetType("Photon.Voice.Unity.Recorder");
        if (recorder == null || recorder.Fields.Any(f => f.Name == "peakWaitingForMicrophone")) throw new InvalidDataException("Expected unmodified Photon recorder");
        var sourceType = recorder.NestedTypes.Single(t => t.Name == "InputSourceType");
        if ((int)sourceType.Fields.Single(f => f.Name == "Microphone").Constant != 0) throw new InvalidDataException("Unexpected Photon input source values");
        var waiting = new FieldDefinition("peakWaitingForMicrophone", FieldAttributes.Private | FieldAttributes.NotSerialized, module.TypeSystem.Int32);
        recorder.Fields.Add(waiting);
        var native = new ModuleReference("PeakMicConsent");
        module.ModuleReferences.Add(native);
        var address = new ByReferenceType(module.TypeSystem.Int32);
        var mayStart = Import(recorder, native, "peak_mic_may_start", module.TypeSystem.Int32, address);
        var takeGrant = Import(recorder, native, "peak_mic_take_grant", address);
        var start = recorder.Methods.Single(m => m.Name == "StartRecording");
        var stop = recorder.Methods.Single(m => m.Name == "StopRecording");
        var update = recorder.Methods.Single(m => m.Name == "Update");
        var restart = recorder.Methods.Single(m => m.Name == "RestartRecording");
        var input = recorder.Methods.Single(m => m.Name == "get_SourceType");
        // This log follows the initial StopRecording and the null-connection return.
        // The insertion is stack-neutral and precedes any recording-source allocation.
        var log = start.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && (string)i.Operand == "Starting recording");
        var anchor = log;
        while (anchor != null && !Calls(anchor, "Log")) anchor = anchor.Next;
        if (anchor == null || !start.Body.Instructions.SkipWhile(i => i != anchor).Any(i => Calls(i, "CreateLocalVoiceAudioAndSource"))) throw new InvalidDataException("Unexpected start recording control flow");
        anchor = anchor.Next;
        Insert(start, anchor,
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, input),
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldflda, waiting),
            Instruction.Create(OpCodes.Call, mayStart), Instruction.Create(OpCodes.Brtrue, anchor), Instruction.Create(OpCodes.Ret));
        Insert(stop, stop.Body.Instructions[0], Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldc_I4_0), Instruction.Create(OpCodes.Stfld, waiting));
        // Scheduling a retry here uses Photon's existing main-thread pending flag, which
        // coalesces simultaneous device-change and permission notifications.
        var flag = update.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldflda && ((FieldReference)i.Operand).Name == "restartRecordingPending");
        anchor = flag.Previous;
        if (anchor.OpCode != OpCodes.Ldarg_0) throw new InvalidDataException("Unexpected recorder update control flow");
        Insert(update, anchor,
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, waiting), Instruction.Create(OpCodes.Brfalse, anchor),
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldflda, waiting), Instruction.Create(OpCodes.Call, takeGrant), Instruction.Create(OpCodes.Brfalse, anchor),
            Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, restart), Instruction.Create(OpCodes.Pop));
    }

    private static bool Calls(Instruction instruction, string name) {
        var target = instruction.Operand as MethodReference;
        return target != null && target.Name == name && (instruction.OpCode == OpCodes.Call || instruction.OpCode == OpCodes.Callvirt);
    }

    private static MethodDefinition Import(TypeDefinition owner, ModuleReference library, string entry, params TypeReference[] parameters) {
        var method = new MethodDefinition(entry, MethodAttributes.Private | MethodAttributes.Static | MethodAttributes.HideBySig | MethodAttributes.PInvokeImpl, owner.Module.TypeSystem.Int32);
        method.PInvokeInfo = new PInvokeInfo(PInvokeAttributes.CallConvCdecl | PInvokeAttributes.NoMangle, entry, library);
        method.ImplAttributes = MethodImplAttributes.PreserveSig;
        foreach (var argument in parameters) method.Parameters.Add(new ParameterDefinition(argument));
        owner.Methods.Add(method);
        return method;
    }

    private static void Insert(MethodDefinition method, Instruction anchor, params Instruction[] before) {
        if (method.Body.ExceptionHandlers.Count != 0) throw new InvalidDataException("Unexpected recorder exception region");
        foreach (var instruction in method.Body.Instructions) {
            if (instruction.Operand == anchor) instruction.Operand = before[0];
            var targets = instruction.Operand as Instruction[];
            if (targets != null) for (int i = 0; i < targets.Length; ++i) if (targets[i] == anchor) targets[i] = before[0];
        }
        var il = method.Body.GetILProcessor();
        foreach (var instruction in before) il.InsertBefore(anchor, instruction);
    }
}
