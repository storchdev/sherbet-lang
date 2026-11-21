import std/strformat
import std/strutils
import std/sequtils
import std/sugar
import std/streams
import std/os
import span

type DiagnosticSeverity* = enum
  dsError = "error"
  dsWarning = "warning"
  dsNote = "note"

type Diagnostic* = ref object
  severity*: DiagnosticSeverity
  message*: string
  span*: Span
  notes*: seq[Diagnostic] # each must have severity dsNote, empty notes
  hints*: seq[string]

type DiagnosticSink* = ref object
  diagnostics*: seq[Diagnostic]

proc initDiagnosticSink*(): DiagnosticSink =
  result = DiagnosticSink(diagnostics: @[])

proc getDiagnosticHeader(self: FileList, diag: Diagnostic): string =
  let augFile = self.files[diag.span.fileIndex]
  let (row, startCol) = self.getSpanPos(diag.span)
  result =
    fmt"{extractFilename(augFile.name)}:{row+1}:{startCol+1}: {$diag.severity}: {diag.message}"

proc emitDiagnostic[T](self: Diagnostic, fileList: FileList, output: T = stderr) =
  let sherFile = fileList.files[self.span.fileIndex]
  let (row, startCol) = fileList.getSpanPos(self.span)

  var line: string
  if row == len(sherFile.lineOffsets) - 1:
    line = sherFile.content[sherFile.lineOffsets[row] ..^ 1]
  else:
    line = sherFile.content[
      sherFile.lineOffsets[row] ..< (sherFile.lineOffsets[row + 1] - 1)
    ]
  line = line.strip(chars = {'\r'})

  var numCarets = self.span.stop - self.span.start
  if startCol + numCarets > len(line):
    numCarets = len(line) - startCol
  if (numCarets == 0):
    numCarets = 1

  output.writeLine(fileList.getDiagnosticHeader(self))
  output.writeLine("    " & line)
  # doesnt handle tabs correctly in the source code
  output.writeLine("    " & " ".repeat(startCol) & "^".repeat(numCarets))

proc emitDiagnostics*[T](self: DiagnosticSink, fileList: FileList, output: T = stderr) =
  for diag in self.diagnostics:
    diag.emitDiagnostic(fileList, output)

    for note in diag.notes:
      note.emitDiagnostic(fileList, output)

    for hint in diag.hints:
      output.writeLine("    hint: " & hint)

proc hasErrors*(self: DiagnosticSink): bool =
  result = self.diagnostics.any(d => d.severity == dsError)

proc reportError*(
    self: DiagnosticSink,
    span: Span,
    message: string,
    notes: seq[Diagnostic],
    hints: seq[string],
) =
  self.diagnostics.add(
    Diagnostic(
      severity: dsError, message: message, span: span, notes: notes, hints: hints
    )
  )

proc reportWarning*(
    self: DiagnosticSink,
    span: Span,
    message: string,
    notes: seq[Diagnostic],
    hints: seq[string],
) =
  self.diagnostics.add(
    Diagnostic(
      severity: dsWarning, message: message, span: span, notes: notes, hints: hints
    )
  )

proc newNote*(span: Span, message: string): Diagnostic =
  result = Diagnostic(severity: dsNote, message: message, span: span)
