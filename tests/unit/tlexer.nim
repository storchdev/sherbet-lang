import diag
import span
import lexer
import std/unittest
import std/streams
import std/os
import std/strutils
import std/sequtils
import std/sugar

suite "diagnostics":
  setup:
    let fixtureDir = currentSourcePath().parentDir / "lexer"
  test "fixtures match":
    for path in os.walkFiles(fixtureDir / "*.sher"):
      var flist = initFileList()
      let file = flist.addFile(path)
      var sink = initDiagnosticSink()

      let lexR = file.scan(sink)
      var mutpath = path
      mutpath.removeSuffix("sher")
      let expected = readFile(mutpath & "expected")

      if path.startsWith("err"):
        let tmpBuf = newStringStream()
        sink.emitDiagnostics(flist, tmpBuf)
        tmpBuf.setPosition(0)
        check expected == tmpBuf.readAll()
      else:
        let tmpBuf = newStringStream()
        tmpBuf.write(lexR.tokens.map((t) => $t).join(" "))
        tmpBuf.setPosition(0)
        check expected == tmpBuf.readAll()
