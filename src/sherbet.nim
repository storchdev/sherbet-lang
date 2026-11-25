import std/os
import std/strutils
import span, diag, lexer

let argc = paramCount()

if argc == 0:
  echo "please provide an input file for the driver"
  quit(1)

let path = paramStr(1)

if not fileExists(path):
  echo "file doesn't exist"
  quit(1)

# let content = readFile(path)

var fileList = initFileList()
let file = fileList.addFile(path)
var sink = initDiagnosticSink()

let lexR = file.scan(sink)
echo "errors:"
sink.emitDiagnostics(fileList)
echo "lex result:"
echo lexR.tokens.dump()
