import Foundation
import Testing
@testable import StillCore

private actor Recorder {
    var updates: [CompletionUpdate] = []
    func append(_ value: CompletionUpdate) { updates.append(value) }
    var last: CompletionUpdate? { updates.last }
}

@Test(.timeLimit(.minutes(1))) func pacedStreamDeliversFirstTextAndFlushesPendingUpdates() async {
    let (stream, output) = AsyncStream.makeStream(of: CompletionUpdate.self)
    let batcher = CompletionBatcher(interval: .milliseconds(250), output: output)
    var updates = stream.makeAsyncIterator()

    await batcher.append(CompletionUpdate(reasoning: "Thinking", isThinking: true))
    #expect(await updates.next()?.reasoning == "Thinking")
    await batcher.append(CompletionUpdate(reasoning: "Thinking longer", isThinking: true))

    // First answer text bypasses the reasoning timer and includes the latest reasoning.
    await batcher.append(CompletionUpdate(text: "Hello", reasoning: "Thinking longer"))
    let firstAnswer = await updates.next()
    #expect(firstAnswer?.text == "Hello")
    #expect(firstAnswer?.reasoning == "Thinking longer")

    await batcher.append(CompletionUpdate(text: "Hello "))
    await batcher.append(CompletionUpdate(text: "Hello world"))
    #expect(await updates.next()?.text == "Hello world")

    await batcher.append(CompletionUpdate(text: "Hello world!", finishReason: "length"))
    await batcher.finish()
    #expect(await updates.next()?.finishReason == "length")
    #expect(await updates.next() == nil)
}

@Test func httpBackendStreamsErrorsAndCancels() async throws {
    let fixture = #"""
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  mode=body['model']
  if mode=='error':
   self.send_response(400);self.end_headers();self.wfile.write(b'{"error":{"message":"Context full"}}');return
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  chunks=['Hello ', 'world']
  if mode in ('reasoning','alias'):
   assert body['messages'][0]['reasoning_content']=='Earlier thought'
   assert body['max_completion_tokens']==2048
   assert 'chat_template_kwargs' not in body
   key='reasoning_content' if mode=='reasoning' else 'reasoning'
   self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{key:'Compare '}}]})+'\n\n').encode())
   self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{key:'options.'}}]})+'\n\n').encode())
  if mode=='literal': chunks=['A literal <|example|> stays text.']
  if mode=='reasoning_only':
   self.wfile.write(b'data: {"choices":[{"delta":{"reasoning_content":"An unfinished thought"}}]}\n\n')
   chunks=[]
  if mode=='slow': chunks=['a']*100
  try:
   for text in chunks:
    event={'choices':[{'delta':{'content':text}}]}
    self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode());self.wfile.flush()
    if mode=='slow': time.sleep(.05)
   if mode!='truncated': self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),H)
print(server.server_port,flush=True)
server.serve_forever()
"""#
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", fixture]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { process.terminate() }
    var portData = Data()
    while portData.count < 10 {
        let byte = try #require(try pipe.fileHandleForReading.read(upToCount: 1))
        guard !byte.isEmpty, byte.first != 10 else { break }
        portData.append(byte)
    }
    let port = try #require(String(data: portData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
    let base = try #require(URL(string: "http://127.0.0.1:\(port)/v1"))
    let messages = [RequestMessage(role: "user", content: "Hello")]
    let plain = Recorder()
    try await OpenAICompatibleBackend(baseURL: base, model: "normal").reply(to: messages) { await plain.append($0) }
    #expect(await plain.last?.text == "Hello world")
    for mode in ["reasoning", "alias"] {
        let recorder = Recorder()
        let history = [RequestMessage(role: "assistant", content: "Earlier answer", reasoningContent: "Earlier thought"), RequestMessage(role: "user", content: "Continue")]
        try await OpenAICompatibleBackend(baseURL: base, model: mode).reply(to: history) { await recorder.append($0) }
        #expect(await recorder.last?.text == "Hello world")
        #expect(await recorder.last?.reasoning == "Compare options.")
    }
    let literal = Recorder()
    try await OpenAICompatibleBackend(baseURL: base, model: "literal").reply(to: messages) { await literal.append($0) }
    #expect(await literal.last?.text == "A literal <|example|> stays text.")
    let unfinished = Recorder()
    do {
        try await OpenAICompatibleBackend(baseURL: base, model: "reasoning_only").reply(to: messages) { await unfinished.append($0) }
        Issue.record("Expected a no-answer error")
    } catch { #expect(error.localizedDescription.contains("without producing an answer")) }
    #expect(await unfinished.last?.reasoning == "An unfinished thought")
    do {
        try await OpenAICompatibleBackend(baseURL: base, model: "error").reply(to: messages) { _ in }
        Issue.record("Expected a readable backend error")
    } catch { #expect(error.localizedDescription == "Context full") }
    do {
        try await OpenAICompatibleBackend(baseURL: base, model: "truncated").reply(to: messages) { _ in }
        Issue.record("An interrupted stream must not be marked complete")
    } catch { #expect(error.localizedDescription.contains("before the reply finished")) }
    let task = Task { try await OpenAICompatibleBackend(baseURL: base, model: "slow").reply(to: messages) { _ in } }
    try await Task.sleep(for: .milliseconds(200))
    let start = ContinuousClock.now
    task.cancel()
    do { try await task.value; Issue.record("Expected cancellation") } catch {}
    #expect(ContinuousClock.now - start < .seconds(2))
}
