import Foundation
actor Counter {
 var starts: [String] = []; var live = 0; var peak = 0
 func translate(_ text: String, target: String, provider: SubtitleTranslationProvider) async throws -> CaptionTranslation {
  starts.append(text); live += 1; peak = max(peak, live)
  // Intentionally ignores cancellation to model a slow adapter.
  await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 0.65) { c.resume() } }
  live -= 1
  return CaptionTranslation(targetLanguage: target, text: "译:"+text, state: .translated, provider: "fake")
 }
}
func seg(_ text: String, final: Bool = false, end: Double = 1) -> LiveCaptionSegment { LiveCaptionSegment(id: "server", start: 0, end: end, text: text, final: final) }
func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS \(name)") }
@main struct Main {
 static func main() async throws {
  var options = SubtitleOptions(); options.translation = true
  var b = CaptionDraftBuffer(connectionID: "a", source: .system, options: options)
  let first = b.receive([seg("draft")])[0]
  check(b.receive([seg("draft")]).isEmpty, "unchanged snapshot creates no new request")
  let timing = b.receive([seg("draft", end: 2)])[0]
  check(timing.revision == first.revision + 1, "timing-only revision schedules translation")
  let final = b.receive([seg("draft", final: true, end: 2)])[0]
  check(final.revision == timing.revision + 1, "final-only revision schedules translation")
  check(!b.apply(CaptionTranslation(targetLanguage: "zh-Hans", text: "old", state: .translated, provider: "fake"), id: first.id, revision: first.revision), "reject late old revision")
  check(!b.apply(CaptionTranslation(targetLanguage: "en", text: "wrong", state: .translated, provider: "fake"), id: final.id, revision: final.revision), "reject wrong target")
  options.transcription = false
  var target = CaptionDraftBuffer(connectionID: "b", source: .microphone, options: options)
  let raw = target.receive([seg("中文", final: true)])[0]
  _ = target.apply(CaptionTranslation(targetLanguage: "zh-Hans", state: .sameLanguage, provider: "fake"), id: raw.id, revision: raw.revision)
  check(target.segments[0].plainText == "中文" && target.segments[0].text.isEmpty, "translation-only same-language stores target once")
  let c = Counter(); let p = ScheduleProbe(options: options, translator: { try await c.translate($0, target:$1, provider:$2) })
  await p.ingest([seg("v1")]); try await Task.sleep(for: .milliseconds(80)); await p.ingest([seg("v2", final:true)])
  await p.wait()
  check(await c.starts == ["v2"], "debounce cancelled before request; final sends immediately")
  let c2 = Counter(); let p2 = ScheduleProbe(options: options, translator: { try await c2.translate($0, target:$1, provider:$2) })
  await p2.ingest([seg("old", final:true)]); try await Task.sleep(for: .milliseconds(80)); await p2.ingest([seg("new", final:true)])
  await p2.wait(); check(await c2.peak == 2, "same segment requests overlap when adapter ignores cancellation")
  check(await p2.results == ["译:new"], "cancelled adapter result rejected after await")
  let c3 = Counter(); let p3 = ScheduleProbe(options: options, translator: { try await c3.translate($0, target:$1, provider:$2) })
  await p3.ingest((0..<12).map { seg("line-\($0)", final:true) }); await p3.wait()
  check(await c3.peak == 12, "different finalized segments have no shared concurrency limit")
  let root = URL(fileURLWithPath: CommandLine.arguments[1]); let store = LiveCaptionStore(directory: root)
  let id = UUID().uuidString.lowercased()
  let conn = CaptionConnection(id:"a", source:.system, start:0, end:2, complete:true, state:"completed")
  var pending = seg("pending", final:true); pending.id="a:0"; pending.connectionID="a"; pending.translation=CaptionTranslation(targetLanguage:"zh-Hans",state:.pending,provider:"fake")
  let archive = try await store.updateConnection(id, mode:.separate, connection:conn, segments:[pending])
  check(archive.complete && !archive.partial, "store complete does not require translation to leave pending")
  let other = CaptionConnection(id:"b", source:.microphone, start:0, end:2, complete:true, state:"completed")
  var s=seg("mic",final:true); s.id="b:0"; s.connectionID="b"; s.source = .microphone
  let both = try await store.updateConnection(id, mode:.separate, connection:other, segments:[s])
  check(both.segments.count==2, "store preserves other source connection")
  b.discardOriginals(); check(!b.apply(CaptionTranslation(targetLanguage:"zh-Hans",text:"late",state:.translated,provider:"fake"),id:final.id,revision:final.revision), "after discard rejects late results")
  print("All 13 offline checks passed")
 }
}
