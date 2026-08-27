// vmingest — control/inspection CLI for voice-memos-ingest.
//
// Subcommands (built out across the implementation plan):
//   transcribe <file>   print a transcript for one audio file (debugging)
//   status              read the app's status file and print a summary
//   run-once            headless one-shot of the full pipeline
//   config              print resolved configuration

import Foundation
import VMIngestCore

func usage() -> Never {
    let text = """
    usage: vmingest <command> [args]

    commands:
      run-once                  run the full pipeline once, headless
      status                    print whether the app is running and recent activity
      config                    print resolved configuration
      transcribe <audio-file>   print the on-device transcript for one file
      tsrp <audio-file>         print Apple's embedded transcript, if any (debug)
      list                      list all recordings from the index DB (debug)
    """
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "transcribe":
    guard args.count == 2 else {
        FileHandle.standardError.write("usage: vmingest transcribe <audio-file>\n".data(using: .utf8)!)
        exit(2)
    }
    let url = URL(fileURLWithPath: args[1])
    do {
        let text = try await Transcriber.transcribe(url: url)
        print(text)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "status":
    do {
        let config = try Config.load()
        guard let status = Status.load(path: config.statusPath) else {
            print("no status file at \(config.statusPath) — is the app running?")
            exit(0)
        }
        print("running:        \(status.running)")
        print("watching since: \(status.watchingSince ?? "—")")
        print("last run:       \(status.lastRunAt ?? "—")")
        print("emitted total:  \(status.totalEmitted)")
        print("last memo:      \(status.lastMemoTitle ?? "—") (\(status.lastMemoAt ?? "—"))")
        print("last error:     \(status.lastError ?? "none")")
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "run-once":
    do {
        let config = try Config.load()
        let result = try await Pipeline.runOnce(config: config)
        if result.didBootstrap {
            print("bootstrap: recorded \(result.bootstrapped) existing memos as seen, emitted 0")
        } else {
            print("emitted \(result.emitted) new transcript(s)")
        }
        for e in result.errors { FileHandle.standardError.write("error: \(e)\n".data(using: .utf8)!) }
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "config":
    do {
        let config = try Config.load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        print("config file: \(Config.configPath())")
        print(String(data: data, encoding: .utf8) ?? "{}")
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "list":
    do {
        let config = try Config.load()
        let recordings = try RecordingsReader.readAll(recordingsDir: config.recordingsDir)
        let fmt = ISO8601DateFormatter()
        for r in recordings {
            print("\(r.id)  \(fmt.string(from: r.recordedAt))  \(String(format: "%6.1fs", r.duration))  \(r.title)")
        }
        FileHandle.standardError.write("\(recordings.count) recordings\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "tsrp":
    guard args.count == 2 else {
        FileHandle.standardError.write("usage: vmingest tsrp <audio-file>\n".data(using: .utf8)!)
        exit(2)
    }
    if let text = TsrpExtractor.extract(fromFileAt: args[1]) {
        print(text)
    } else {
        FileHandle.standardError.write("no tsrp atom (or unparseable)\n".data(using: .utf8)!)
        exit(1)
    }

default:
    FileHandle.standardError.write("unknown command: \(command)\n".data(using: .utf8)!)
    usage()
}
